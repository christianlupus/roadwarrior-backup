#! /bin/bash

# PS4='$LINENO: '
# set -x

CONFIG_PATH=/etc/roadwarrior-backup/config

if [ ! -r $CONFIG_PATH ]; then
	echo "Could not read path $CONFIG_PATH"
	exit 1
fi

#. `dirname "$0"`/config
. "$CONFIG_PATH"


# Check for root
if [ `whoami` != root ]; then
	echo "You need to run the script as user root"
	exit 1
fi

## Saves a local folderstructure on a remote backup machine
##
## $1 The folder in the local file system tree that should be backed up.
## $2 The relative name on the backup server under which the backup should be saved.
createPlainBackup()
{
	local dst="$PREFIX/sync/$2"
	ssh root@$HOST "mkdir -p $dst" < /dev/null || {
			echo "Could not create folder $dst on $HOST. Aborting";
			return 1;
		}
	
	local src="$1"
	if ! echo "$src" | grep '/$' > /dev/null ; then
		# Ensure src end with a slash to avoid unintended directory creation by rsync
		src="$src/"
	fi
	
	local links=$(ssh root@$HOST bash <<- EOF
		cd '$PREFIX'
		for i in daily.* weekly.* monthly.* yearly.*
		do
			if [ -d "\$i" -a -d "\$i/$2" ]; then
				echo "--link-dest=$PREFIX/\$i/$2"
			fi
		done
	EOF
	)
	ret=$?
	
	if [ $ret -ne 0 ]; then
		echo "Could not enumerate all existing backups. Aborting."
		return 2
	fi
	
	# Take only the first 20 backups as rsync does not allow more
	links=$(echo "$links" | head -n 20)
	
	local rsync_links=()
	while read l
	do
		test -n "$l" && rsync_links+=("$l")
	done <<< "$links"
	
	local add_options=()
	
	test -n $FUZZY && add_options+=("--fuzzy")
	
	#echo "Num Links: ${#rsync_links[@]}"
	
	rsync $RSYNC_OPT "${add_options[@]}" "${rsync_links[@]}" "$src" "root@$HOST:$dst"
	ret=$?
	
	case $ret in
		0)
			;;
		*)
			echo "An error happened during the transfer. Aborting transaction."
			return 3
			;;
	esac
	
}

## Mount a filesystem and creates a backup thereof on the remote server
##
## $1 The block decive to be backed up. Must be trivially mountable.
## $2 The relative name on the remote backup machine.
createMountedBackup()
{
	# Mountpoint
	local mnt=`mktemp -d`
	
	mount "$1" "$mnt" -o ro || {
			echo "Could not mount the backup. Aborting."
			return 4
		}
	
	local src="$mnt"
	if [ -n "$MNT_PREFIX" ]; then
		src="$src/$MNT_PREFIX"
	fi
	
	createPlainBackup "$src" "$2"
	local ret=$?
	
	umount "$mnt" || {
			echo "Umounting failed. You might need to manually umount."
			test $ret -eq 0 && ret=5
		}
	rmdir "$mnt"
	
	return $ret
}

## A generic function to handle LVM based backups.
##
## This function first generates a snapshot of a named LV, calls a certain command and then removes the snapshot of the LV again.
## The command is executed after snapshot creation with the first parameter the (full) name of the snapshot and any additioal (vararg) parameters to this function
##
## $1 The LV to be used as a basis for the snapshot
## $2 The command to be executed
## $3, $4, ... The additional parameters for the command
createLVMBackup()
{
	local source="$1"
	local command="$2"
	shift 2
	
	# Strip leading /dev/ from source if existent
	if echo "$source" | grep '^/dev/' > /dev/null; then
		source=`echo "$source" | sed 's@^/dev/@@'`
	fi
	
	local vgname=`echo "$source" | cut -d/ -f1`
	
	lvcreate --snapshot "$source" --name $SNAPSHOTNAME --size $SNAPSHOTSIZE -qq {flock_id}>&- || {
			echo "Could not create LV snapshot $SNAPSHOTNAME for LV $source. Plase check manually."
			return 6
		}
	
	"$command" "/dev/$vgname/$SNAPSHOTNAME" "$@"
	local ret=$?
	
	lvremove -qy "$vgname/$SNAPSHOTNAME" -q {flock_id}>&- || {
			echo "Removal of the snapshot was not successfull. Plase check manually."
			test $ret -eq 0 && ret=7
		}
	
	return $ret
}

## Create a backup from a LV partition that contains a single file system.
##
## $1 The name of the LV to be backed up
## $2 The relative name on the remote machine
createPlainLVMBackup()
{
	createLVMBackup "$1" createMountedBackup "$2"
	return $?
}

## Decrypts a block device and backs up the resulting plain filesystem inside
##
## $1 The encrypted block device to use
## $2 The relative path on the remote backup server to store the backup
## $3 The name of the decrypted device (without /dev/mapper)
## $4 The keyfile used for decryption
createPlainEncryptedBackup()
{
	cryptsetup open -d "$4" "$1" "$3" || {
			echo "Could not open the encrypted device $1 using the key $4"
			return 8
		}
	
	createMountedBackup "/dev/mapper/$3" "$2"
	local ret=$?
	
	cryptsetup close "$3" || {
			echo "Could not close the crypt device /dev/mapper/$3. Please do so manually."
			test $ret -eq 0 && ret=9
		}
	
	return $ret
}

## Backup an encrypted LV that contains a single file system using a LVM snapshot
##
## $1 The block device that contains the origin file system
## $2 The relative path on the remote backup server to store the content to
## $3 The name of the decrypted device to be used (without /dev/mapper)
## $4 The keyfile needed to decrypt the block device
createEncryptedLVMBackup()
{
	if [ -z "$4" -o ! -r "$4" ]; then
		echo "No valid key ($4) for $1 was given"
		return 10
	fi
	
	createLVMBackup "$1" createPlainEncryptedBackup "$2" "$3" "$4"
	return $?
}

## Parse the options in the backuptab file
## This function resets all global configurations to the defaults and then sets the to-be-modified ones accordingly to the table
##
## $1 The source of the backing process, just for reference of a certain line in case of parsing errors
## $2 The options as in the backuptab specified
parseOptions()
{
	MNT_PREFIX=''
	CRYPT=''
	FUZZY='yes'
	
	src="$1"
	shift
	
	# Split the options by comma
	while read -d, i
	do
		
		test -z "$i" && continue
		
		# Read key=value pairs
		IFS='=' read k v <<< "$i"
		case "$k" in
			defaults)
				;;
			prefix)
				MNT_PREFIX="$v"
				;;
			crypt)
				CRYPT="$v"
				;;
			nofuzzy)
				FUZZY=''
				;;
			fuzzy)
				FUZZY='yes'
				;;
			*)
				echo "Ignoring key $k in the options of the backup for $src"
		esac
		
	done <<< "$1,"
}

## Parse a single line from the backuptab file
##
## The line is split automatically by bash's word separation.
##
## $1 The source of the backup
## $2 The relative path of the backup on the remote backup machine
## $3 The type of the source. Valid values are plain, lvm, lvm+crypt.
## $4 Options for the backup process
parseTabLine()
{
	local src="$1"
	local dst="$2"
	local type="$3"
	shift 3
	
	parseOptions "$src" "$1"
	
	case "$type" in
		plain)
			createPlainBackup "$src" "$dst" || return $?
			;;
		lvm)
			createPlainLVMBackup "$src" "$dst" || return $?
			;;
		lvm+crypt)
			createEncryptedLVMBackup "$src" "$dst" "$SNAPSHOTNAME" "$CRYPT" || return $?
			;;
		*)
			echo Unknown type found: $type
			exit 1
			;;
	esac
}

## Check for existence of the various flag files
##
## If no flag files are found, the program terminates directly.
## If flags are found, this is stored in some global variables.
checkFlags()
{
	test -e "$FLAGDIR/yearly" && ENABLE_YEARLY=yes
	test -e "$FLAGDIR/monthly" && ENABLE_MONTHLY=yes
	test -e "$FLAGDIR/weekly" && ENABLE_WEEKLY=yes
	test -e "$FLAGDIR/daily" && ENABLE_DAILY=yes
	
	if [ -z "$ENABLE_YEARLY$ENABLE_MONTHLY$ENABLE_WEEKLY$ENABLE_DAILY" ]; then
		exit 0
	fi
}

## Check the connectivity to the remote backup server by opening a testing SSH connection.
##
## This function will terminate the execution of the script if the server cannot be reached.
checkConnectivity()
{
	if ! ssh root@$HOST 'true' < /dev/null > /dev/null 2>&1; then
		echo "Could not connect to server $HOST, stopping now."
		exit 1
	fi
}

## Rotate the backups on the remote server
##
## This function logs into the remote server and performs a rotation of a certain level of backups.
## 
## $1 The name of the backups to be rotated (like monthly)
## $2 The name of the last underlying backup (e.g. weekly.3)
## $3 The highest index of the current backup level (e.g. 11)
## $4 The flag file that should be deleted on success.
rotate_abstract()
{
	ssh root@$HOST 'bash' <<- EOF
# 	cat <<- EOF | bash
# 		echo 'on server'
		
		# Check for lower level backup existence
		if [ ! -d '$PREFIX/$2' ]; then
			echo 'Lower level backup $2 was not found.'
			exit 1
		fi
		
		# Search for the first hole in the current sequence
		function findHole()
		{
			for i in \`seq 0 $3\`
			do
				if [ ! -d "$1.\$i" ]; then
					echo \$i
					return 1
				fi
			done
			
			return 0
		}
		
# 		set -x
		cd '$PREFIX'
		
		hole=\`findHole\`
		holeFound=\$?
		
		if [ \$holeFound -eq 0 ]; then
			# The sequence is complete. Remove the tail and continue.
			mv '$1.$3' remove || { echo 'Could not move old backup out of the way'; exit 2; }
			upper=$3
		else
			# A hole (or early ending of the sequence) was detected. Fill only the next entry/gap.
			upper=\$hole
		fi
		
		# Do the rotation itself
		for i in \`seq \$upper -1 1\`
		do
			let im=\$i-1
			mv "$1.\$im" "$1.\$i" || { echo "Could not rotate the backup $1.\$im to $1.\$i."; exit 3; }
		done
		
		# Use the underlying backup as the first one
		mv '$2' '$1.0' || { echo "Could not move the underlying backup into place."; exit 4; }
		
		# Eventually remove the temporary backup
		if [ \$holeFound -eq 0 ]; then
			rm -rf remove || { echo "Could not permanently remove the oldest backup"; exit 5; }
		fi
		
# 		sleep 0.5
	EOF
	local ret=$?
	
	case $ret in
		0)
			rm "$4" || return 11
			return 0
			;;
		1)
			rm "$4" || return 13
			return 12
			;;
		*)
			return 2$ret
			;;
	esac
}

## Rotate the yearly backups on the server and remove flag
rotate_yearly()
{
	test -z "$ENABLE_YEARLY" && return 0
	
	rotate_abstract yearly monthly.11 10 "$FLAGDIR/yearly"
	return $?
}

## Rotate the monthly backups on the server and remove flag
rotate_monthly()
{
	test -z "$ENABLE_MONTHLY" && return 0
	
	rotate_abstract monthly weekly.3 11 "$FLAGDIR/monthly"
	return $?
}

## Rotate the weekly backups on the server and remove flag
rotate_weekly()
{
	test -z "$ENABLE_WEEKLY" && return 0
	
	rotate_abstract weekly daily.6 3 "$FLAGDIR/weekly"
	return $?
}

## Rotate the daily backups on the server and remove flag
rotate_daily()
{
	test -z "$ENABLE_DAILY" && return 0
	
	create_backup || return $?
	
	rotate_abstract daily sync 6 "$FLAGDIR/daily"
	return $?
}

## Create a new (complete) backup, rotate the daily backups on the server and remove flag
## 
## First, the lines of the backuptabs file are parsed and synchronized to the remote server.
## Then, the intermediate backup is rotated in place into the daily chain.
create_backup()
{
	local line
	
	cat "$BACKUPTAB" | sed 's@#.*@@;s@^[ \t]*$@@;/^$/d' | while read line
	do
# 		echo "$line"
		parseTabLine $line || return $?
# 		echo "Line done: $line"
	done
	ret=$?
	
	return $ret
}

## Remove the lock file on termination of the script
## 
## This must not be called if the lock could not be aquired.
## Oterwise, we could steal the file and on next invocation the lock is no longer visible.
finish()
{
	rm -f $LOCK_FILE
}

# Try to get the lock on a certain file
exec {flock_id}> $LOCK_FILE
flock -n ${flock_id}
ret=$?

if [ $ret -ne 0 ]; then
	# TODO exit 0 or 1?
	exit 0
fi

# Enable the trap only after the check of the lock is finished. Otherwise some nasty effects might happen every even time, when removing a file (with active lock) while backup is still running...
trap finish EXIT

# Check if we have to do anything. This function will terminate the script in case of nothing has to be done.
checkFlags

checkConnectivity

set -x

# Do the rotations and abort in case anything goes wrong
rotate_yearly && rotate_monthly && rotate_weekly && rotate_daily || echo "Problem found during sync process."

flock -u ${flock_id}
