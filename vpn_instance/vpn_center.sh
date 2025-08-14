#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Script must run as root" >&2
  exit 1
fi


#timezone setting
timedatectl set-timezone Europe/Moscow
systemctl restart systemd-timesyncd.service

# Check username
read -p "Enter username: " USER

if [ -z "$USER" ]; then
    echo "ERROR: username cant be empty!" >&2
    exit 1
fi

if [ "$USER" = "root" ]; then
    echo "ERROR: You cant be root!" >&2
    exit 1
fi

if ! id "$USER" &>/dev/null; then
    echo "ERROR: The user '$USER' does not exist in the system!" >&2
    exit 1
fi

# a function that checks for the presence of a rule in iptables and, if missing, applies it.
iptables_add() {
  if ! iptables -C "$@" &>/dev/null; then
    iptables -A "$@"
  fi
}


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

#Drop all other traffic in all directions
		iptables -P OUTPUT DROP
		iptables -P INPUT DROP
		iptables -P FORWARD DROP

		echo -e "\n"
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

while true; do
#Settings for iptables for OpenVPN
	read -r -n 1 -p $'\n'"You need the iptables settings for OpenVPN. Continue? (y|n)" yn
        case $yn in
        [Yy]*)
  		read -r -p $'\n'"Enter the interface, protocol, and port for the VPN server in order:" eth proto port

# OpenVPN
                iptables_add INPUT -i "$eth" -m state --state NEW -p "$proto" --dport "$port" -j ACCEPT

# Allow TUN interface connection to OpenVPN server
                iptables_add INPUT -i tun+ -j ACCEPT -m comment --comment openvpn

# Allow TUN interface connection to be forwarded through other interface
                iptables_add FORWARD -i tun+ -j ACCEPT -m comment --comment openvpn
                iptables_add FORWARD -i tun+ -o "$eth" -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment openvpn
                iptables_add FORWARD -i "$eth" -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment openvpn

# NAT the VPN client traffic to the internet
                iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$eth" -j MASQUERADE -m comment --comment openvpn

		echo -e "\n"
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

# let's check if iptables-persistent is installed.
if ! dpkg -l iptables-persistent &>/dev/null;
then
	echo -e "\niptables-persistent not found. Installing iptables-persistent...\n"
	apt-get update
	apt-get install -y iptables-persistent	
fi

# let's check if OpenVPN is installed.
if ! command -v openvpn &>/dev/null;
then
	echo -e "\nOPenVPN is not found. Installing OpenVPN...\n"
	apt-get update
	apt-get install -y openvpn
fi

# let's check if golang is installed. And install if not
if ! command -v golang &>/dev/null;
then
	echo -e "\ngolang is not found. Installing golang...\n"
	apt-get update
	apt-get install -y golang
fi

# let's check if OpenVPN exporter is installed. And install if not
if ! command -v openvpn_exporter &>/dev/null;
then
	echo -e "\nopenvpn_exporter not found. Installing openvpn_exporter....\n"
	cd /home/$USER
	sudo -u $USER wget -P /home/$USER/ https://github.com/kumina/openvpn_exporter/archive/refs/tags/v0.3.0.tar.gz
	sudo -u $USER tar xvf v0.3.0.tar.gz
	sudo -u $USER sed -i 's|openvpnStatusPaths = flag\.String("openvpn\.status_paths", "[^"]*"|openvpnStatusPaths = flag.String("openvpn.status_paths", "/var/log/openvpn/openvpn-status.log"|' openvpn_exporter-0.3.0/main.go
	cd /home/$USER/openvpn_exporter-0.3.0
	go build /home/$USER/openvpn_exporter-0.3.0/main.go
	cp /home/$USER/openvpn_exporter-0.3.0/main /usr/bin/openvpn_exporter
	touch /var/log/openvpn/openvpn-status.log
	addgroup --system "openvpn_exporter" --quiet
	adduser --system --home /usr/share/openvpn_exporter --no-create-home --ingroup "openvpn_exporter" --disabled-password --shell /bin/false "openvpn_exporter"
	sudo usermod -a -G openvpn_exporter root
	sudo chgrp openvpn_exporter /var/log/openvpn/openvpn-status.log
	sudo chmod 660 /var/log/openvpn/openvpn-status.log
	sudo chown openvpn_exporter:openvpn_exporter /usr/bin/openvpn_exporter
	sudo chmod 755 /usr/bin/openvpn_exporter
	cat <<end> /etc/systemd/system/openvpn_exporter.service
	[Unit]
	Description=Prometheus OpenVPN Node Exporter
	Wants=network-online.target
	After=network-online.target

	[Service]
	User=openvpn_exporter
	Group=openvpn_exporter
	Type=simple
	ExecStart=/usr/bin/openvpn_exporter \\
    	--openvpn.status_paths=/var/log/openvpn/openvpn-status.log

	[Install]
	WantedBy=multi-user.target
end
	systemctl daemon-reload
	systemctl restart openvpn_exporter.service
	systemctl enable openvpn_exporter.service	
fi
# save config iptables
echo -e "\n====================\nSaving iptables config\n====================\n"
service netfilter-persistent save
echo -e "DONE\n"

# activating the routing function
echo -e "\n====================\nIp forward configing\n====================\n"
sed -i 's/#\?\(net.ipv4.ip_forward=1\s*\).*$/\1/' /etc/sysctl.conf
sysctl -p
echo -e "\nDONE\n"
 
#let's check if the program is installed if not then install it. Or reinstall if necessary.
if [ ! -d /usr/share/easy-rsa/ ];
then
	echo "easy-rsa could not be found. Installing easy-rsa..."
	apt-get update
	mkdir /home/$USER/easy-rsa
    	apt-get install -y easy-rsa
	ln -s /usr/share/easy-rsa/* /home/$USER/easy-rsa/
	chown -R $USER.$USER /home/$USER/easy-rsa
	chmod 700 /home/rsa-user/easy-rsa


else
	while true; do
		read -r -n 1 -p $'\n'"Are you ready to reinstall easy-rsa? (y|n) " yn
		case $yn in
		[Yy]*)
			apt-get purge -y easy-rsa
			apt-get install -y easy-rsa 
		  	echo -e "\nDONE\n"
		  	break
		  	;;
		[Nn]*) break
		       	;;

		[*]) echo -e "\nPlease answer Y or N!\n" ;;
		esac
	done
fi

#create directory for clients
mkdir -p /etc/openvpn/clients_config/keys /etc/openvpn/clients_config/conf
chown -R $USER:$USER /etc/openvpn/clients_config/ /etc/openvpn/clients_config/

#Install prometheus-node-exporter
if ! command -v prometheus-node-exporter &>/dev/null;
then
	echo "\nInstalling prometheus-node-exporter"
        apt-get update 
	apt-get install -y prometheus-node-exporter

fi	

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
        cat > /usr/local/bin/vpn_backup.sh << end
#!/bin/bash
TIMESTAMP=\$(date +%Y%m%d)
tar -czf /tmp/vpn-backup-\$TIMESTAMP.tar.gz /etc/openvpn/server /etc/opentvpn/clients-conf
aws s3 cp /tmp/vpn-backup-\$TIMESTAMP.tar.gz s3://backup-inf/openvpn/ --endpoint-url=https://storage.yandexcloud.net --region=ru-central1
rm -f /tmp/vpn-backup-*.tar.gz
end
chmod +x /usr/local/bin/vpn_backup.sh
bash -c 'echo "0 */2 * * * root /usr/local/bin/vpn_backup.sh" > /etc/cron.hourly/backup'


#create pki and issue a pair of keys. Create server key and req
while true; do
                read -r -n 1 -p $'\n'"Do you want init-pki, and create server key and req? (y|n) " yn
                case $yn in
                [Yy]*)
			cd /home/$USER/easy-rsa
			sudo -u $USER ./easyrsa init-pki
			sudo -u $USER ./easyrsa gen-req server nopass
			echo -e "\nDONE\n"
                        break
                        ;;
                [Nn]*) exit ;;

                [*]) echo -e "\nPlease answer Y or N!\n" ;;
                esac
        done

