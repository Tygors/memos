# S3 Storage Mode Switching

Switch between MinIO and Backblaze B2 (or any S3-compatible storage) for attachments and database backups using a single environment variable toggle.

## How It Works

The environment variable **`S3_PUBLIC_URL`** acts as the toggle:

- **Not set** → original MinIO / S3 presigned-URL mode (unchanged behavior)
- **Set to a URL** → B2 / public-proxy mode:
  - Attachment ExternalLink uses the given URL instead of a presigned URL
  - The URL's path segment is prepended to the object key (e.g. `/memos` → key becomes `memos/xxx.jpg`)
  - The presign renewal runner is skipped (URLs never expire)
  - Database backup path gains a `/memos-backup/` prefix

## Environment Variables

| Variable | MinIO Mode | B2 Mode |
|---|---|---|
| `S3_PUBLIC_URL` | *(not set)* | `https://your-worker.your-domain.workers.dev/memos` |
| `MINIO_ENDPOINT` | MinIO server URL | B2 S3 endpoint (e.g. `https://s3.us-east-005.backblazeb2.com`) |
| `MINIO_ACCESS_KEY` | MinIO access key | B2 application key ID |
| `MINIO_SECRET_KEY` | MinIO secret key | B2 application key |
| `MINIO_BACKUP_BUCKET` | MinIO bucket (default: `memos-backup`) | B2 bucket (e.g. `my-bucket`) |
| `MINIO_BACKUP_INTERVAL` | Backup interval in seconds (default: `720`) | *(same)* |

> Only `S3_PUBLIC_URL` is **new** — all `MINIO_*` variables already exist. Switching modes means changing their values, not adding new ones.

## Attachments (Go Backend)

Three files changed:

| File | Change |
|---|---|
| `server/router/api/v1/attachment_service.go` | Reads `S3_PUBLIC_URL`. When set, extracts the URL path as a key prefix and uses the URL base for `ExternalLink` instead of generating a presigned URL. |
| `server/runner/s3presign/runner.go` | Returns early when `S3_PUBLIC_URL` is set — public URLs don't need periodic re-signing. |

### Memos UI Configuration

In both modes, configure the storage settings through the Memos admin panel (`Settings → Storage`):

| Field | MinIO | B2 |
|---|---|---|
| Storage Type | `S3` | `S3` |
| Endpoint | MinIO server URL | B2 S3 endpoint |
| Bucket | `memos` | `my-b2-bucket` |
| Access Key | MinIO access key | B2 application key ID |
| Secret Key | MinIO secret key | B2 application key |
| Region | `us-east-1` | B2 region (e.g. `us-east-005`) |
| Path-style | ✅ enabled | ✅ enabled |
| Filepath Template | `assets/{timestamp}_{uuid}_{filename}` | `assets/{timestamp}_{uuid}_{filename}` |

The `Filepath Template` stays the same — the `S3_PUBLIC_URL` path is automatically prepended when set.

### Object Key & URL Example

```
S3_PUBLIC_URL = https://b2-img-bed.tygors-wu.workers.dev/memos

Object key in B2:              memos/assets/1734567890_abc123_image.png
Public URL:                    https://b2-img-bed.tygors-wu.workers.dev/memos/assets/1734567890_abc123_image.png
                                                                                 ^^^^^
                                                    (path from S3_PUBLIC_URL matches B2 key prefix)
```

## Database Backup (entrypoint.sh)

The backup script uses the `MINIO_*` environment variables and `mc` (MinIO Client). Since B2 is S3-compatible, the same `mc` binary works against both.

When `S3_PUBLIC_URL` is set, the backup path changes:

- **MinIO mode:** `<bucket>/memos_prod.db`
- **B2 mode:** `<bucket>/memos-backup/memos_prod.db`

### Backup Path Examples

```
MinIO:
  mc cp backup.db "memos-backup/memos-backup/memos_prod.db"
       └─alias──┘└─bucket───────┘└─key─────────┘
  → Stored in the MinIO "memos-backup" bucket as "memos_prod.db"

B2:
  mc cp backup.db "memos-backup/tryB2InS3Way/memos-backup/memos_prod.db"
       └─alias──┘└─bucket──────────┘└─prefix────┘└─key─────────┘
  → Stored in the B2 "tryB2InS3Way" bucket under the "memos-backup/" prefix
```

### Restore

On first start (no local database file), the script restores from the same path — works correctly in both modes.

## Switching Modes

The only `MINIO_*` variables that need a value change are the credentials (`ENDPOINT`, `ACCESS_KEY`, `SECRET_KEY`) and optionally the backup bucket name. No new variables, no code changes between modes.

### Switch to B2

```bash
# Add the toggle
export S3_PUBLIC_URL="https://your-worker.your-domain.workers.dev/memos"

# Update existing vars with B2 values
export MINIO_ENDPOINT="https://s3.us-east-005.backblazeb2.com"
export MINIO_ACCESS_KEY="your-b2-key-id"
export MINIO_SECRET_KEY="your-b2-application-key"
export MINIO_BACKUP_BUCKET="your-b2-bucket-name"
```

Then update the Memos UI storage settings to point at B2.

### Switch Back to MinIO

```bash
unset S3_PUBLIC_URL

# Restore MinIO values
export MINIO_ENDPOINT="https://your-minio-server.example.com"
export MINIO_ACCESS_KEY="your-minio-access-key"
export MINIO_SECRET_KEY="your-minio-secret-key"
export MINIO_BACKUP_BUCKET="memos-backup"
```

Then update the Memos UI storage settings back to MinIO.

## Migration: Moving Existing Data

To migrate attachments from MinIO to B2, use `rclone` or `mc`:

```bash
# Install mc if needed
curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc

# Configure both endpoints
mc alias set minio-backup https://your-minio.example.com access-key secret-key
mc alias set b2-backup https://s3.us-east-005.backblazeb2.com b2-key-id b2-app-key

# Copy all attachments (add --watch for progress)
mc cp --recursive minio-backup/memos/ b2-backup/your-b2-bucket/memos/

# Copy backup history
mc cp --recursive minio-backup/memos-backup/ b2-backup/your-b2-bucket/memos-backup/
```
