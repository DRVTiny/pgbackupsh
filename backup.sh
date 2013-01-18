#!/bin/bash -x
(( ${BASH_VERSION%%.*}>=4 )) || {
 echo 'Must be run under BASH version 4 or higher!' >&2
 exit 1
}

declare -A slf
slf[NAME]=${0##*/}
slf[PATH]=$(dirname $(readlink -e "$0"))
# What type of backup we want to do?
WHAT2DO=${1:-base}
LOG_FILE='/var/log/postgresql/backup.log'
DEBUG_LEVEL=info
RUN_AS_USER='postgres'

source /opt/scripts/functions/debug.func
log_open '/var/log/postgresql/backup.log' 
[[ $(whoami) == $RUN_AS_USER ]] || {
 error_ "This script must be launched with EUID=$RUN_AS_USER, trying to change EUID now..."
 sudo -u $RUN_AS_USER $0
 exit $?
}

which postgres &>/dev/null || {
 error_ '"postgres" command not found, check that it is in your PATH'
 exit 101
}

USER_HOME=${USER_HOME-$(getent passwd $RUN_AS_USER | cut -d':' -f6)}
source ${slf[PATH]}/backup.inc

[[ -f ${BACKUP2[BASE]}/.dontbackup ]] && {
 error_ 'Backups is prohibited by administrator'
 exit 100
}

case "$WHAT2DO" in
base)  
  TS="$(date +%Y%m%d_%H%M%S)"
  debug_ "BackupID=Current time stamp: $TS"
  BACKUP2[BASE]+="/$TS"
  BACKUP2[INCREMENT]+="/$TS"
  
  psql <<<"SELECT pg_start_backup('$TS', true);"
   _errc="$(rsync -a --exclude-from=exclude.lst ${POSTGRES[DATA_PATH]}/ ${BACKUP2[BASE]} 2>&1 >/dev/null)"
   (( $? )) && error_ "Some problem while RSYNC, description given: ${_errc}"
  psql <<<'SELECT pg_stop_backup();'
  
  info_ 'Start backup archiving...'
  _errc=$(
    { tar -cj --remove-files -f ${BACKUP2[BASE]}.tbz2 \
                              ${BACKUP2[BASE]} \
                              $([[ -d ${BACKUP2[INCREMENT]} ]] && echo -n ${BACKUP2[INCREMENT]}) && \
      rmdir ${BACKUP2[BASE]}; } 2>&1 >/dev/null
         )
  (( $? )) && error_ "Some error occured while archiving backup: ${_errc}"
   
;;
save_xlog)  
  [[ $2 && -f $2 && -r $2 ]] || { error_ 'You must specify file to copy and it must be readable'; exit 1; }
  info_ "We requested to copy/save $2"
  TIMESTAMP=$(getLatestBaseBakTS)
  info_ "Base  backup timestamp (00000000_000000 if base backups is absent): ${TIMESTAMP:-00000000_000000}"
  DEST_DIR="${BACKUP2[INCREMENT]}/${TIMESTAMP:-00000000_000000}"
  mkdir -p $DEST_DIR
  cp "$2"  $DEST_DIR
;;
esac
