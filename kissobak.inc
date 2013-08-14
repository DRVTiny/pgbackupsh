declare -a lstFiles2Clean
declare -a lstToDoOnExit
cleanOnExit () {
 local i errc=0
 (( ${#lstFiles2Clean[@]} )) && {
  for ((i=0; i<${#lstFiles2Clean[@]}; i++)); do
   if [[ -f ${lstFiles2Clean[$i]} ]]; then
    rm -f "${lstFiles2Clean[$i]}";  ((errc+=$?))
   elif [[ -d ${lstFiles2Clean[$i]} ]]; then
    rm -rf "${lstFiles2Clean[$i]}"; ((errc+=$?))
   else
    error_ "Cant remove ${lstFiles2Clean[$i]} because it's type is unknown"
   fi
  done
 }

 for ((i=0; i<${#lstToDoOnExit[@]}; i++)); do
  source <(echo "${lstToDoOnExit[$i]}")
  ((errc+=$?))
 done

 return $errc
}
trap cleanOnExit EXIT

doCleanWALs () {
 shopt -s extglob
 local pthBaseBackup="${1%/}"; shift
 local pthWALstorage="${pthBaseBackup%/*}/../wals"
 local pthBackupLabel TS idStartWAL
 local f d errc

 [[ -d $pthWALstorage ]] || return 1
 if [[ -d $pthBaseBackup ]]; then
  for d in $pthBaseBackup{,/main}; do
   [[ -f $d/backup_label && $(stat -c %s $d/backup_label) -gt 0 ]] && {
    pthBackupLabel="$d/backup_label"
    break
   }
  done
  if ! [[ ! $pthBackupLabel && -f "${pthBaseBackup}.lbl" ]]; then
   pthBackupLabel="${pthBaseBackup}.lbl"
  else
   return $ERC_NO_BACKUP_LABEL
  fi
 elif [[ -f $pthBaseBackup ]]; then
  pthBackupLabel=${pthBaseBackup%%.+([^/])}
  TS=${pthBackupLabel##*/}
  pthBackupLabel+='.lbl'  
  if ! [[ -f $pthBackupLabel ]]; then
   errc=0
   for f in $TS{,/main}/backup_label; do
    $cmdTAR -xf $pthBaseBackup $f -C /tmp 2>/dev/null && break
    (( errc++ ))
   done
   (( errc==2 )) && return $ERC_NO_BACKUP_LABEL  
   pthBackupLabel="/tmp/$f"
   lstFiles2Clean+=("/tmp/$TS")
  fi
 fi
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
 find "$dir" -regextype posix-extended -regex '.*/[0-9]{8}_[0-9]{6}(\.(tar\.bz2|tbz2|tar\.gz|tgz))?' \( \( -type d -a -exec test -f {}/backup_label -o -f {}/main/backup_label \; \) -o -type f \) -print | \
  sed "s%^${dir}/%%" | \
   sort -rn
 return $?
}

chkWalFile () {
local walFile="$1"
local walID=${walFile##*/}
local sign5
local STD_SIGN5='d0710007'
 [[ $walID =~ \.backup$ ]] && \
  debug_ "File $walFile seems to be backup label"
 walID=${walID%%.*}
 if ! [[ $walID =~ ^[0-9A-F]{24}$ ]]; then
  error_ "walID='$walID' seems to be invalid (it must be ~ [0-9A-F]{24})!"
 elif [[ $walFile =~ \.backup$ ]]; then
  [[ $(head -c18 "$walFile") == 'START WAL LOCATION' ]] || {
   error_ "File $walFile seems to be backup label, but it's format is invalid"
   return 1
  }
 else 
  sign5=$(head -c2 "$walFile" | hexdump | head -1 | cut -d' ' -f2- | tr -d ' ')
  [[ $sign5 == ${STD_SIGN5:0:4} ]] || \
   warn_ "File $walFile may be (but may be not) invalid, because it contain signature '$sign5' instead of expected '${STD_SIGN5:0:4}'"
 fi
 return 0
}

doBaseBackup () {
 local RemoteHost="$1"
 local User Dir2Copy PSQL
 local TID flCopyDataFailed TS OurDestPath
 [[ $RemoteHost ]] || { error_ 'We dont know, from where and what to copy'; return $ERC_MAND_PAR_MISS; }
 info_ "Starting base backup from $RemoteHost..."
 if [[ $RemoteHost =~ \@ ]]; then 
  IFS='@:' read User RemoteHost Dir2Copy <<<"$RemoteHost"
 else
  eval "User=\${INI$RemoteHost[login_from_server]}; Dir2Copy=\${INI$RemoteHost[pgdata]}"
 fi
 eval "PSQL=\${INI$RemoteHost[psql]:-psql}"

 debug_ "User=$User, Dir2Copy=$Dir2Copy, PSQL=$PSQL"

 TS="$(date +%Y%m%d_%H%M%S)"
 OurDestPath="${INIserver[backup_path]}/$RemoteHost/base/$TS"
 info_ "BackupID: $TS; Destination path on backup server: ${OurDestPath}."
 ${flTestOut+echo }mkdir -p "$OurDestPath" || {
  error_ 'Problem detected while accessing backup directory'
  return $ERC_ACCESS_DENIED_FILE_OP
 }

 TID=${#lstToDoOnExit[@]}
 lstToDoOnExit+=('pg_backup stop')
 pg_backup start || {
  error_ "Couldnot start backup on $RemoteHost. Error=${STDERR}"
  return $ERC_START_BACKUP_FAIL
 }

 $( [[ $flTestOut ]] && echo 'cat -' || echo 'try' ) \
<<<"rsync -a --exclude-from=${OurConfig%/*}/exclude.lst ${User}@${RemoteHost}:${Dir2Copy%/}/ ${OurDestPath%/}" || {
  error_ "Copy postgresql data directory (${Dir2Copy%/}) from $RemoteHost failed with: \"$STDERR\""
  flCopyDataFailed=1
 }
 
 if pg_backup stop; then
  unset lstToDoOnExit[$TID]
 else
  error_ "Some problem occured while stopping backup on $RemoteHost. Error=${STDERR}"
  return $ERC_STOP_BACKUP_FAIL
 fi
 
 eval "local LoginAs=\${INI$RemoteHost[login_to_server]-$(whoami)}"
 debug_ "Now let's create empty pg_xlog subdirectory inside base backup (because it must exist in time of restoration)"
 mkdir "$OurDestPath/pg_xlog"
 local SSHConnPar="${LoginAs}@${INIserver[hostname]}"
 local WALsHere="${INIserver[backup_path]}/$RemoteHost/wals"
 [[ $flTestOut ]] || exec 3<&1 1>"$OurDestPath/recovery.conf"
 cat <<EOF
restore_command = '$(basename $0 .sh) restore_xlog %f %p'
archive_cleanup_command = 'ssh $SSHConnPar $cmdArchiveCleanup "$WALsHere" %r'
EOF
 if [[ $flReplicaMode ]]; then
  cat <<EOF
standby_mode = 'on'
trigger_file = '/tmp/postgresql.trigger.5432'
EOF
 fi
 if [[ $flTestOut ]]; then
  return 0
 else
  exec 1<&3
 fi
 cp $OurDestPath/backup_label ${OurDestPath}.lbl || cp $OurDestPath/main/backup_label ${OurDestPath}.lbl
 if eval "[[ \${INI$RemoteHost[compress_bb],,} =~ ^(yes|true|1)$ ]]"; then
  info_ 'We was requested to compress base backup and we proud to announce that we can do that since august 2013!'
  if try <<EOF
cd "${OurDestPath%/*}"
$cmdTAR -cj --remove-files -f ${TS}.tar.bz2 ${TS}
EOF
  then
   rm -rf "$OurDestPath"
  else
   error_ "Cant move $OurDestPath into tar archive, reason: $STDERR"
   return $ERC_ZIP_BACKUP_FAIL
  fi
 fi
 return 0
}

doSaveWalSeg () {
 local walsPath="$1"
 [[ $walsPath && -e $walsPath && -r $walsPath ]] || \
  { error_ 'You must specify file to copy, it must exists and it must be readable'; return $ERC_MAND_PAR_MISS; }
 local walsName=${walsPath##*/}
 local backupServer=${INIserver[hostname]}
 local tmpFile
 info_ "We requested to copy/save $walsPath to backup host $backupServer" 
 
 chkWalFile "$walsPath" || { fatal_ 'Wal segment is invalid!'; return $ERC_INVALID_WALS; }

 if eval [[ \${INI$HOSTNAME[compress_xlog]}\${INI$HOSTNAME[compress_xlogs]} ]]; then
  tmpFile=$(mktemp /tmp/XXXXXXXXXXXXXXXXXXXXXXX)
  lstFiles2Clean+=($tmpFile)
  bzip2 --best -c "$walsPath" > $tmpFile
  walsPath="$tmpFile"
 fi 
 
 eval "local LoginAs=\${INI$HOSTNAME[login_to_server]}"
 if ! try <<EOF
 ssh ${LoginAs=postgres}@${backupServer} "mkdir -p ${INIserver[backup_path]}/$HOSTNAME/wals/" && \
  rsync -a "$walsPath" $LoginAs@$backupServer:${INIserver[backup_path]}/$HOSTNAME/wals/$walsName
EOF
 then
  fatal_ "Cant copy WAL file to remote location. STDERR=\"$STDERR\""
  return $ERC_COPY_WAL_SRV_FAIL
 fi
 return 0
}

doRestoreWalSeg () {
 local srcFile="${1##*/}"
 local dstPath="${2%/}"
 [[ -d $dstPath ]] && dstPath+="/$srcFile"
 
 eval "local LoginAs=\${INI$HOSTNAME[login_to_server]}"
 if ! try <<EOF
  scp "$LoginAs@${INIserver[hostname]}:${INIserver[backup_path]}/$HOSTNAME/wals/$srcFile" "$dstPath"
EOF
 then
  fatal_ "Cant get wal file $srcFile from backup server ${INIserver[hostname]}. STDERR='$STDERR'"
  return $ERC_COPY_WAL_CLI_FAIL
 fi
 
 local zipCmd=$(file "$dstPath" 2>&1 | sed -nr 's%^[^ ]*: %%; s% compressed data.*$%%p') tmpFile
 if [[ $zipCmd ]]; then
  tmpFile=$(mktemp /tmp/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX)
  lstFiles2Clean+=($tmpFile)
  
  if ! try <<EOF
$zipCmd -cd "$dstPath" > $tmpFile
EOF
  then
   rm -f "$dstPath"
   fatal_ "Cant unpack file '$dstPath' with '$zipCmd' archiver, maybe it is damaged. STDERR='$STDERR'"
   return $ERC_UNZIP_WAL_FAIL
  else
   mv $tmpFile "$dstPath"
  fi
 else
  info_ "File '$dstPath' is not compressed"
 fi
 return 0
}

doRotateBaseBaks () {
 local RemoteHost="$1" SubCmd="$2" 
 local pthHostBaseBaks="${INIserver[backup_path]}/$RemoteHost/base"
 [[ -d $pthHostBaseBaks ]] || {
  error_ "No directory with base backups for host $RemoteHost found: seems, that you never do backups from this one"
  return $ERC_NO_BB_DIR
 }
 local lstBaseBackups=( $(list_bb_in_dir "$pthHostBaseBaks") )
 (( ${#lstBaseBackups[@]} )) || {
  error_ "No base backups found in ${pthHostBaseBaks}, maybe you removed them all or it was created inproperly"
  return $ERC_NO_BB_FOUND
 }
 case $SubCmd in
 tail*)
  doCleanWALs "${pthHostBaseBaks}/${lstBaseBackups[0]}"
 ;;
 *)
  eval "local nBaseBaks2Keep=\${INI$RemoteHost[n_base_backups]:-2}"
  if (( ${#lstBaseBackups[@]}>nBaseBaks2Keep )); then
   local errc=0 i
   for ((i=nBaseBaks2Keep; i<${#lstBaseBackups[@]}; i++)); do
    doCleanWALs "$pthHostBaseBaks/${lstBaseBackups[$i]}" -n &>/dev/null
    (( errc+=$? ))
   done
#   (( errc )) || {
    pushd "$(pwd)" &>/dev/null
    cd "$pthHostBaseBaks"
    rm -rf ${lstBaseBackups[@]:$nBaseBaks2Keep}
    popd &>/dev/null
    doCleanWALs "${pthHostBaseBaks}/${lstBaseBackups[$((nBaseBaks2Keep-1))]}" 2>/dev/null
#   }
  fi
 ;;
 esac
 return 0
}
