#!/bin/bash

sudo systemctl stop snell.service
sudo systemctl disable snell.service
sudo rm -f /etc/systemd/system/snell.service

cd
rm -f rm /usr/bin/snell-server
rm -f rm /etc/snell/snell-server.conf
