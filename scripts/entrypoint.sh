#!/usr/bin/env sh

# Fix ownership of data directory for users upgrading from older versions
# where files were created as root
MEMOS_UID=${MEMOS_UID:-10001}
MEMOS_GID=${MEMOS_GID:-10001}
DATA_DIR="/var/opt/memos"

if [ "$(id -u)" = "0" ]; then
    # Running as root, fix permissions and drop to nonroot
    if [ -d "$DATA_DIR" ]; then
        chown -R "$MEMOS_UID:$MEMOS_GID" "$DATA_DIR" 2>/dev/null || true
    fi
    exec su-exec "$MEMOS_UID:$MEMOS_GID" "$0" "$@"
fi

file_env() {
   var="$1"
   fileVar="${var}_FILE"

   val_var="$(printenv "$var")"
   val_fileVar="$(printenv "$fileVar")"

   if [ -n "$val_var" ] && [ -n "$val_fileVar" ]; then
      echo "error: both $var and $fileVar are set (but are exclusive)" >&2
      exit 1
   fi

   if [ -n "$val_var" ]; then
      val="$val_var"
   elif [ -n "$val_fileVar" ]; then
      if [ ! -r "$val_fileVar" ]; then
         echo "error: file '$val_fileVar' does not exist or is not readable" >&2
         exit 1
      fi
      val="$(cat "$val_fileVar")"
   fi

   export "$var"="$val"
   unset "$fileVar"
}

file_env "MEMOS_DSN"

# MinIO backup/restore for SQLite persistence
# Only runs when using SQLite (default) and MinIO credentials are configured
if command -v mc >/dev/null 2>&1 && [ -n "$MINIO_ENDPOINT" ] && [ -n "$MINIO_ACCESS_KEY" ] && [ -n "$MINIO_SECRET_KEY" ]; then
    BACKUP_BUCKET="${MINIO_BACKUP_BUCKET:-memos-backup}"
    mc alias set memos-backup "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null 2>&1

    # Restore latest backup if no local database exists
    if [ ! -f "$DATA_DIR/memos.db" ]; then
        latest=$(mc ls "memos-backup/$BACKUP_BUCKET/" 2>/dev/null | sort -r | head -1 | awk '{print $NF}')
        if [ -n "$latest" ]; then
            echo "Restoring from backup: $latest"
            mc cp "memos-backup/$BACKUP_BUCKET/$latest" "$DATA_DIR/memos.db" >/dev/null 2>&1
        fi
    fi

    # Background backup loop (default: every 3600 seconds = 1 hour)
    (
        while true; do
            sleep "${MINIO_BACKUP_INTERVAL:-3600}"
            ts=$(date +%Y%m%d%H%M)
            mc cp "$DATA_DIR/memos.db" "memos-backup/$BACKUP_BUCKET/memos-${ts}.db" >/dev/null 2>&1
            # Keep only the latest 168 backups (7 days at hourly)
            mc ls "memos-backup/$BACKUP_BUCKET/" 2>/dev/null | sort -r | tail -n +169 | awk '{print $NF}' | while read -r f; do
                mc rm "memos-backup/$BACKUP_BUCKET/$f" >/dev/null 2>&1
            done
        done
    ) &
fi

exec "$@"
