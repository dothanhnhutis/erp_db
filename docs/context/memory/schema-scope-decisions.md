---
name: schema-scope-decisions
description: "vide-db-postgres schema — edit conventions, what's hardened, and what remains optional"
metadata: 
  node_type: memory
  type: project
  originSessionId: b71bd957-6d9f-46d7-8a2a-bdbde595a2c2
---

`vide-db-postgres` là schema PostgreSQL 18 (init qua `initdb/` + docker-compose, pg_partman cho `audit_logs`) quản lý **tài khoản – RBAC – phiên đăng nhập**.

**Quy ước:** project init-from-scratch (chưa production) → sửa **in-place** trong `001_init.sql`/`002_trigger.sql`, KHÔNG viết ALTER migration. Verify bằng `docker compose -f docker-compose.dev.yaml down -v && up --build -d` (init chỉ chạy lại khi xoá volume). Lưu ý log init luôn có 1 dòng `FATAL: database "pgdb" does not exist` — là race vô hại của pg_partman BGW, KHÔNG phải lỗi.

**Triển khai:** ngoài Docker còn có `DEPLOY.md` (runbook cài thủ công Ubuntu/Debian PGDG). `003` đã bọc create_parent idempotent; `005` đọc CSV qua biến psql (default `/tmp`, override `-v csv_*=...`). pg_partman có thể cài SAU nếu tạo `audit_logs_default` tạm (bảng partition chưa có partition sẽ từ chối INSERT) — chi tiết trong DEPLOY.md.

**Backup/Access:** `BACKUP.md` + `scripts/backup.sh` (pg_dump -Fc + cron, chạy cả Docker lẫn thủ công qua env `DOCKER_CONTAINER`; backup KHÔNG cần extension). **Restore phải vào DB rỗng mới** (trigger audit gắn mọi bảng; pg_dump nạp data trước khi tạo trigger nên không fire) — đã verify restore 0 lỗi. `docker-compose.dev.yaml` đã bind `127.0.0.1:5432:5432` (remote dùng SSH tunnel).

**Đã hardening (2026-06, đã verify trên DB thật):**
- Vá init hỏng (xoá index mồ côi warehouse); tiện ích quản lý phiên (`last_seen_at`, `idx_user_sessions_active`, view `active_user_sessions`).
- `user_sessions` loại khỏi trigger audit; `fn_generic_audit_log` **che secret theo tên cột** (`password_hash`/`token_hash`/`password`/`secret`/`refresh_token` → `***REDACTED***`, giữ key).
- CHECK enum: `chk_users_status`, `chk_roles_status`, `chk_user_sessions_device_type` (dùng CHECK, KHÔNG native ENUM — đồng nhất convention).
- `uq_roles_name` (partial unique), index chiều ngược `role_permissions(permission_id)`/`user_roles(role_id)`, `uq_user_avatars_one_primary`, FK + index `files.uploaded_by`.
- `audit_logs`: partition theo **THÁNG** + **retention 1 năm (drop)** trong `003_partition.sql` (`part_config.retention='1 year'`, `retention_keep_table=false`); pg_partman 5.4.3 BGW (interval 10s) tự dọn. Prod nên nâng `pg_partman_bgw.interval`.

**Còn lại OPTIONAL (chưa làm — chỉ đề xuất nếu user hỏi):**
- Override quyền trực tiếp theo user (mở rộng RBAC ngoài role) — user đã từng để ngoài phạm vi.
- Cosmetic: `username` chưa unique.

**How to apply:** khi đụng vùng đã hardening, không cần làm lại. Với mục optional, chỉ nhắc ngắn, không tự thêm.
