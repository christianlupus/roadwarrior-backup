#! /bin/bash

set -x

. `dirname "$0"`/config

# Check for root
if [ `whoami` != root ]; then
	echo "You need to run the script as user root"
	exit 1
fi

function createPlainBackup()
{
	dst="$PREFIX/sync/$2"
	ssh root@$HOST "mkdir -p $dst"
	
	src="$1"
	if ! echo "$src" | grep '/$' > /dev/null ; then
		# Ensure src end with a slash to avoid unintended directory creation by rsync
		src="$src/"
	fi
	
	# TODO Add hard-linking
	
	links=()
	for i in 0 1 2 3 4 5 6; do links+=("daily.$i"); done
	for i in 0 1 2; do links+=("weekly.$i"); done
	for i in 0 1 2 3 4 5 6 7 8 9 10 11; do links+=("monthly.$i"); done
	
	rsync_links=()
	for i in "${links[@]}"
	do
		ssh root@$HOST "test -d $PREFIX/$i" && rsync_links+=("--link-dest=$PREFIX/$i/$2")
	done
	
	rsync $RSYNC_OPT "$src" "root@$HOST:$dst" "${rsync_links[@]}"
}

function createMountedBackup()
{
	# Mountpoint
	mnt=`mktemp -d`
	
	mount "$1" "$mnt" -o ro
	
	src="$mnt"
	if [ -n "$MNT_PREFIX" ]; then
		src="$src/$MNT_PREFIX"
	fi
	
	createPlainBackup "$src" "$2"
	
	umount "$mnt"
	rmdir "$mnt"
}

function createPlainLVMBackup()
{
	lvcreate --snapshot "$1" --name $SNAPSHOTNAME --size $SNAPSHOTSIZE
	createMountedBackup $SNAPSHOTNAME "$2"
	lvremove -qy $SNAPSHOTNAME
}

function createEncryptedLVMBackup()
{
	if [ -z "$CRYPT" ]; then
		echo "No key for $1 was given"
		exit 1
	fi
	
	lvcreate --snapshot "$1" --name $SNAPSHOTNAME --size $SNAPSHOTSIZE
	cryptsetup open -d "$CRYPT" "$SNAPSHOTNAME" "$MAPPERNAME"
	
	createMountedBackup "/dev/mapper/$MAPPERNAME" "$2"
	
	cryptsetup close "$MAPPERNAME"
	lvremove -qy $SNAPSHOTNAME
}

function parseOptions()
{
	MNT_PREFIX=''
	CRYPT=''
	
	src="$1"
	shift
	
	# Split the options by comma
	while read -d, i
	do
		
		# Read key=value pairs
		IFS='=' read k v <<< "$i"
		case "$k" in
			prefix)
				MNT_PREFIX="$v"
				;;
			crypt)
				CRYPT="$v"
				;;
			*)
				echo "Ignoring key $k in the options of the backup for $src"
		esac
		
	done <<< "$@,"
}

function parseTabLine()
{
	src="$1"
	dst="$2"
	type="$3"
	shift 3
	
	parseOptions "$src" "$@"
	
	case "$type" in
		plain)
			createPlainBackup "$src" "$dst"
			;;
		lvm)
			createPlainLVMBackup "$src" "$dst"
			;;
		lvm+crypt)
			createEncryptedLVMBackup "$src" "$dst"
			true
			;;
		*)
			echo Unknown type found: $type
			exit 1
			;;
	esac
}

function checkFlags()
{
	test -e "$FLAGDIR/yearly" && ENABLE_YEARLY=yes
	test -e "$FLAGDIR/monthly" && ENABLE_MONTHLY=yes
	test -e "$FLAGDIR/weekly" && ENABLE_WEEKLY=yes
	test -e "$FLAGDIR/daily" && ENABLE_DAILY=yes
	
	if [ -z "$ENABLE_YEARLY$ENABLE_MONTHLY$ENABLE_WEEKLY$ENABLE_DAILY" ]; then
		exit 0
	fi
}

function checkConnectivity()
{
	if ! ssh root@$HOST 'true'; then
		echo "Could not connect to server $HOST, stopping now."
		exit 1
	fi
}

function rotate_abstract()
{
	let red=$3-1
	cat <<- EOF | ssh root@$HOST 'bash'
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
			mv '$1.$3' remove
			upper=$3
		else
			# A hole (or early ending of the sequence) was detected. Fill only the next entry/gap.
			upper=\$hole
		fi
		
		# Do the rotation itself
		for i in \`seq \$upper -1 1\`
		do
			let im=\$i-1
			mv "$1.\$im" "$1.\$i"
		done
		
		# Use the underlying backup as the first one
		mv '$2' '$1.0'
		
		# Eventually remove the temporary backup
		test \$holeFound -eq 0 && rm -rf remove
		
# 		sleep 0.5
	EOF
}

function rotate_yearly()
{
	rotate_abstract yearly monthly.11 10
	rm "$FLAGDIR/yearly"
}

function rotate_monthly()
{
	rotate_abstract monthly weekly.3 11
	rm "$FLAGDIR/monthly"
}

function rotate_weekly()
{
	rotate_abstract weekly daily.6 3
	rm "$FLAGDIR/weekly"
}

function rotate_daily()
{
	rotate_abstract daily sync 6
	rm "$FLAGDIR/daily"
}

function create_backup()
{
	cat "$BACKUPTAB" | sed 's@#.*@@;s@^[ \t]*$@@;/^$/d' | while read line
	do
		parseTabLine $line
	done
	
	rotate_daily
}


function finish()
{
	rm -f /tmp/backup.lock
}

exec {flock_id}> /tmp/backup.lock
flock -n ${flock_id}
ret=$?

if [ $ret -ne 0 ]; then
	# TODO exit 0 or 1?
	exit 0
fi

# Enable the trap only after the check of the lock is finished. Otherwise some nasty effects might happen every even time...
trap finish EXIT

checkFlags
# checkConnectivity

test -n "$ENABLE_YEARLY" && rotate_yearly
test -n "$ENABLE_MONTHLY" && rotate_monthly
test -n "$ENABLE_WEEKLY" && rotate_weekly
test -n "$ENABLE_DAILY" && create_backup

# Check for rotation

# process

flock -u $flock_id
# rm /tmp/backup.lock
