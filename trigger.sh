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
	rsync $RSYNC_OPT "$src" "root@$HOST:$dst"
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
	
	while read -d, i
	do
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

function process()
{
	
	cat "$BACKUPTAB" | sed 's@#.*@@;s@^[ \t]*$@@;/^$/d' | while read line
	do
		parseTabLine $line
	done
	
}

# Check connectivity

process
