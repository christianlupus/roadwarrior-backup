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

print_help() {
	cat << EOF
$0: Set the flags for the various backup levels.

Possible parameters are:
	--daily, -d     Enable the daily backup that will cause a new backup and afterwards rotation of the daily backups
	--weekly, -w    Enable the weekly backup rotation
	--monthly, -m   Enable the monthly backup rotation
	--yearly, -y    Enable the yearly backup rotation
	
	--help, -h    Print this help message
EOF
}

## Add a flag to the flags folder
##
## $1 The name of the flag to be generated
enable_flag() {
	file="$FLAGDIR/$1"
	
	test -e "$file" && echo "Warning: flag $1 exists already!"
	
	touch "$file"
}

enable_daily() {
	enable_flag daily
}

enable_weekly() {
	enable_flag weekly
}

enable_monthly() {
	enable_flag monthly
}

enable_yearly() {
	enable_flag yearly
}

reset_locks() {
	rm -f "$FLAGDIR/"{daily,weekly,monthly,yearly}
}

assert_no_reset()
{
	if [ -n "$RESET_LOCKS" ]; then
		echo "Cannot set and reset flags at the same time. Aborting" >&2
		exit 1
	fi
}

assert_no_set() {
	if [ -n "$ENABLE_DAILY$ENABLE_MONTHLY$ENABLE_WEEKLY$ENABLE_YEARLY" ]; then
		echo "Cannot set and reset flags at the same time. Aborting" >&2
		exit 1
	fi
}

## Remove the lock file on termination of the script
## 
## This must not be called if the lock could not be aquired.
## Oterwise, we could steal the file and on next invocation the lock is no longer visible.
finish()
{
	flock -u ${flock_id}
	rm -f $LOCK_FILE
}

# Try to get the lock on a certain file
exec {flock_id}> $LOCK_FILE
flock -n ${flock_id}
ret=$?

if [ $ret -ne 0 ]; then
	echo "Could not get flock on $LOCK_FILE. Blocking until lock can be aquired..." 
	flock ${flock_id}
	echo "Got the lock"
fi

# Enable the trap only after the check of the lock is finished. Otherwise some nasty effects might happen every even time, when removing a file (with active lock) while backup is still running...
trap finish EXIT

ENABLE_DAILY=
ENABLE_WEEKLY=
ENABLE_MONTHLY=
ENABLE_YEARLY=
RESET_LOCKS=

while test $# -gt 0
do
	case "$1" in
		--help|-h)
			print_help
			;;
		--daily|-d)
			assert_no_reset
			ENABLE_DAILY=yes
			;;
		--weekly|-w)
			assert_no_reset
			ENABLE_WEEKLY=yes
			;;
		--monthly|-m)
			assert_no_reset
			ENABLE_MONTHLY=yes
			;;
		--yearly|-y)
			assert_no_reset
			ENABLE_YEARLY=yes
			;;
		--reset)
			assert_no_set
			RESET_LOCKS=yes
			;;
		*)
			echo "Unknown parameter found: $1" >&2
			echo
			
			print_help
			exit 1
			;;
	esac
	
	shift
done

test -n "$ENABLE_DAILY" && enable_daily
test -n "$ENABLE_WEEKLY" && enable_weekly
test -n "$ENABLE_MONTHLY" && enable_monthly
test -n "$ENABLE_YEARLY" && enable_yearly
test -n "$RESET_LOCKS" && reset_locks
exit 0
