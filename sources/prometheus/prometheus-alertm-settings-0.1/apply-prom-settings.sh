#!/bin/bash

sudo cp /etc/prometheus-my-settings/*.yml /etc/prometheus/
sudo systemctl restart prometheus 
sudo systemctl restart prometheus-alertmanager
