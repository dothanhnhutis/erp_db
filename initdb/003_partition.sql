
-- Tạo các partition theo tháng (Nên dùng cronjob hoặc pg_partman để tạo tự động)
-- CREATE TABLE audit_logs_2026_04 PARTITION OF audit_logs FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
-- CREATE TABLE audit_logs_2026_05 PARTITION OF audit_logs FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

-- 1. Tạo schema cho pg_partman (khuyên dùng)
CREATE SCHEMA IF NOT EXISTS partman;

-- 2. Kích hoạt extension (Cần quyền Superuser hoặc Owner)
CREATE
EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

-- Khởi tạo partman cho audit_logs.
-- Bọc idempotent: an toàn khi chạy lại, hoặc khi cài partman SAU (xem DEPLOY.md).
DO
$$
    BEGIN
        IF NOT EXISTS (SELECT 1
                       FROM partman.part_config
                       WHERE parent_table = 'public.audit_logs') THEN
            PERFORM partman.create_parent(
                    p_parent_table := 'public.audit_logs', -- Tên bảng cha (Schema.Table)
                    p_control := 'changed_at', -- Cột dùng để phân vùng
                    p_interval := '1 month', -- Kích thước mỗi phân vùng (mỗi partition = 1 tháng)
                    p_premake := 3 -- Số lượng partition tương lai cần tạo sẵn
                    );
        END IF;
    END
$$;

-- ==========================================================
-- Retention: giữ 1 năm, hết hạn DROP hẳn partition (thu hồi disk).
-- pg_partman_bgw (bật trong docker-compose) tự thực thi khi chạy maintenance — không cần cron riêng.
-- ==========================================================
UPDATE partman.part_config
SET retention            = '1 year',
    retention_keep_table = false   -- false = DROP partition cũ; true = chỉ detach (vẫn giữ disk)
WHERE parent_table = 'public.audit_logs';

