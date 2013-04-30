doCleanWALs () {
 local pthBackupLabel="$1"; shift
 local pthWALstorage="$(dirname $pthBackupLabel)/../../wals" idStartWAL
 [[ -d $pthWALstorage ]] || return 1
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
 find "$dir" -type d -regextype posix-extended  -regex '.*/[0-9]{8}_[0-9]{6}' -exec test -f {}/backup_label \; -print | \
  sed "s%^${dir}/%%" | \
   sort -rn
 return $?
}
