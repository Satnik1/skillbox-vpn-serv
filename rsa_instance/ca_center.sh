#!/bin/bash
set -e 

# Проверка прав администратора
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Script must run as root" >&2
  exit 1
fi

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
#timezone setting
timedatectl set-timezone Europe/Moscow
systemctl restart systemd-timesyncd.service

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
		if ! command -v iptables-persistent &>/dev/null;
		then
			echo -e "\niptables-persistant not found. Installing iptables-persistent...\n"
			apt-get update
			apt-get install iptables-persistent
		fi
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

		#save config
		echo -e "\n====================\nSaving iptables config\n====================\n"
    		service netfilter-persistent save
   	 	echo -e "DONE\n"
		break
		;;

	[Nn]*)	echo -e "\n"
    		break
	       	;;
	*)
		echo -e "\nPlease answer Y or N!\n" 
		break
		;;
	esac
done

#let's check if the program is installed if not then install it. Or reinstall if necessary.
if [ ! -d /usr/share/easy-rsa/ ];
then
	echo "easy-rsa could not be found. Installing easy-rsa...\nWork directory: ~/easy-rsa/"
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

			if [ ! -d /home/$USER/easy-rsa/ ];
			then
				mkdir /home/$USER/easy-rsa
				ln -s /usr/share/easy-rsa/* /home/$USER/easy-rsa/
				chown -R $USER.$USER /home/$USER/easy-rsa
				chmod 700 /home/rsa-user/easy-rsa

			else
				read -r -n 1 -p $'\n'"Your folder /home/$USER/easy-rsa/ will be removed. Are you sure? (y|n)" yn
				case $yn in
				[Yy]*) 
					rm -r -d /home/$USER/easy-rsa
					mkdir /home/$USER/easy-rsa
					ln -s /usr/share/easy-rsa/* /home/$USER/easy-rsa/
					chown -R $USER.$USER /home/$USER/easy-rsa
				 	chmod 700 /home/rsa-user/easy-rsa

					echo -e "DONE\n"
					break
					;;
				[Nn]*)
					break 
					;;
				[*]) echo -e "\nPlease answer Y or N!\n" ;;
				esac
			fi
		  	echo -e "\nDONE\n"
		  	break
		  	;;
		[Nn]*) 
			break
			;;
		*) echo -e "\nPlease answer Y or N!\n" ;;
		esac
	done
fi

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
	cat > /usr/local/bin/ca_backup.sh << end
#!/bin/bash
TIMESTAMP=\$(date +%Y%m%d)
tar -czf /tmp/rsa-backup-\$TIMESTAMP.tar.gz -C /home/$USER/easy-rsa pki
aws s3 cp /tmp/rsa-backup-\$TIMESTAMP.tar.gz s3://backup-inf/rsa/ --endpoint-url=https://storage.yandexcloud.net --region=ru-central1
rm -f /tmp/rsa-backup-*.tar.gz
end
chmod +x /usr/local/bin/ca_backup.sh
bash -c 'echo "0 */2 * * * root /usr/local/bin/ca_backup.sh" > /etc/cron.hourly/backup'



#create pki and issue a pair of keys
cd /home/$USER/easy-rsa
sudo -u $USER ./easyrsa init-pki
