#! /bin/sh

if [ `whoami` != root ]; then
	echo "Please call this script as user root"
	exit 1
fi

# set -x

echo 'Copying templates to /etc/roadwarrior-backup folder'
install -d -o root -g root /etc/roadwarrior-backup
test -f /etc/roadwarrior-backup/backuptab || install -o root -g root -m u=rw,go=r backuptab.template /etc/roadwarrior-backup/backuptab
test -f /etc/roadwarrior-backup/config || install -o root -g root -m u=rw,go=r config.template /etc/roadwarrior-backup/config

echo 'Creating directory under /var'
install -d -o root -g root /var/lib/roadwarrior-backup/
install -d -o root -g root /var/lib/roadwarrior-backup/flags

echo 'Installing script in /usr/local/sbin'
install -o root -g root trigger.sh /usr/local/sbin/roadwarrior-backup-trigger.sh

