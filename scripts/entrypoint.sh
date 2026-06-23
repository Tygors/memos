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
    if mc alias set memos-backup "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null 2>&1; then
        echo "MinIO backup alias configured successfully for bucket: $BACKUP_BUCKET"
    else
        echo "WARNING: Failed to configure MinIO backup alias at $MINIO_ENDPOINT" >&2
    fi

    # Restore latest backup if no local database exists
    if [ ! -f "$DATA_DIR/memos.db" ]; then
        latest=$(mc ls "memos-backup/$BACKUP_BUCKET/" 2>/dev/null | sort -r | head -1 | awk '{print $NF}')
        if [ -n "$latest" ]; then
            echo "Restoring from backup: $latest"
            mc cp "memos-backup/$BACKUP_BUCKET/$latest" "$DATA_DIR/memos.db" >/dev/null 2>&1 || echo "WARNING: failed to restore from backup" >&2
        fi
    fi

    # Background backup loop (default: every 720 seconds = 12 minutes)
    (
        while true; do
            sleep "${MINIO_BACKUP_INTERVAL:-720}"
            echo "Running scheduled MinIO backup..."
            mc cp "$DATA_DIR/memos.db" "memos-backup/$BACKUP_BUCKET/memos.db" >/dev/null 2>&1 && echo "Scheduled backup complete" || echo "WARNING: scheduled backup failed" >&2
        done
    ) &

    # Watch for the on-demand backup trigger written by the Go server
    # when a new memo is created.  Poll every 60 seconds.
    TRIGGER_FILE="/tmp/memos-backup-trigger"
    (
        while true; do
            sleep 60
            if [ -f "$TRIGGER_FILE" ]; then
                rm -f "$TRIGGER_FILE"
                echo "Triggered MinIO backup (new memo)..."
                mc cp "$DATA_DIR/memos.db" "memos-backup/$BACKUP_BUCKET/memos.db" >/dev/null 2>&1 && echo "Triggered backup complete" || echo "WARNING: triggered backup failed" >&2
            fi
        done
    ) &
fi

exec "$@"
