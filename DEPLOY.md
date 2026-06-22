# Triển khai thủ công trên VPS (Ubuntu/Debian, không Docker)

Tài liệu này dựng PostgreSQL 18 + schema trong `initdb/` **trực tiếp trên VPS**, làm bằng tay đúng
những gì Docker tự động làm. Schema là PostgreSQL 18 chuẩn nên chạy **y như Docker**.

Tham chiếu cấu hình gốc: [docker-compose.dev.yaml](docker-compose.dev.yaml) (env + `command:`) và
[Dockerfile](Dockerfile) (gói `postgresql-18-partman`).

---

## 0. Docker vs cài thủ công — cái nào nặng hơn?

Trên Linux, Docker **không phải máy ảo** — Postgres chạy gần như native, **hiệu năng query gần như y hệt**.
Khác biệt chỉ ở phần nền:

| | Docker | Thủ công |
|---|---|---|
| RAM nền | + ~100–300MB cho `dockerd`/`containerd` | Không có |
| Disk | + ~200MB image | Chỉ gói apt |
| Phụ thuộc | Cần cài Docker Engine | Không |
| Cấu hình/cập nhật | Đóng gói sẵn, dễ tái lập | Tự quản |

→ VPS nhỏ hoặc không muốn cài Docker: **cài thủ công nhẹ hơn rõ**, đổi lại bạn tự lo cấu hình.

---

## 1. Cài PostgreSQL 18 (PGDG repo)

```bash
sudo apt update && sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh   # thêm repo PGDG (nhấn Y)
sudo apt update && sudo apt install -y postgresql-18
systemctl status postgresql        # kiểm tra đang chạy
```

- File cấu hình: `/etc/postgresql/18/main/postgresql.conf`
- Data dir: `/var/lib/postgresql/18/main`

---

## 2. Tạo database + user (thay cho biến env của Docker)

Docker tạo `admin`/`pgdb` từ `POSTGRES_USER`/`POSTGRES_DB`. Làm tay:

```bash
sudo -u postgres psql <<'EOF'
CREATE ROLE admin WITH LOGIN SUPERUSER PASSWORD 'secret';   -- SUPERUSER để CREATE EXTENSION + COPY
CREATE DATABASE pgdb OWNER admin;
EOF
```

> `admin` cần **SUPERUSER** vì `001` tạo extension `pgcrypto`, `003` tạo `pg_partman`, và `005` dùng
> `COPY ... FROM` (đọc file phía server). Hai lệnh `ALTER DATABASE pgdb SET datestyle/timezone` đã nằm sẵn đầu `001`.

---

## 3. Cài pg_partman + cấu hình background worker (KHUYẾN NGHỊ làm ngay)

```bash
sudo apt install -y postgresql-18-partman
```

Thêm cấu hình BGW (tương đương block `command:` của docker-compose). Dùng `conf.d` cho gọn:

```bash
sudo tee /etc/postgresql/18/main/conf.d/pg_partman.conf >/dev/null <<'EOF'
shared_preload_libraries = 'pg_partman_bgw'
pg_partman_bgw.dbname    = 'pgdb'
pg_partman_bgw.interval  = 3600          # 1 giờ/lần (prod). Docker để 10 chỉ hợp dev.
pg_partman_bgw.role      = 'admin'
EOF

sudo systemctl restart postgresql        # shared_preload_libraries BẮT BUỘC restart
```

> ⚠️ `shared_preload_libraries` chỉ nạp khi **khởi động** → đây là lý do không thể bật BGW mà không restart.

---

## 4. Chạy schema theo đúng thứ tự

Đặt CSV nơi postgres đọc được (mặc định `005` đọc `/tmp`), rồi chạy 4 file bằng `psql`:

```bash
cd /đường/dẫn/repo
cp data/*.csv /tmp/                       # hoặc dùng -v csv_*=... ở bước seed

export PGPASSWORD=secret
PSQL="psql -h localhost -U admin -d pgdb -v ON_ERROR_STOP=1"

$PSQL -f initdb/001_init.sql              # core RBAC: bảng, index, FK, view
$PSQL -f initdb/002_trigger.sql           # trigger updated_at + audit (đã che secret)
$PSQL -f initdb/003_partition.sql         # pg_partman: partition tháng + retention 1 năm
$PSQL -f initdb/004_test.sql              # ERP: item master, WMS, MRP, lệnh SX, giá vốn
$PSQL -f initdb/005_seed.sql              # seed Super Admin + permissions
$PSQL -f initdb/006_erp_seed.sql          # seed danh mục ERP (uom/item/kho/BOM) — xem ERP.md
$PSQL -f initdb/007_erp_demo.sql          # (TUỲ CHỌN) dữ liệu demo 1 vòng SX — prod có thể bỏ
```

CSV ở thư mục khác? Override (không cần sửa file):

```bash
$PSQL -v csv_users=/srv/seed/users.csv -v csv_roles=/srv/seed/roles.csv \
      -v csv_permissions=/srv/seed/permissions.csv \
      -v csv_role_permissions=/srv/seed/role_permissions.csv \
      -v csv_user_roles=/srv/seed/user_roles.csv \
      -f initdb/005_seed.sql
```

> Thứ tự `001 → 002 → 003 → 004 → 005 → 006 → 007` là bắt buộc (giống Docker chạy `docker-entrypoint-initdb.d`).
> `003` đã được bọc **idempotent** nên chạy lại không lỗi. `006/007` là seed ERP (chạy 1 lần);
> `007` chỉ là dữ liệu demo — bỏ qua nếu lên production. Giải thích mô hình + truy vấn mẫu: [ERP.md](ERP.md).

---

## 5. (Tuỳ chọn) Hoãn pg_partman — cài SAU

Nếu chưa muốn cài partman, vẫn chạy được DB **nhưng phải tạo DEFAULT partition tạm**, vì `audit_logs`
là bảng partition và **bảng partition chưa có partition nào sẽ từ chối mọi INSERT** (trigger audit gắn cho mọi
bảng → seed/tạo user sẽ fail nếu thiếu).

```bash
# Bỏ qua bước 3 và file 003. Chạy 001, 002 rồi:
$PSQL -c "CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;"
$PSQL -f initdb/004_test.sql           # ERP schema
$PSQL -f initdb/005_seed.sql           # DB ghi được ngay; audit rows nằm ở audit_logs_default
$PSQL -f initdb/006_erp_seed.sql       # seed danh mục ERP
$PSQL -f initdb/007_erp_demo.sql       # (tuỳ chọn) demo
```

Khi rảnh, **cài partman sau**:

```bash
# 1) Cài gói + cấu hình BGW như Mục 3, rồi: sudo systemctl restart postgresql
# 2) Xử lý default tạm TRƯỚC khi create_parent (chọn 1 trong 2):

# (A) Chấp nhận xoá log cũ trong default:
$PSQL -c "DROP TABLE audit_logs_default;"
$PSQL -f initdb/003_partition.sql

# (B) Giữ log cũ:
$PSQL -c "ALTER TABLE audit_logs DETACH PARTITION audit_logs_default;"
$PSQL -f initdb/003_partition.sql
$PSQL -c "INSERT INTO audit_logs SELECT * FROM audit_logs_default;"   # đẩy log cũ vào partition tháng
$PSQL -c "DROP TABLE audit_logs_default;"
```

> Phải xử lý default trước vì `create_parent` của partman tự tạo default riêng — không thể có 2 default,
> và không thể gắn partition tháng đè lên dữ liệu đang nằm trong default.

---

## 6. Kiểm tra (verify)

```bash
$PSQL -c "SELECT partition_interval, retention, retention_keep_table
          FROM partman.part_config WHERE parent_table='public.audit_logs';"   # 1 mon | 1 year | f

$PSQL -c "SELECT inhrelid::regclass FROM pg_inherits
          WHERE inhparent='audit_logs'::regclass ORDER BY 1;"                 # partition theo tháng _pYYYYMM01

# Audit đã che secret? (kỳ vọng ***REDACTED***)
$PSQL -c "SELECT new_data->>'password_hash' FROM audit_logs
          WHERE table_name='users' AND action='INSERT' LIMIT 1;"

# Seed đủ?
$PSQL -c "SELECT count(*) FROM permissions;"                                  # 54
```

---

## 7. Vận hành & bảo mật

- **Autostart:** `sudo systemctl enable postgresql`
- **Cho phép kết nối ngoài (nếu cần):** sửa `listen_addresses` trong `postgresql.conf` + thêm dòng vào
  `pg_hba.conf` (ưu tiên `scram-sha-256`), rồi `sudo systemctl reload postgresql`. Mở firewall cổng 5432 có kiểm soát.
  Chi tiết + SSH tunnel: [BACKUP.md §3](BACKUP.md).
- **Backup định kỳ + khôi phục + truy cập DB từ xa:** xem [BACKUP.md](BACKUP.md) — script `scripts/backup.sh` + cron, dùng được cả Docker lẫn thủ công.
- **pg_partman BGW:** đừng để `pg_partman_bgw.interval` quá thấp ở prod (10 giây là cho dev); `3600` là hợp lý.
- **Đổi mật khẩu mặc định** `admin`/`secret` trước khi lên production.
