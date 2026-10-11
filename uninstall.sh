#!/bin/bash

sudo bash install.sh --uninstall
sudo rm -f /etc/batocera-desktop.conf
sudo rm -rf /var/log/batocera-desktop
sudo rm -rf /boot/batocera /batocera
exit 0
