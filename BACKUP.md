# Backup định kỳ & truy cập DB từ xa

Áp dụng cho **cả 2 trường hợp VPS: có Docker và cài thủ công**. Bổ sung cho [DEPLOY.md](DEPLOY.md).

---

## 0. Có cần extension nào không?

**Không.** PostgreSQL có sẵn các tool (đi kèm bản cài, không phải extension):

- `pg_dump` / `pg_restore` — sao lưu/khôi phục **logical** (1 database, linh hoạt). **Dùng cái này.**
- `pg_dumpall` — kèm role/permission toàn cụm.
- `pg_basebackup` + WAL archiving — sao lưu **physical** / khôi phục theo thời điểm (PITR), cho production lớn.

Việc "định kỳ" do **cron** (hoặc systemd timer) lo. Các tuỳ chọn nâng cao (không bắt buộc): `pg_cron`
(lập lịch *trong* DB), `pgBackRest`/`wal-g`/`pg_probackup` (backup + PITR cấp production) — là phần mềm rời, không phải extension.

---

## 1. Backup bằng `scripts/backup.sh`

Script [scripts/backup.sh](scripts/backup.sh) chạy `pg_dump -Fc` (nén) ra file timestamp, tự xoay vòng (xoá bản cũ hơn `KEEP_DAYS`).
Một script cho cả 2 trường hợp — chọn bằng biến `DOCKER_CONTAINER`.

```bash
chmod +x scripts/backup.sh

# Cài thủ công (host có pg_dump; mật khẩu trong ~/.pgpass):
BACKUP_DIR=/var/backups/pgdb scripts/backup.sh

# Docker (chạy pg_dump trong container):
DOCKER_CONTAINER=postgres_container PGPASSWORD=secret BACKUP_DIR=/var/backups/pgdb scripts/backup.sh
```

Tạo `~/.pgpass` (cho bản thủ công, khỏi lộ mật khẩu trên dòng lệnh):

```bash
echo 'localhost:5432:pgdb:admin:secret' > ~/.pgpass && chmod 600 ~/.pgpass
```

### Lập lịch định kỳ (cron)

```bash
crontab -e
```

Thêm 1 dòng — **2h sáng mỗi ngày**:

```cron
# Cài thủ công:
0 2 * * * BACKUP_DIR=/var/backups/pgdb KEEP_DAYS=14 /opt/app/scripts/backup.sh >> /var/log/pgdb-backup.log 2>&1

# Docker (thay dòng trên):
0 2 * * * DOCKER_CONTAINER=postgres_container PGPASSWORD=secret BACKUP_DIR=/var/backups/pgdb KEEP_DAYS=14 /opt/app/scripts/backup.sh >> /var/log/pgdb-backup.log 2>&1
```

> Thay `/opt/app` bằng đường dẫn repo thật. Cân nhắc `logrotate` cho `/var/log/pgdb-backup.log`.
> Tuỳ chọn khác: **systemd timer** thay cron; với Docker có thể dùng sidecar `prodrigestivill/postgres-backup-local`.

---

## 2. Khôi phục (restore)

⚠️ **Lưu ý riêng schema này:** trigger audit gắn cho *mọi* bảng. Hãy **khôi phục vào một database RỖNG mới**.
pg_dump nạp dữ liệu **trước** khi tạo trigger, nên restore vào DB mới sẽ KHÔNG kích hoạt trigger audit
(không sinh log rác, không double-insert). **Đừng** restore data-only đè lên DB đang chạy.

```bash
# Cài thủ công:
createdb -h localhost -U admin pgdb_restore
pg_restore -h localhost -U admin -d pgdb_restore --no-owner /var/backups/pgdb/pgdb_YYYYMMDD_HHMMSS.dump

# Docker:
docker exec postgres_container createdb -U admin pgdb_restore
docker exec -i postgres_container pg_restore -U admin -d pgdb_restore --no-owner < /var/backups/pgdb/pgdb_YYYYMMDD_HHMMSS.dump
```

Xem nội dung 1 bản backup mà không cần restore:

```bash
pg_restore -l /var/backups/pgdb/pgdb_YYYYMMDD_HHMMSS.dump        # hoặc: docker exec -i ... pg_restore -l < file.dump
```

---

## 3. Truy cập database từ xa

> **Không "SSH thẳng vào database".** Database nói chuyện qua cổng 5432 (giao thức riêng), không phải SSH.
> Bạn SSH vào **máy chủ** rồi dùng `psql`, hoặc tạo **SSH tunnel** để tool GUI nối vào. Dưới đây là 3 cách.

### Cách 1 — SSH vào host rồi psql (đơn giản nhất)

```bash
ssh user@vps-ip
# Cài thủ công:
psql -h localhost -U admin -d pgdb
# Docker:
docker exec -it postgres_container psql -U admin -d pgdb
```

### Cách 2 — SSH tunnel (KHUYẾN NGHỊ, để dùng DBeaver/pgAdmin/psql từ laptop)

Không cần mở cổng 5432 ra internet. Trên laptop:

```bash
ssh -N -L 5433:localhost:5432 user@vps-ip
# rồi nối tới localhost:5433
psql -h localhost -p 5433 -U admin -d pgdb
```

- DBeaver / pgAdmin / TablePlus đều có sẵn mục **"SSH tunnel"**: điền host SSH + user/key, còn DB host để `localhost:5432`.
- Hoạt động cho cả Docker (compose map 5432 ra host) lẫn bản thủ công.

### Cách 3 — Mở cổng 5432 ra ngoài (chỉ khi thật cần, phải siết bảo mật)

**Cài thủ công:**

```conf
# postgresql.conf
listen_addresses = '*'
```
```conf
# pg_hba.conf — chỉ IP tin cậy, ép SSL
hostssl  pgdb  admin  <YOUR_IP>/32  scram-sha-256
```
```bash
sudo systemctl reload postgresql
sudo ufw allow from <YOUR_IP> to any port 5432    # firewall chỉ mở cho IP đó
```

**Docker:** `ports: "5432:5432"` mặc định bind `0.0.0.0` → **lộ ra internet nếu firewall mở**.
- Không muốn lộ: đổi thành `127.0.0.1:5432:5432` (chỉ localhost) và dùng SSH tunnel (Cách 2).
- Có chủ đích mở: vẫn giới hạn firewall theo IP, dùng mật khẩu mạnh + SSL.

> ⚠️ **Không bao giờ** mở 5432 cho `0.0.0.0/0`. Ưu tiên SSH tunnel. Luôn đổi mật khẩu mặc định `admin/secret`.
