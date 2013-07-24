doCleanWALs () {
 local pthBaseBackup="${1%/}"; shift
 local pthWALstorage="$pthBaseBackup/../../wals"
 local pthBackupLabel idStartWAL
 local d

 [[ -d $pthBaseBackup ]] || return 1
 [[ -d $pthWALstorage ]] || return 2

 for d in $pthBaseBackup{,/main}; do
  [[ -f $d/backup_label && $(stat -c %s $d/backup_label) -gt 0 ]] && {
   pthBackupLabel="$d/backup_label"
   break
  }
 done
 [[ $pthBackupLabel ]] || return 3
 
 idStartWAL=$(sed -nr 's%^.+\(file\s([0-9A-F]+)\)\s*$%\1%p' "$pthBackupLabel" 2>/dev/null) && \
  [[ $idStartWAL && -f $pthWALstorage/$idStartWAL ]] && \
   ${INIserver[archive_cleanup_command]-/opt/PostgreSQL/current/bin/pg_archivecleanup} $@ "$pthWALstorage" $idStartWAL
 return $?
}

pg_backup () {
  [[ $1 =~ ^st(art|op)$ ]] || return 1
  declare -A cmd=([start]="pg_start_backup('$TS', true)" [stop]='pg_stop_backup()')
  try <<EOF
${flTestOut+echo }ssh $User@$RemoteHost "echo \"SELECT ${cmd[$1]};\" | $PSQL"
EOF
  return $?
}

list_bb_in_dir () {
 local dir="$1"
 find "$dir" -type d -regextype posix-extended  -regex '.*/[0-9]{8}_[0-9]{6}' -exec test -f {}/backup_label -o -f {}/main/backup_label \; -print | \
  sed "s%^${dir}/%%" | \
   sort -rn
 return $?
}

chkWalFile () {
local walFile="$1"
local walID=${walFile##*/}
 [[ $walID =~ \.backup$ ]] && \
  debug_ "File $walFile seems to be backup label"
 walID=${walID%%.*}
 if ! [[ $walID =~ ^[0-9A-F]{24}$ ]]; then
  error_ "walID='$walID' seems to be invalid (it must be ~ [0-9A-F]{24})!"
 elif [[ $walFile =~ \.backup$ && ! $(head -c18 "$walFile") == 'START WAL LOCATION' ]]; then
  error_ "File $walFile seems to be backup label, but it's format is invalid"
  return 1
 elif ! [[ $(head -c4 "$walFile" | hexdump | head -1 | cut -d' ' -f2- | tr -d ' ') == 'd0710007' ]]; then
  error_ "File $walFile seems to be invalid, because it contains wrong signature"
 fi
 return 0
}
