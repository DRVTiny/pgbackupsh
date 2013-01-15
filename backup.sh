#!/bin/bash -x
exit 0
slf=${0##*/}
RUN_AS_USER='postgres'
USER_HOME="$(getent passwd postgres | cut -d':' -f6)"
[[ $(whoami) == $RUN_AS_USER ]] || {
 echo "This script must be launched with EUID=$RUN_AS_USER, trying to change EUID now..." >&2
 sudo -u $RUN_AS_USER $0
 exit $?
}
err_ () {
 echo "$slf: ERROR: $@" >&2
 return 0
}
source ${0%/*}/backup.inc
# What type of backup we want to do?
what2do=${1:-base}
case "$what2do" in
base)  
  TS="$(date +%Y%m%d_%H%M%S)"
  
  BASEBAK_DIR="${BACKUP2[BASE]}/$TS"
  INCRBAK_DIR="${BACKUP2[INCREMENT]}/$TS"
  
  psql <<<"SELECT pg_start_backup('$TS', true);"
   rsync -a --exclude 'wals' --exclude 'pg_xlog'  --exclude '*~' --exclude '.#*' --exclude 'DEADJOE' ${srcDir}/ $BASEBAK_DIR 2>/dev/null
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
