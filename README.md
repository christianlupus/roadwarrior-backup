
# roadwarrior-backup

A small script to allow incremental remote backups for roadwarriors (and those with a notebook in general).

## Introduction - Why another backup solution?

When using a laptop you are most likely not always in one single location.
You move around, log into various WiFi networks etc.

Most backup solutions however work as pull backups, that means the backup machine triggers the backup process.
As the backup machine sits somewhere it does not know where the client (that needs to be backed up) is located and how to reach it.
Thus, pull backups are not suitable for use with mobile devices.

This is the reason why I created this set of scripts to allow a remote backup be done.

## Main features

- Asynchronous and lock-protected transfer of the file to be backed up
- Incremental backups using hard links to reduce required storage while maintaining easy access to the files
- Restoration is easily done as the whole folder structure is directly visible
- Plan bash script, few additional dependencies are needed
- Use of LVM snapshots when possible to obtain a well defined state during the transfer
- Support for Luks decryption using key files allows for encrypted systems to be backed up

## How it works

The whole process is separated into two phases.
First, there is a script that allows to set some flags in a special folder by creating files.
These flags determine what action needs to be done during the next backup iteration.
This script needs to be called with different options on various moments in time, e.g. by anacron or by systemd timers.

Second, there is a script that checks for the flags set, that should be called with a high frequency.
If no flags are there, this script quickly terminates causing no high load to the system.
However if any flags are set, the script checks connection to the preconfigured backup server.

If the connection cannot be made, the script terminates, which maintains the flags.
The next time the backup server is reachable again, the backup can directly start.

If the connection can successfully established, the flags determine the actions taken by the working script.
The backups of the various levels are shifted if needed and indicated by the flags.
On the lowest possible level (daily backup) a new incremental backup is generated as needed.

## Installation

### Copying of scripts and template files
Simply go to the folder of this repository and call `./install.sh` as user `root`.
This will install a set of files on your machine, that are `/etc/roadwarrior-backup`, `/var/lib/roadwarrior-backup` and install the scripts `roadwarrior-backup-trigger.sh` and `roadwarrior-backup-flag` in `/usr/local/sbin`.
Please configure the settings in `/etc/roadwarrior-backup` and you are ready for the first backup.

### Configuration of the script

There are two files to be configured correctly.
First, there is `/etc/roadwarrior-backup/config`.
This is the main configuration file used by the script.

You must adopt `HOST` and `PREFIX` to your setup.
The other settings in this file can be changed if needed, but have sensible defaults.
However, please keep in mind, that changing the paths in `FLAGDIR`, `LOCK_FILE`, or `BACKUPTAB` needs manual modification and mofing of files as the installation script assumes these to be kept at their defaults.

The `SNAPSHOTNAME` is the name of a generated snapshot, in case LVM is used.
The size of this snapshot is set by `SNAPSHOTSIZE`.
You might want to adopt to the amount of tansferred data and your bandwidth.

### Configuration of the backup locations

Next, you need to configure the backup locations of the mobile device.
This is done in the file `/etc/roadwarrior-backup/backuptab`, which is a table similaryly to e.g. `fstab`.
The first column is the (local) source on the device that should be backed up.
The second column is a path on the backup server under which the source should be saved (see below for an example).
The third column defines the type of source provided in the first column.

| Type | Description |
|----|-----|
| plain | Copy the data from the absolute path in the 1st column as source to the backup server. |
| lvm | The first column is the VG/LV pair of a LVM volume that should be snapshotted prior to the transfer. |
| lvm+crypt | Similar to lvm but decrypt a containing luks container in the LV snapshot prior to transfer. |

The fourth column contains additional parameters for the backup location in form of a comma separated key value list.

| Option key | Type | Description |
|----|----|----|
| prefix | only lvm and lvm+crypt | Do not backup all files in the LV container but instead descend into the prefix folder inside. |
| crypt | only lvm+crypt | Provide the key file as value for decryption. |
| fuzzy | any | Enable fuzzy transfer of files (see `man rsync`). |
| nofuzzy | any | Disable fuzzy transfer of files (see `man rsync`). |

### Enable key based SSH access

The backup solution is based on the use of SSH.
You need to setup key based authentication.
Simply put the content of `/root/.ssh/id_rsa.pub` on the laptop at the end of `/root/.ssh/authorized_keys` on the backup machine.
For further questions see your favorite search engine of the internet ;-).

Verify that you can log into your backup server using `ssh $HOSTNAME` from your laptop as user root, while replacing `$HOSTNAME` with the address of your backup machine.

### Creating the first (full) backup

After configuration, it is suggested that you create a first daily backup.
This will be a full backup so it might take quite some time depending on your bandwith and amount of data.
It might be favorable to do this when the mobile device is connected with maximum upload bandwith to the backup server to speed things up.

To trigger the first backup call the following functions in a terminal as root:

```
# roadwarrior-backup-flag.sh -d
# roadwarrior-backup-trigger.sh
```

### Enabling autmatic backups

You should now add a set of automatic jobs to your favorite job handling system.
Such systems are cron, anacron, systemd timers etc.

As cron/anacron is the most simple configuration in terms of lines of code, it should be described here.
Feel free to adopt to your own needs.

First of all, the script `/usr/local/sbin/roadwarrior-backup-trigger.sh` must be called regularly (say every 5 min) as root.
To do so, simply put a line in `/etc/crontab` or a new file `/etc/cron.d/roadwarrior-backup` with the content

```
*/5 * * * *	root	/usr/local/sbin/roadwarrior-backup-trigger.sh
```

The trigger will now be triggered every 5 min.
As soon as a flag is set, the next time the trigger is fired, the corresponding action is going to take place.

Next, the indivdual time levels must be implemented.
This is done using anacron to cope with the effect if the machine is not running all the time.

Create a file `/etc/cron.daily/roadwarrior-backup`, make it executable and put in this file the following content

```
#! /bin/sh
/usr/local/sbin/roadwarrior-backup-flag.sh --daily
```

Do the same in the folders `/etc/cron.weekly`, `/etc/cron.monthly`, and `/etc/cron.yearly`.
Do not forget to adopt the parameter in the files accordinly to `--weekly`, `--monthly`, and `--yearly`.

### Check everything is working

Now you should have a working configuration set up.
Before you rely completely on your backup you should check if the automatic backup works (so check tomorrow) and if all files have been transferred as you intended.

## Configuration example

Assume the following file `/etc/roadwarrior-backup/config`:

```
BACKUPTAB=/etc/roadwarrior-backup/backuptab
HOST=my.central.backup.server
PREFIX=/backup/laptop
RSYNC_OPT="--partial --partial-dir=.rsync-dir -az --numeric-ids --delete --delete-excluded --delete-delay --one-file-system -F"
SNAPSHOTNAME=backup-snap
SNAPSHOTSIZE=1G
MAPPERNAME=backup-decrypted
FLAGDIR=/var/lib/roadwarrior-backup/flags
LOCK_FILE=/var/lib/roadwarrior-backup/lock
```

Further assume the following `/etc/roadwarrior-backup/backuptab`:

```
/etc               /etc       plain
system/data        /images    lvm                     
system/home-enc    /home      lvm+crypt      prefix=max,crypt=/key/home.key
```

This will create on the backup machine the folder `/backup/laptop`.
Within this folder the various backups are saved, e.g. `/backup/laptop/daily.0`.
In each backup there will be three folders: `etc`, `images`, and `home`.

All data in `/etc` of the laptop will be backed to the folder `/backup/laptop/daily.0/etc`.
There is no LVM in use, so it is not possible to be done atomically.
This means that any changes during the transfer might cause an inconsistent state to be backed up.
This inherent to the fact that a plain folder is copied and no restriction of the roadwarrior-backup.

The content of the LV `data` in the VG `system` is copied to the folder `/backup/laptop/daily.0/images` on the backup server.
To do so, a LVM snapshot is used which makes the transfer atomic, it will be in a well defined state.

The data of the user `max` will be copied to `/backup/laptop/daily.0/home` on the backup machine.
These files lie on an encrypted LV called `home-enc` in the VG `system`.
To decrypt the (LUKS) block device the key `/key/home.key` on the laptop is used.
The decrypted block device is then mounted temporarily to extract the data.
Note however, that the file system is mounted at `/home` but max' data are in `/home/max`.
Thus the second option `prefix=max` just copies the data from the folder `max` inside the file system on the decrypted block device to the destination folder.
