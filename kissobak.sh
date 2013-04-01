#!/bin/bash
(( ${BASH_VERSION%%.*}>=4 )) || {
 echo 'Must be run under BASH version 4 or higher!' >&2
 exit 1
}

declare -A slf=(
	[NAME]=${0##*/}
	[PATH]=$(dirname $(readlink -e "$0"))
)

while getopts 'TDR' k; do
 case $k in
  T) flTestOut='| cat -' ;;
  D) set -x 		 ;;
  R) flReplicaMode=1 	 ;;
  *) : 			 ;;
 esac
done
shift $((OPTIND-1))

WHAT2DO=${1:-base}
LOG_FILE='/var/log/postgresql/backup.log'
DEBUG_LEVEL=info
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
  eval "$(read_ini $f)"  
 done < <(find ${OurConfig%/*}/clients -type f -name '*.ini')
fi

source "${slf[PATH]}/${slf[NAME]%.*}.inc"

case $WHAT2DO in
base)
 [[ $2 ]] || { error_ 'We dont know, from where and what to copy'; exit 1; }
 if [[ $2 =~ \@ ]]; then 
  IFS='@:' read User RemoteHost Dir2Copy <<<"$2"
 else
  RemoteHost="$2"
  eval "User=\${INI$RemoteHost[login_from_server]}; Dir2Copy=\${INI$RemoteHost[pgdata]}"
 fi 
 TS="$(date +%Y%m%d_%H%M%S)"
 info_ "We requested to get base copy from $RemoteHost, BackupID: $TS"
 OurDestPath="${INIserver[backup_path]}/$RemoteHost/base/$TS"
 ${flTestOut+echo }mkdir -p "$OurDestPath"
 info_ "We was requested to get base copy from $RemoteHost, $Dir2Copy. We are going to place this copy in $OurDestPath"
 ${flTestOut+echo }ssh $User@$RemoteHost "psql <<<\"SELECT pg_start_backup('$TS', true);\""
 _errc="$(${flTestOut+echo }rsync -a --exclude-from=${OurConfig%/*}/exclude.lst $User@$RemoteHost:${Dir2Copy%/}/ $OurDestPath 2>&1 >/dev/null)"
 (( $? )) && error_ "Some problem while RSYNC, description given: ${_errc}"
 ${flTestOut+echo }ssh $User@$RemoteHost "psql <<<'SELECT pg_stop_backup();'" 
  eval "LoginAs=\${INI$RemoteHost[login_to_server]-$(whoami)}"
  if [[ $flReplicaMode ]]; then
   eval "cat <<EOF ${flTestOut->$OurDestPath/recovery.conf}
standby_mode = 'on'
trigger_file = '/tmp/postgresql.trigger.5432'
restore_command = 'scp ${LoginAs}@${INIserver[hostname]}:${INIserver[backup_path]}/$RemoteHost/wals/%f %p'
archive_cleanup_command = '${INIserver[archive_cleanup_command]-/opt/PostgreSQL/current/bin/pg_archivecleanup} ${INIserver[backup_path]}/$RemoteHost/wals %r'
EOF
"
  else
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
 eval "nBaseBaks2Keep=\${INI$RemoteHost[n_base_backups]:-2}"
 lstBaseBackups=($(ls "${INIserver[backup_path]}/$RemoteHost/base" | sed -nr '/^[0-9]{8}_[0-9]{6}$/p' | sort -rn))
 if (( ${#lstBaseBackups[@]}>nBaseBaks2Keep )); then
  errc=0
  for ((i=nBaseBaks2Keep; i<${#lstBaseBackups[@]}; i++)); do
   bb=${lstBaseBackups[$i]}
   doCleanWALs "${INIserver[backup_path]}/$RemoteHost/base/$bb/backup_label" -n &>/dev/null
   (( errc+=$? ))
  done
  (( errc )) || {
   pushd "$(pwd)" &>/dev/null
   cd "${INIserver[backup_path]}/$RemoteHost/base"
   rm -rf ${lstBaseBackups[@]:$nBaseBaks2Keep}
   popd &>/dev/null
   doCleanWALs "${INIserver[backup_path]}/$RemoteHost/base/${lstBaseBackups[$((nBaseBaks2Keep-1))]}/backup_label" 2>/dev/null
  }
 fi
# $0 tail_clean
;;
tail_clean)
 RemoteHost="$2"
 bb=$(ls "${INIserver[backup_path]}/$RemoteHost/base" | sed -nr '/^[0-9]{8}_[0-9]{6}$/p' | sort -n | head -1)
 [[ $bb ]] && doCleanWALs "${INIserver[backup_path]}/$RemoteHost/base/$bb/backup_label"
;;
*)
 info_ "Sorry, operation \"$WHAT2DO\" N.I.Y"
;;
esac
