#!/usr/bin/env bash

# set -x
set -o pipefail

DST_HOST=some.host
LOG_DIR=log
LOG_EXT=.log

if [ -n "`env | grep TERM=`" ]; then
    LOG_ECHO=true
else
    LOG_ECHO=false
fi


# Cfg
CFG_DIR=cfg
BACKUP_DIR=/backup_storage # on a remote system
ARCHIVE_DATE_MASK=+%Y-%m-%d_%H-%M-%S
LOG_MSG_DATE_MASK="+%Y-%m-%d %H:%M:%S %Z"
UMASK=0007
MYSQLDUMP_TMP_DIR=/tmp
DB_ARCH_NAME_EXT=.gz
SSH_TPL="ssh -q DST_USER@DST_HOST"
RSYNC_OPT="--verbose --progress"
RSYNC_TPL="nice -n 19 ionice -c 3 rsync RSYNC_OPT -aR --compress --delete --perms --chmod=g+rw,o-rwx,Du+rwx,Dg+rwx,Do-rwx,D-t -e \"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\" EXCLUDE SRC DST_USER@DST_HOST:DST_DIR"
MYSQL_CMD=mysql
MYSQL_GET_ALL_DB_NAMES_TPL="MYSQL_CMD --host=MYSQL_HOST --user=MYSQL_USER --password=MYSQL_PASS --skip-column-names -e \"show databases\""
MYSQLDUMP_CMD=mysqldump
MYSQLDUMP_TPL="MYSQLDUMP_CMD --host=MYSQL_HOST --user=MYSQL_USER --password=MYSQL_PASS --skip-lock-tables --quick --extended-insert --disable-keys --databases DB_NAME | gzip -c --best > DB_ARCH_NAME"
POST_CMD_TPL='eval grep --color=never "Error: \| - Start$\| - Use the config\| - Work with the dir\| - Dump the DB\| - Finish$\|rsync error" LOG_FILE | ./send_xmpp.sh > /dev/null 2>&1'
KEEP_LAST_BACKUPS=5
KEEP_FIRST_BY_UNIQ_STR_PART=8 # Backups look 2017-01-01_15-02-02, 2017-02-01_15-02-03. First 8 symbols are markers to keep backup (For example "2017-01-" and "2017-02-")
# End Cfg


# $1 - (string) message
# $2 - (boolean, default true) print date/time
# $3 - (boolean, default true) print end of line
log() {
    if [ "$2" == false ]; then
        MSG=
    else
        MSG="`date '+%Y-%m-%d %H:%M:%S,%3N %Z'` - "
    fi

    MSG=${MSG}${1}

    if [ "$3" == false ]; then
        ECHO_OPT=-n
    else
        ECHO_OPT=
    fi

    if [ ${LOG_ECHO} == true ]; then
        echo ${ECHO_OPT} "$MSG"
    fi

    echo ${ECHO_OPT} "$MSG" >> "$LOG_FILE"
}


if [ -z "$1" ]; then
    echo "Usage: $0 config_file"
    echo "Config directory: $CFG_DIR"
    echo "Exit"
    exit 1
else
    CFG=$1
fi

SOURCE_FILE="$CFG_DIR/$CFG"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "Can't read the file: $SOURCE_FILE"
    exit 2
fi

. "$SOURCE_FILE"

if [ $? -ne 0 ]; then
    echo "Failed to source the file: $SOURCE_FILE. Exit 1"
    exit 1
fi

umask "$UMASK"
DT=`date "$ARCHIVE_DATE_MASK"`
LOG_DIR="$LOG_DIR/$CFG"
LOG_FILE=${LOG_DIR}/${DT}${LOG_EXT}

# Create log dir
if [ ! -d "$LOG_DIR" ]; then
    CMD="mkdir -p $LOG_DIR"
    ${CMD}
    log "(Created log dir, ran: $CMD)"
fi
# End

log "Start"
log "Use the config: $SOURCE_FILE"

if [ ! -f "$SOURCE_FILE" ]; then
    log "This configuration doesn't exist. Exit"
    exit 3
fi

BACKUP_ROOT_DIR="$BACKUP_DIR/$CFG"
BACKUP_DIR="$BACKUP_ROOT_DIR/$DT"
log "New backup dir is: $BACKUP_DIR"

if [ -n "$SSH_TPL" ]; then
    SSH_CMD="$SSH_TPL"
    SSH_CMD=${SSH_CMD//DST_USER/${DST_USER}}
    SSH_CMD=${SSH_CMD//DST_HOST/${DST_HOST}}
    SSH_PRE_CMD="$SSH_CMD '"
    SSH_POST_CMD="'"
else
    SSH_CMD=
    SSH_PRE_CMD=
    SSH_POST_CMD=
fi

CMD="${SSH_PRE_CMD}ls $BACKUP_ROOT_DIR 2> /dev/null${SSH_POST_CMD} | sort"
log "Find latest backup, run: $CMD"
BACKUPS_LIST=`eval ${CMD}`
LAST_BACKUP_DIR=`echo "$BACKUPS_LIST" | tail -n 1`

if [ -z "$LAST_BACKUP_DIR" ]; then
    log "Latest backup not found"
    CMD="${SSH_PRE_CMD}umask $UMASK; mkdir -p $BACKUP_DIR${SSH_POST_CMD}"
    log "Create destination directory, run: $CMD"
    eval ${CMD}

    if [ $? -ne "0" ]; then
        log "Failed to create the directory. Exit"
        exit 1
    fi
else
    LAST_BACKUP_DIR="$BACKUP_ROOT_DIR/$LAST_BACKUP_DIR"
    log "Found latest backup: $LAST_BACKUP_DIR"

    CMD="${SSH_PRE_CMD}nice -n 19 ionice -c 3 cp -al $LAST_BACKUP_DIR $BACKUP_DIR${SSH_POST_CMD}"
    log "Copying data from latest to new backup, run: $CMD"
    eval ${CMD}
    log "Copy finished"
fi

for DIRS_ITERATOR in "${!DIRS[@]}"; do
    DIR=${DIRS[$DIRS_ITERATOR]}
    log "Work with the dir: $DIR"

    RSYNC_CMD="$RSYNC_TPL"
    RSYNC_CMD=${RSYNC_CMD//RSYNC_OPT/${RSYNC_OPT}}
    RSYNC_CMD=${RSYNC_CMD//SRC/${DIR}}
    RSYNC_CMD=${RSYNC_CMD//DST_USER/${DST_USER}}
    RSYNC_CMD=${RSYNC_CMD//DST_HOST/${DST_HOST}}
    RSYNC_CMD=${RSYNC_CMD//DST_DIR/${BACKUP_DIR}}

    # Exclude list
    EXCLUDE_CMD=
    DIR_STRLEN=${#DIR}

    for EXCLUDE_ITERATOR in "${!EXCLUDE[@]}"; do
        EXCL=${EXCLUDE[$EXCLUDE_ITERATOR]}

        if [ ${DIR} == ${EXCL:0:${DIR_STRLEN}} ]; then
            if [ -n "$EXCLUDE_CMD" ]; then
                EXCLUDE_CMD="$EXCLUDE_CMD --exclude $EXCL"
            else
                EXCLUDE_CMD="--exclude $EXCL"
            fi
        fi
    done

    if [ -n "$EXCLUDE_CMD" ]; then
        RSYNC_CMD=${RSYNC_CMD//EXCLUDE/${EXCLUDE_CMD}}
    else
        RSYNC_CMD=${RSYNC_CMD//EXCLUDE /}
    fi
    # End

    log "Run rsync: $RSYNC_CMD"
    OUT=`eval "${RSYNC_CMD} 2>&1"`
    log "Output:
$OUT"
    log "Completed the dir: $DIR"
done

# MySQL DBs dump
if [ -n "$MYSQL_HOST" ]; then
    log "DB backup start"

    MYSQL_EXEC="$MYSQL_GET_ALL_DB_NAMES_TPL"
    MYSQL_EXEC=${MYSQL_EXEC//MYSQL_CMD/${MYSQL_CMD}}
    MYSQL_EXEC=${MYSQL_EXEC//MYSQL_HOST/${MYSQL_HOST}}
    MYSQL_EXEC=${MYSQL_EXEC//MYSQL_USER/${MYSQL_USER}}
    MYSQL_EXEC=${MYSQL_EXEC//MYSQL_PASS/${MYSQL_PASS}}

    log "Get all databases name"
    DBS=`eval "${MYSQL_EXEC} 2>&1"`

    if [ $? -ne 0 ]; then
        log "Error: 'Get all databases name' failed. Output: $DBS"
    else
        log "Output:
$DBS"

        DBS=(${DBS})

        for DB in "${DBS[@]}"; do
            log "Dump the DB: $DB"

            DB_ARCH_NAME=${MYSQLDUMP_TMP_DIR}/${DB}${DB_ARCH_NAME_EXT}

            if [ -f "$DB_ARCH_NAME" ]; then
                log "Remove the file: $DB_ARCH_NAME"
                rm -f "$DB_ARCH_NAME"
            fi

            MYSQLDUMP_EXEC="$MYSQLDUMP_TPL"
            MYSQLDUMP_EXEC=${MYSQLDUMP_EXEC//MYSQLDUMP_CMD/${MYSQLDUMP_CMD}}
            MYSQLDUMP_EXEC=${MYSQLDUMP_EXEC//MYSQL_HOST/${MYSQL_HOST}}
            MYSQLDUMP_EXEC=${MYSQLDUMP_EXEC//MYSQL_USER/${MYSQL_USER}}
            MYSQLDUMP_EXEC=${MYSQLDUMP_EXEC//MYSQL_PASS/${MYSQL_PASS}}
            MYSQLDUMP_EXEC=${MYSQLDUMP_EXEC//DB_NAME/${DB}}
            MYSQLDUMP_EXEC=${MYSQLDUMP_EXEC//DB_ARCH_NAME/${DB_ARCH_NAME}}

            OUT=`eval "${MYSQLDUMP_EXEC} 2>&1"`

            if [ $? -eq 0 ] && [ -f "$DB_ARCH_NAME" ]; then
                RSYNC_CMD="$RSYNC_TPL"
                RSYNC_CMD=${RSYNC_CMD//RSYNC_OPT/${RSYNC_OPT}}
                RSYNC_CMD=${RSYNC_CMD//SRC/$DB_ARCH_NAME}
                RSYNC_CMD=${RSYNC_CMD//DST_USER/$DST_USER}
                RSYNC_CMD=${RSYNC_CMD//DST_HOST/$DST_HOST}
                RSYNC_CMD=${RSYNC_CMD//DST_DIR/$BACKUP_DIR}
                RSYNC_CMD=${RSYNC_CMD//EXCLUDE /}

                log "Run rsync: $RSYNC_CMD"
                OUT=`eval "${RSYNC_CMD} 2>&1"`
                log "Output:
$OUT"
                rm -f "$DB_ARCH_NAME"
            else
                log "Error: Backup failed for the DB: '$DB'. Output: $OUT"
            fi

            log "Completed the DB dump: $DB"
        done
    fi

    log "DB backup finish"
fi
# End MySQL DBs dump

log "Finish"

if [ -n "$POST_CMD_TPL" ]; then
    POST_CMD="$POST_CMD_TPL"
    POST_CMD=${POST_CMD//LOG_FILE/${LOG_FILE}}

    log "Run POST_CMD"
    ${POST_CMD}
fi

# Remove old backups
if [ -n "$KEEP_LAST_BACKUPS" ]; then
    log "All backups list:"
    if [ -n "$BACKUPS_LIST" ]; then
        log "$BACKUPS_LIST" false
    else
        log "<empty>" false
    fi

    CANDIDATES_TO_REMOVE=`echo "$BACKUPS_LIST" | head -n -${KEEP_LAST_BACKUPS}`
    log "List without last $KEEP_LAST_BACKUPS backups"
    if [ -n "$CANDIDATES_TO_REMOVE" ]; then
        log "$CANDIDATES_TO_REMOVE" false
    else
        log "<empty>" false
    fi

    KEEP=()
    DELETE=()
    FIRST_BY_UNIQ_STR_PART=

    while read -r CANDIDATE; do
        CANDIDATE_UNIQ_STR_PART="${CANDIDATE:0:$KEEP_FIRST_BY_UNIQ_STR_PART}"

        if [ -z "$FIRST_BY_UNIQ_STR_PART" ] || [ "$FIRST_BY_UNIQ_STR_PART" != "$CANDIDATE_UNIQ_STR_PART" ] ; then
            KEEP+=("$CANDIDATE")
            FIRST_BY_UNIQ_STR_PART="$CANDIDATE_UNIQ_STR_PART"
        else
            DELETE+=("$CANDIDATE")
        fi
    done <<< "$CANDIDATES_TO_REMOVE"

    log "Keep backups list:"
    if [ -n "$KEEP" ]; then
        (IFS=$'\n'; log "${KEEP[*]}" false)
    else
        log "<empty>" false
    fi

    log "Delete backups list:"
    if [ -n "$DELETE" ]; then
        (IFS=$'\n'; log "${DELETE[*]}" false)
        CMD="${SSH_PRE_CMD}cd $BACKUP_ROOT_DIR && rm -rf ${DELETE[*]}${SSH_POST_CMD}"
        log "Delete backups, run: $CMD"
        eval ${CMD}
    else
        log "<empty>" false
    fi
fi
# End Remove old backups
