#! /bin/sh

install -o root -g root -Dm u=rw,go=r roadwarrior-backup.cron /etc/cron.d/roadwarrior-backup

install -o root -g root -D roadwarrior-backup.daily /etc/cron.daily/roadwarrior-backup
install -o root -g root -D roadwarrior-backup.weekly /etc/cron.weekly/roadwarrior-backup
install -o root -g root -D roadwarrior-backup.monthly /etc/cron.monthly/roadwarrior-backup
install -o root -g root -D roadwarrior-backup.yearly /etc/cron.yearly/roadwarrior-backup
