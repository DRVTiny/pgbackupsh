#!/bin/bash
(( ${BASH_VERSION%%.*}>=4 )) || {
 echo 'Must be run under BASH version 4 or higher!' >&2
 exit 1
}

declare -A slf=(
	[NAME]=${0##*/}
	[PATH]=$(dirname $(readlink -e "$0"))
)

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

if [[ -f $USER_HOME/.pg_backup ]]; then
 source ${USER_HOME}/.pg_backup
else
 source ${slf[PATH]}/backup.inc
fi

[[ -f ${BACKUP2[BASE]}/.dontbackup ]] && {
 error_ 'Backups is prohibited by administrator'
 exit 100
}

if ! [[ -f ${POSTGRES[CONF]} ]]; then
 error_ "PostgreSQL data path (${POSTGRES[DATA_PATH]}) doesnt contain ${POSTGRES[CONF]##*/}, therefore seems to be invalid"
 exit 105
fi

case "$WHAT2DO" in
base)  
  TS="$(date +%Y%m%d_%H%M%S)"
  debug_ "BackupID=Current time stamp: $TS"
  rm -rf ${BACKUP2[BASE]}/* ${BACKUP2[INCREMENT]}/*
  BACKUP2[BASE]+="/$TS"
  BACKUP2[INCREMENT]+="/$TS"
  case ${BACKUP_METHOD[BASE]} in
  pg_basebackup)
   which pg_basebackup &>/dev/null || {
    error_ 'pg_basebackup command not found, check your PATH'
    exit 213
   }
   max_wal_senders=$(sed -nr 's%^\s*max_wal_senders\s*=\s*([0-9]+)\s*(#.*)?$%\1%p' "${POSTGRES[CONF]}")
   if ! (( ${max_wal_senders-0} >= WAL_SENDERS[MIN] )); then
    if ! [[ -w ${POSTGRES[CONF]} ]]; then
     error_ "PostgreSQL config file (${POSTGRES[CONF]}) is not writeable but we need to modify it because max_wal_senders must be >=${WAL_SENDERS[MIN]}"
     exit 106
    fi    
    if [[ $max_wal_senders ]]; then
     (( max_wal_senders < WAL_SENDERS[MIN] )) && \
      sed -ri "s%^(\s*max_wal_senders\s*=\s*)${max_wal_senders}(\s*(#.*)?)$%\1${WAL_SENDERS[DESIRED]}\2%p" "${POSTGRES[CONF]}"
    else
     echo "max_wal_senders = ${WAL_SENDERS[DESIRED]}" >> "${POSTGRES[CONF]}"
    fi
   fi
   pg_basebackup -D ${BACKUP2[BASE]} -Ft -P -Z9 -x -l "$TS" --xlog-method=stream
  ;;
  rsync)
   eval "echo \"SELECT pg_start_backup('$TS', true);\" | ${BACKUP_FROM[HOST]+ssh ${BACKUP_FROM[HOST]} }psql;"
    _errc="$(rsync -a --exclude-from=${slf[PATH]}/exclude.lst ${BACKUP_FROM[HOST]+${BACKUP_FROM[HOST]}:}${POSTGRES[DATA_PATH]}/ ${BACKUP2[BASE]} 2>&1 >/dev/null)"
    (( $? )) && error_ "Some problem while RSYNC, description given: ${_errc}"
   eval "echo \"SELECT pg_stop_backup();\" | ${BACKUP_FROM[HOST]+ssh ${BACKUP_FROM[HOST]} }psql;"
   if [[ ${BACKUP2[ARCHIVE]} ]]; then
    info_ 'Start backup archiving...'
    _errc=$(
     { tar -cj --remove-files -f ${BACKUP2[BASE]}.tbz2 \
                               ${BACKUP2[BASE]} \
                               $([[ -d ${BACKUP2[INCREMENT]} ]] && echo -n ${BACKUP2[INCREMENT]}) && \
       rmdir ${BACKUP2[BASE]}; } 2>&1 >/dev/null
          )
    (( $? )) && error_ "Some error occured while archiving backup: ${_errc}"
   fi   
  ;;
  *) 
   error_ 'Unknown backup method specified, see backup.inc'
   exit 212
  ;;
  esac
;;
save_xlog)
  walsFile="$2"
  [[ $walsFile && -f $walsFile && -r $walsFile ]] || \
   { error_ 'You must specify file to copy and it must be readable'; exit 1; }
  info_ "We requested to copy/save $walsFile"
  case ${BACKUP_METHOD[INCREMENT],,} in
  'local')
    TIMESTAMP=$(getLatestBaseBakTS)
    if [[ $TIMESTAMP ]]; then
     info_ "Base  backup timestamp: $TIMESTAMP"
     DEST_DIR="${BACKUP2[INCREMENT]}/$TIMESTAMP"
     mkdir -p $DEST_DIR
     cp "$2"  $DEST_DIR   
    fi
   ;;
  'remote')
#    scp -q $walsFile ${REMOTE[USER]}@${REMOTE[HOST]}:${REMOTE[PATH]}
    rsync -a $walsFile ${REMOTE[USER]}@${REMOTE[HOST]}:${REMOTE[PATH]}
   ;;
  esac  
;;
esac
