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

do_backup() {
    sqlite3 "$DATA_DIR/memos_prod.db" ".backup $DATA_DIR/.backup_tmp" && \
    mc cp "$DATA_DIR/.backup_tmp" "memos-backup/$BACKUP_BUCKET/memos_prod.db" >/dev/null 2>&1 && \
    rm -f "$DATA_DIR/.backup_tmp"
}

# MinIO backup/restore for SQLite persistence
# Only runs when using SQLite (default) and MinIO credentials are configured
if command -v mc >/dev/null 2>&1 && [ -n "$MINIO_ENDPOINT" ] && [ -n "$MINIO_ACCESS_KEY" ] && [ -n "$MINIO_SECRET_KEY" ]; then
    BACKUP_BUCKET="${MINIO_BACKUP_BUCKET:-memos-backup}"
    if mc alias set memos-backup "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null 2>&1; then
        echo "MinIO backup alias configured successfully for bucket: $BACKUP_BUCKET"
    else
        echo "WARNING: Failed to configure MinIO backup alias at $MINIO_ENDPOINT" >&2
    fi

    # Restore backup if no local database exists
    if [ ! -f "$DATA_DIR/memos_prod.db" ]; then
        if mc stat "memos-backup/$BACKUP_BUCKET/memos_prod.db" >/dev/null 2>&1; then
            echo "Restoring from backup: memos_prod.db"
            mc cp "memos-backup/$BACKUP_BUCKET/memos_prod.db" "$DATA_DIR/memos_prod.db" >/dev/null 2>&1 || echo "WARNING: failed to restore from backup" >&2
        fi
    fi

    # Scheduled backup (default: every 720 seconds = 12 minutes)
    (
        while true; do
            sleep "${MINIO_BACKUP_INTERVAL:-720}"
            echo "Running scheduled backup..."
            do_backup && echo "Scheduled backup complete" || echo "WARNING: scheduled backup failed" >&2
        done
    ) &

    # Triggered backup (poll every 60s)
    TRIGGER_FILE="/tmp/memos-backup-trigger"
    (
        while true; do
            sleep 60
            if [ -f "$TRIGGER_FILE" ]; then
                rm -f "$TRIGGER_FILE"
                echo "Triggered backup..."
                do_backup && echo "Triggered backup complete" || echo "WARNING: triggered backup failed" >&2
            fi
        done
    ) &
fi

# Run memos in background so we can trap shutdown signals
"$@" &
MEMOS_PID=$!

trap 'echo "Shutting down, running final backup..."; do_backup; echo "Final backup complete"; kill $MEMOS_PID 2>/dev/null; exit 0' TERM INT

wait $MEMOS_PID
