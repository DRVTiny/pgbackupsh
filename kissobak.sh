#!/bin/bash
shopt -s extglob; set +H

doShowUsage () {
cat <<EOF
kissobak is a very simple and straightforward PostgreSQL backup utility following the classical KISS principles
(C) by DRVTiny, 2013
Usage: ${slf[NAME]} options command

Where "options" can be one of:
[-x] For debug mode
[-T] For test-only mode (works only with command=base)
[-R] To create recovery.conf apropriate for creating hot-standby (instead of usual recovery.conf for simple restore)
[-d (FATAL|ERROR|WARN|INFO|DEBUG)] Specify debug level to write log with 
[-l logfile] Specify path to logfile
[-h] To show this useful message :)
And "command" may be the one of:
 Executive commands:
(server)          base CLIENT_HOSTNAME
Create "base" backup for clientID=CLIENT_HOSTNAME
                  
(client)          save_xlog WAL_FULL_PATH
Send wal segment file from client to server (with optional compression), it must be used as archive_command in postgresql.conf
                  
(client)          restore_xlog WAL_ID
Get wal segment file from server in time of recovery|replication
              
(server)          rotate CLIENT_HOSTNAME [tail]
Remove old base backups and appropriate wal segments

 Informational commands:
(server)          ls [CLIENT_HOSTNAME]
Print the list of base backups available for clientID=CLIENT_HOSTNAME or for all clients

(server)          df
Get information about free disc space on mount point used for backups
EOF
 return 0
}

(( ${BASH_VERSION%%.*}>=4 )) || {
 echo 'Must be run under BASH version 4 or higher!' >&2
 exit 1
}

me=$(readlink -e "$0")
source /opt/scripts/functions/prologue.inc
declare -A slf=(
	[NAME]=${0##*/}
	[PATH]=${0%/*}
	[REAL]=$me
	[REAL_PATH]=${me%/*}
	[REAL_NAME]=${me##*/}
)

(( $# )) || { doShowUsage; exit 0; }
DEBUG_LEVEL=info
LOG_FILE='/var/log/postgresql/backup.log'
PID_FILE='/var/run/kissobak/pidfile'
while getopts 'TxRh d: l: p:' k; do
 case $k in
  T) flTestOut='| cat -' 	;;
  x) set -x 		 	;;
  R) flReplicaMode=1 	 	;;
  d) DEBUG_LEVEL="$OPTARG" 	;;
  l) LOG_FILE="$OPTARG"  	;;
  p) PID_FILE="$OPTARG"  	;;
  h)  doShowUsage; exit 0 	;;
  \?) doShowUsage; exit 1 	;;
 esac
done
shift $((OPTIND-1))
c=0
while [[ $@ ]]; do
 ARGV[$((c++))]="$1"
 shift
done

source /opt/scripts/functions/config.func
source /opt/scripts/functions/debug.func || \
 { echo "${slf[NAME]}: FATAL: No debug - no live!" >&2; exit 1; }
log_open "$LOG_FILE" || \
 error_ "Cant open log file $LOG_FILE, we have to write to STDERR"
 
# Search for our wonderful config file in simplest ini format
for OurConfig in {${USER_HOME:=$(getent passwd $(whoami) | cut -d: -f6)}/.kissobak,/etc/kissobak}/config.ini; do
 [[ -e $OurConfig && -r $OurConfig ]] && break
done
[[ -e $OurConfig && -r $OurConfig ]] || { error_ 'Ooops... Config file not found'; exit 1; }
# ...and read them
eval "$(read_ini $OurConfig)"
if [[ -d ${OurConfig%/*}/clients ]]; then
 while read f; do
  [[ -r $f ]] || continue
  tmp_=$(mktemp /tmp/XXXXXXXXXX)
  eval "$(read_ini $f)" 2>$tmp_ || error_ "Some error while reading $f ini file: $(<${tmp_})"
  rm -f "$tmp_"
 done < <(find ${OurConfig%/*}/clients -type f -name '*.ini')
fi

{ source "${slf[REAL]%.*}.erc" || source "${0%.*}.erc"; }  || \
 { fatal_ 'Cant find my include file containing error codes description'; exit 151; }

{ source "${slf[REAL]%.*}.inc" || source "${0%.*}.inc"; }  || \
 { fatal_ 'Cant find my include file containing important functions'; exit $ERC_INCLF_NOT_FOUND; }

declare -A Need2LockWhenDo=(
 [base]=1
 [ls]=0
 [df]=0
 [save_xlog]=0
 [restore_xlog]=1
 [rotate]=1
)

WHAT2DO=${ARGV[0]:-base}

if (( Need2LockWhenDo[$WHAT2DO] )); then
 [[ -f $PID_FILE && -f /proc/$(<$PID_FILE)/cmdline ]] && {
  fatal_ "PID file exists and process ($(<$PID_FILE)) seems to be running"
  exit $ERC_OP_LOCKED
 } || {
  [[ -f $PID_FILE ]] && debug_ "PID file $PID_FILE already exists, but no corresponding process running, so we are going to reuse it"
  echo "$$" > $PID_FILE || {
   fatal_ 'Cant write to PID file for some (unknown) reason. Maybe SELinux is a shit that break things?'
   exit $ERC_PID_CANT_BE_CREATED   
  }
  lstFiles2Clean+=($PID_FILE)
 }
fi
cmdArchiveCleanup="${INIserver[archive_cleanup_command]-/opt/PostgreSQL/current/bin/pg_archivecleanup}"
cmdTAR=${INIserver[tar_command]:-$(which tar 2>/dev/null || whereis tar | cut -d' ' -f2)}
case $WHAT2DO in
base)
 doBaseBackup ${ARGV[1]} ;;
ls)
 if [[ ${ARGV[1]} ]]; then
  i=0 
  while (( ${#ARGV[$((++i))]} )); do
   echo "Base backups for clientID: '${ARGV[$i]}'"
   list_bb_in_dir "${INIserver[backup_path]}/${ARGV[$i]}/base" | nl
  done
 else
  while read -r d; do
   echo "Base backups for clientID: '${d##*/}'"
   list_bb_in_dir "$d/base" | nl
  done < <(find "${INIserver[backup_path]}/" -maxdepth 1 -mindepth 1 -type d -exec test -d {}/base \; -print)
 fi
;;
df)
 df -h "${INIserver[backup_path]}"
;;
save_xlog)
 doSaveWalSeg ${ARGV[1]} ;;
restore_xlog)
 doRestoreWalSeg ${ARGV[1]} ${ARGV[2]} ;;
rotate)
 doRotateBaseBaks ${ARGV[1]} ${ARGV[2]} ;;
*)
 info_ "Sorry, operation \"$WHAT2DO\" is not implemented yet" ;;
esac
