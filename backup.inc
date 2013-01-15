dbName='namos'

POSTGRES_VER=$(postgres -V | cut -d'.' -f1,2 | awk '{print $NF}')
srcDir=$POSTGRES_VER

declare -A BACKUP2
BACKUP2[BASE]="${USER_HOME:=$HOME}/backup/base/$srcDir"
BACKUP2[INCREMENT]="${USER_HOME:=$HOME}/backup/increment/$srcDir"
mkdir -p ${BACKUP2[BASE]} ${BACKUP2[INCREMENT]}

getLatestBaseBakTS () {
 ls "${BACKUP2[BASE]}" | \
  sed -nr 's%^([0-9]{8})_([0-9]{6})(\.t(ar(\.([gx7]z|bz2))?|bz2|[gx7]z))?$%\1\2%p' | \
   sort -rn | head -1 | sed -r 's%^([0-9]{8})([0-9]{6})$%\1_\2%'
 return 0
}
