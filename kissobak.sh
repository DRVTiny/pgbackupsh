#!/bin/bash
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
And "command" may be the one of:
                  base HOSTNAME
                  save_xlog FILE
                  rotate HOSTNAME [tail]
EOF
 return 0
}

(( ${BASH_VERSION%%.*}>=4 )) || {
 echo 'Must be run under BASH version 4 or higher!' >&2
 exit 1
}

me=$(readlink -e "$0")
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
while getopts 'TxRh d: l:' k; do
 case $k in
  T) flTestOut='| cat -' ;;
  x) set -x 		 ;;
  R) flReplicaMode=1 	 ;;
  d) DEBUG_LEVEL="$OPTARG" ;;
  l) LOG_FILE="$OPTARG"  ;;
  h) doShowUsage; exit 0 ;;
  *) : 			 ;;
 esac
done
shift $((OPTIND-1))
WHAT2DO=${1:-base}

source /opt/scripts/functions/config.func
{ source /opt/scripts/functions/debug.func && \
  log_open "$LOG_FILE"; } || \
   { echo "${slf[NAME]}: FATAL: No debug - no live!" >&2; exit 1; }

# Search for our wonderful config file in simplest ini format
for OurConfig in {$HOME/.kissobak,/etc/kissobak}/config.ini; do
 [[ -f $OurConfig && -r $OurConfig ]] && break
done
[[ -f $OurConfig && -r $OurConfig ]] || { error_ 'Ooops... Config file not found'; exit 1; }
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

{ source "${slf[REAL]%.*}.inc" || source "${0%.*}.inc"; }  || fatal_ 'Cant find my include file containing important functions'

[[ -f $PID_FILE && -f /proc/$(<$PID_FILE)/cmdline ]] && {
 fatal_ "PID file exists and process ($(<$PID_FILE)) seems to be running"
 exit 151
} || {
 rm -f "$PID_FILE"
 echo "$$" > $PID_FILE
}

case $WHAT2DO in
base)
 [[ $2 ]] || { error_ 'We dont know, from where and what to copy'; exit 1; }
 info_ 'Starting base backup...'
 if [[ $2 =~ \@ ]]; then 
  IFS='@:' read User RemoteHost Dir2Copy <<<"$2"
 else
  RemoteHost="$2"
  eval "User=\${INI$RemoteHost[login_from_server]}; Dir2Copy=\${INI$RemoteHost[pgdata]}; PSQL=\${INI$RemoteHost[psql]:-psql}"
 fi
 debug_ "User=$User, Dir2Copy=$Dir2Copy, PSQL=$PSQL"
 TS="$(date +%Y%m%d_%H%M%S)"
 info_ "We was requested to get base copy from $RemoteHost, BackupID: $TS"
 OurDestPath="${INIserver[backup_path]}/$RemoteHost/base/$TS"
 info_ "We was requested to get base copy from $RemoteHost, $Dir2Copy. We are going to place this copy in $OurDestPath" 
 ${flTestOut+echo }mkdir -p "$OurDestPath" || {
  error_ 'Problem detected while accessing backup directory'
  exit 1
 }
 trap 'pg_backup stop' SIGINT SIGTERM SIGHUP
 pg_backup start || {
  error_ "Coudnot start backup on $RemoteHost. Error=${STDERR}"
  exit 1
 }
 $( [[ $flTestOut ]] && echo 'cat -' || echo 'try' ) \
<<<"rsync -a --exclude-from=${OurConfig%/*}/exclude.lst ${User}@${RemoteHost}:${Dir2Copy%/}/ ${OurDestPath%/}" || {
  error_ "Copy postgresql data directory (${Dir2Copy%/}) from $RemoteHost failed with: \"$STDERR\""
  flCopyDataFailed=1
 } 
 pg_backup stop || {
  error_ "Some problem occured while stopping backup on $RemoteHost. Error=${STDERR}"
  exit 1
 }
# if [[ $flCopyDataFailed ]]; then
#  ${flTestOut+echo }rm -rf "$OurDestPath"
#  exit 1
# fi
 trap "" SIGINT SIGTERM SIGHUP
 eval "LoginAs=\${INI$RemoteHost[login_to_server]-$(whoami)}"
 if [[ $flReplicaMode ]]; then
  info_ 'Creating recovery.conf for replication'
  eval "cat <<EOF ${flTestOut->$OurDestPath/recovery.conf}
standby_mode = 'on'
trigger_file = '/tmp/postgresql.trigger.5432'
restore_command = 'scp ${LoginAs}@${INIserver[hostname]}:${INIserver[backup_path]}/$RemoteHost/wals/%f %p'
archive_cleanup_command = '${INIserver[archive_cleanup_command]-/opt/PostgreSQL/current/bin/pg_archivecleanup} ${INIserver[backup_path]}/$RemoteHost/wals %r'
EOF
"
 else
  info_ 'Creating recovery.conf for backup restoration only'
  eval "cat <<EOF ${flTestOut->$OurDestPath/recovery.conf}
restore_command = 'scp ${LoginAs}@${INIserver[hostname]}:${INIserver[backup_path]}/$RemoteHost/wals/%f %p'
EOF
"   
 fi
;;
save_xlog)
 walsFile="$2"
 [[ $walsFile && -f $walsFile && -r $walsFile ]] || \
 { error_ 'You must specify file to copy and it must be readable'; exit 1; }
 info_ "We requested to copy/save $walsFile to backup host ${INIserver[hostname]}"
 eval "LoginAs=\${INI$HOSTNAME[login_to_server]}"
 ssh ${LoginAs=postgres}@${INIserver[hostname]} "mkdir -p ${INIserver[backup_path]}/$HOSTNAME/wals/"
 rsync -a "$walsFile" $LoginAs@${INIserver[hostname]}:${INIserver[backup_path]}/$HOSTNAME/wals/
;;
rotate)
 RemoteHost="$2"
 SubCmd="$3"
 
 pthHostBaseBaks="${INIserver[backup_path]}/$RemoteHost/base"
 [[ -d $pthHostBaseBaks ]] || {
  error_ "No directory with base backups for host $RemoteHost found: seems, that you never do backups from this one"
  exit 114
 }
 lstBaseBackups=( $(list_bb_in_dir "$pthHostBaseBaks") )
 (( ${#lstBaseBackups[@]} )) || {
  error_ "No base backups found in ${pthHostBaseBaks}, maybe you removed them all or it was created inproperly"
  exit 114
 }
 case $SubCmd in
 tail*)
  doCleanWALs "${pthHostBaseBaks}/${lstBaseBackups[@]:${#lstBaseBackups[@]}-1}/backup_label"
 ;;
 *)
  eval "nBaseBaks2Keep=\${INI$RemoteHost[n_base_backups]:-2}"
  if (( ${#lstBaseBackups[@]}>nBaseBaks2Keep )); then
   errc=0
   for ((i=nBaseBaks2Keep; i<${#lstBaseBackups[@]}; i++)); do
    bb=${lstBaseBackups[$i]}
    doCleanWALs "$pthHostBaseBaks/$bb/backup_label" -n &>/dev/null
    (( errc+=$? ))
   done
   (( errc )) || {
    pushd "$(pwd)" &>/dev/null
    cd "$pthHostBaseBaks"
    rm -rf ${lstBaseBackups[@]:$nBaseBaks2Keep}
    popd &>/dev/null
    doCleanWALs "${pthHostBaseBaks}/${lstBaseBackups[$((nBaseBaks2Keep-1))]}/backup_label" 2>/dev/null
   }
  fi
 ;;
 esac
;;
*)
 info_ "Sorry, operation \"$WHAT2DO\" N.I.Y"
;;
esac
rm -f $PID_FILE
