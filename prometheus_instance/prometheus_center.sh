#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Script must run as root" >&2
  exit 1
fi


#timezone setting
timedatectl set-timezone Europe/Moscow
systemctl restart systemd-timesyncd.service

#Install prometheus-node-exporter if not
if ! command -v prometheus &>/dev/null;
then
        echo "\nInstalling prometheus"
        apt-get update
        apt-get install prometheus

fi


#Install prometheus-node-exporter if not
if ! command -v prometheus-node-exporter &>/dev/null;
then
        echo "\nInstalling prometheus-node-exporter"
        apt-get update
        apt-get install prometheus-node-exporter

fi

#Install Alertmanager if not
if ! command -v prometheus-alertmanager &>/dev/null;
then
	echo "\nInsatalling Alertmanager"
	apt-get install prometheus-alertmanager
fi



# request an IP adress for each VM
get_ip() {
  while read -r -p "Enter private IP for $1: " ip; do
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
    echo "inavlid IP format!"
  done
  echo "$ip"
}

vpn_ip=$(get_ip "VPN Instance")
rsa_ip=$(get_ip "RSA Instance")

# /etc/hosts update
HOSTS_FILE="/etc/hosts"
echo -e "\nupdate /etc/hosts file..."

# Delete if there are old entries.
sed -i '/# Added by Prometheus setup script/d' "$HOSTS_FILE"
sed -i '/vpn-instance/d' "$HOSTS_FILE"
sed -i '/rsa-instance/d' "$HOSTS_FILE"
sed -i '/prometheus-instance/d' "$HOSTS_FILE"

# add new
echo -e "\n# Added by Prometheus setup script" >> "$HOSTS_FILE"
echo "$vpn_ip    vpn-instance" >> "$HOSTS_FILE"
echo "$rsa_ip    rsa-instance" >> "$HOSTS_FILE"
echo "127.0.0.1  prometheus-instance" >> "$HOSTS_FILE"

echo "Add entries:"
echo "$vpn_ip    vpn-instance"
echo "$rsa_ip    rsa-instance"
echo "127.0.0.1  prometheus-instance"
   
# restart Prometheus
systemctl restart prometheus

echo -e "\nThe configuration has been successfully updated!"
echo "Node exporters: vpn-instance, rsa-instance, prometheus0instance!"
echo "OpenVPN exporter: vpn-instance:9176"
echo "Alertmanager: prometheus-instance:9093"


# let's check if iptables-persistent is installed.
if ! dpkg -l iptables-persistent &>/dev/null;
then
        echo -e "\niptables-persistant not found. Installing iptables-persistent...\n"
        apt-get update
        apt-get install -y iptables-persistent
fi

# a function that checks for the presence of a rule in iptables and, if missing, applies it.
iptables_add() {
  if ! iptables -C "$@" &>/dev/null; then
    iptables -A "$@"
  fi
}

# iptables for prometheus, alertmanager  and exporters
echo -e "\n====================\nIptables configuration\n====================\n"
iptables_add INPUT -p tcp --dport 9090 -j ACCEPT -m comment --comment prometheus
iptables_add INPUT -p tcp --dport 9093 -j ACCEPT -m comment --comment prometheus_alertmanager
iptables_add OUTPUT -p tcp --dport 587 -j ACCEPT -m comment --comment smtp
iptables_add OUTPUT -p tcp -d 127.0.0.1 --dport 9100 -j ACCEPT -m comment --comment prometheus_node_exporter
iptables_add OUTPUT -p tcp -d "$vpn_ip" --dport 9100 -j ACCEPT -m comment --comment vpn_node_exporter
iptables_add OUTPUT -p tcp -d "$rsa_ip" --dport 9100 -j ACCEPT -m comment --comment ca_node_exporter
iptables_add OUTPUT -p tcp -d "$vpn_ip" --dport 9176 -j ACCEPT -m comment --comment prometheus_openvpn_exporter
echo -e "\n====================\nSaving iptables config\n====================\n"

#Apply settings for iptables
while true; do
	read -r -n 1 -p $'\n'"Do you want apply new settings for iptables? (y|n)" yn
	case $yn in
	[Yy]*)

#Accept output traffic DNS
		iptables_add OUTPUT -p tcp --dport 53 -j ACCEPT -m comment --comment dns
		iptables_add OUTPUT -p udp --dport 53 -j ACCEPT -m comment --comment dns

#Accept output traffic NTP
		iptables_add OUTPUT -p udp --dport 123 -j ACCEPT -m comment --comment ntp

#Accept traffic ICMP for ping
		iptables_add OUTPUT -p icmp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
		iptables_add INPUT -p icmp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT

#Accept traffic lo-interface for internal services work
		iptables_add OUTPUT -o lo -j ACCEPT
		iptables_add INPUT -i lo -j ACCEPT

#Accept ssh
		iptables_add INPUT -p tcp --dport 22 -j ACCEPT -m comment --comment ssh

#Accept HTTP and HTTPS
		iptables_add OUTPUT -p tcp -m multiport --dports 443,80 -j ACCEPT

#Accept traffic for established session
		iptables_add INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
		iptables_add OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
#

#Drop all other traffic in all directions
		iptables -P OUTPUT DROP
		iptables -P INPUT DROP
		iptables -P FORWARD DROP
		break
		;;
    		
	[Nn]*)
		echo -e "\n"
		break
       		;;
	[*])
		echo -e "\nPlease answer Y or N!\n" ;;
  	esac
done

#install unzip
if ! command -v unzip &>/dev/null;
then
       apt-get install -y unzip
fi
#install AWS CLI
if ! command -v aws &>/dev/null;
then
        echo "Установка AWS CLI..."
        cd /home/$USER
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        ./aws/install

fi              
                
aws configure   
if ! aws s3 ls s3://backup-inf/ --endpoint-url=https://storage.yandexcloud.net &>/dev/null; then
    echo "Ошибка подключения к Object Storage!"
    exit 1
fi

#create backup
        cat > /usr/local/bin/monitor_backup.sh << end
#!/bin/bash
TIMESTAMP=\$(date +%Y%m%d)
tar -czf /tmp/monitor-backup-\$TIMESTAMP.tar.gz /etc/prometheus 
aws s3 cp /tmp/monitor-backup-\$TIMESTAMP.tar.gz s3://backup-inf/monitor/ --endpoint-url=https://storage.yandexcloud.net --region=ru-central1
rm -f /tmp/monitor-backup-*.tar.gz
end
chmod +x /usr/local/bin/monitor_backup.sh
bash -c 'echo "0 */2 * * * root /usr/local/bin/monitor_backup.sh" > /etc/cron.hourly/backup'



# save config iptables
echo -e "\n====================\nSaving iptables config\n====================\n"
service netfilter-persistent save
echo -e "DONE\n"
