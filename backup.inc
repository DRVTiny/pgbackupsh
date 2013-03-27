declare -A POSTGRES=(
	[VERSION]=$(postgres -V | cut -d'.' -f1,2 | awk '{print $NF}')
)
POSTGRES[DATA_PATH]=${PGDATA-/var/lib/postgresql/${POSTGRES[VERSION]}}
POSTGRES[CONF]="${POSTGRES[DATA_PATH]}/postgresql.conf"

declare -A BACKUP2=(
	[BASE]="${USER_HOME:=$HOME}/backup/base/${POSTGRES[VERSION]}"
)
BACKUP2[INCREMENT]=${BACKUP2[BASE]/\/base\///increment/}

declare -A WAL_SENDERS=(
	[MIN]=2
	[DESIRED]=10
)

declare -A BACKUP_METHOD=(
	[BASE]='pg_basebackup'
	[INCREMENT]='remote'
)

declare -A REMOTE=(
	[USER]='barman'
	[HOST]='backup.namos.local'
	[PATH]="/var/lib/barman/$(hostname)/incoming"
)

mkdir -p ${BACKUP2[BASE]} ${BACKUP2[INCREMENT]}

getLatestBaseBakTS () {
 ls "${BACKUP2[BASE]}" | \
  sed -nr 's%^([0-9]{8})_([0-9]{6})(\.t(ar(\.([gx7]z|bz2))?|bz2|[gx7]z))?$%\1\2%p' | \
   sort -rn | head -1 | sed -r 's%^([0-9]{8})([0-9]{6})$%\1_\2%'
 return 0
}
