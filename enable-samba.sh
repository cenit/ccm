#!/usr/bin/env bash
# Usage: enable-samba.sh <folder-to-serve-over-http>

if [ -z "$1" ]; then
  echo "Usage: $0 <folder-to-serve-over-http>" >&2
  exit 1
fi

sudo apt update
sudo apt-get dist-upgrade -y
sudo apt-get install samba -y

echo -e "[c$]\n    comment = Samba on Ubuntu\n    path = /\n    read only = yes\n    browsable = yes" | sudo tee -a /etc/samba/smb.conf > /dev/null

sudo service smbd restart
sudo ufw allow samba

echo "Adding password for samba user ${USER}"
sudo smbpasswd -a "${USER}"

sudo apt-get install apache2 -y

sudo rm -rf /var/www/html
sudo ln -s "$(realpath "$1")" /var/www/html
