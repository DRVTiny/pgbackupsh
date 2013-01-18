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

RUN_AS_USER='postgres'

err_ () {
 echo "${slf[NAME]}: ERROR: $@" >&2
 return 0
}

[[ $(whoami) == $RUN_AS_USER ]] || {
 err_ "This script must be launched with EUID=$RUN_AS_USER, trying to change EUID now..." >&2
 sudo -u $RUN_AS_USER $0
 exit $?
}

which postgres &>/dev/null || {
 err_ '"postgres" command not found, check that it is in your PATH!'
 exit 101
}

USER_HOME=${USER_HOME-$(getent passwd $RUN_AS_USER | cut -d':' -f6)}
source ${slf[PATH]}/backup.inc

[[ -f ${BACKUP2[BASE]}/.dontbackup ]] && {
 err_ 'Backups is prohibited by administrator'
 exit 100
}

case "$WHAT2DO" in
base)  
  TS="$(date +%Y%m%d_%H%M%S)"
  
  BASEBAK_DIR="${BACKUP2[BASE]}/$TS"
  INCRBAK_DIR="${BACKUP2[INCREMENT]}/$TS"
  
  psql <<<"SELECT pg_start_backup('$TS', true);"
   rsync -a --exclude-from=exclude.lst ${POSTGRES[DATA_PATH]}/ ${BASEBAK_DIR} 2>/dev/null
  psql <<<"SELECT pg_stop_backup();"
  
  tar -cj --remove-files -f ${BASEBAK_DIR}.tbz2 ${BASEBAK_DIR} $([[ -d $INCRBAK_DIR ]] && echo -n $INCRBAK_DIR) && \
   rmdir $BASEBAK_DIR 2>/dev/null
   
;;
save_xlog)
 [[ $2 && -f $2 && -r $2 ]] || { err_ 'You must specify file to copy'; exit 1; }
 TIMESTAMP=$(getLatestBaseBakTS)
 DEST_DIR="${BACKUP2[INCREMENT]}/${TIMESTAMP:-00000000_000000}"
 mkdir -p $DEST_DIR
 cp "$2"  $DEST_DIR
;;
esac
