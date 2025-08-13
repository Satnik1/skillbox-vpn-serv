#!/bin/bash

yc compute instance create \
	--name rsa-instance \
	--zone ru-central1-a \
	--network-interface subnet-name=my-yc-subnet-a,nat-ip-version=ipv4 \
	--create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts \
	--metadata-from-file user-data="/media/sf_share/skillbox_vpn-server/rsa_instance/rsa_conf.yaml"


