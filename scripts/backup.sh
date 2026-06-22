#!/usr/bin/env bash
#
# Sao lưu định kỳ database bằng pg_dump (custom format, có nén).
# Một script dùng được cho CẢ HAI trường hợp:
#   - Cài thủ công : ./backup.sh                 (host có pg_dump, mật khẩu trong ~/.pgpass)
#   - Docker       : DOCKER_CONTAINER=postgres_container PGPASSWORD=secret ./backup.sh
#
# Cấu hình qua biến môi trường (đều có mặc định):
#   PGUSER PGDATABASE PGHOST PGPORT BACKUP_DIR KEEP_DAYS DOCKER_CONTAINER PGPASSWORD
#
set -euo pipefail

PGUSER="${PGUSER:-admin}"
PGDATABASE="${PGDATABASE:-pgdb}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pgdb}"
KEEP_DAYS="${KEEP_DAYS:-14}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}"

ts="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/${PGDATABASE}_${ts}.dump"

if [[ -n "$DOCKER_CONTAINER" ]]; then
    # Chạy pg_dump TRONG container rồi stream ra file trên host
    # (host khỏi cần cài postgresql-client, đảm bảo đúng phiên bản).
    docker exec -e PGPASSWORD="${PGPASSWORD:-}" "$DOCKER_CONTAINER" \
        pg_dump -U "$PGUSER" -d "$PGDATABASE" -Fc >"$out"
else
    # Cài thủ công: dùng pg_dump trên host. Mật khẩu nên để trong ~/.pgpass (chmod 600):
    #   localhost:5432:pgdb:admin:secret
    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -Fc -f "$out"
fi

# Không để mất bản tốt khi dump lỗi: chỉ xoay vòng khi dump mới hợp lệ (không rỗng).
if [[ ! -s "$out" ]]; then
    echo "LỖI: file dump rỗng, không xoay vòng." >&2
    rm -f "$out"
    exit 1
fi

# Xoay vòng: xoá các bản cũ hơn KEEP_DAYS ngày.
find "$BACKUP_DIR" -name "${PGDATABASE}_*.dump" -type f -mtime "+${KEEP_DAYS}" -delete

echo "OK $(date '+%F %T') -> $out ($(du -h "$out" | cut -f1))"
