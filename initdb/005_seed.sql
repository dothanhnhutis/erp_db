-- Seed dữ liệu khởi tạo (Super Admin + permissions).
-- Đường dẫn CSV qua biến psql, mặc định /tmp (khớp Docker mount ./data -> /tmp).
-- COPY chạy phía SERVER nên cần superuser (hoặc role pg_read_server_files) và file postgres đọc được.
-- Trên VPS nếu đặt CSV nơi khác, override khi chạy, vd:
--   psql -d pgdb -v csv_users=/srv/seed/users.csv -v csv_roles=/srv/seed/roles.csv ... -f 005_seed.sql
-- (Mỗi \if dưới đây chỉ đặt mặc định khi biến CHƯA được truyền qua -v, nên -v luôn thắng.)
\if :{?csv_users}
\else
    \set csv_users '/tmp/users.csv'
\endif
\if :{?csv_roles}
\else
    \set csv_roles '/tmp/roles.csv'
\endif
\if :{?csv_permissions}
\else
    \set csv_permissions '/tmp/permissions.csv'
\endif
\if :{?csv_role_permissions}
\else
    \set csv_role_permissions '/tmp/role_permissions.csv'
\endif
\if :{?csv_user_roles}
\else
    \set csv_user_roles '/tmp/user_roles.csv'
\endif

COPY users (id, email, password_hash, username, status)
    FROM :'csv_users' WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY roles (id, name, description, status, can_delete, can_update)
    FROM :'csv_roles' WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY permissions (id, code, description)
    FROM :'csv_permissions' WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY role_permissions (role_id, permission_id)
    FROM :'csv_role_permissions' WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY user_roles (user_id, role_id)
    FROM :'csv_user_roles' WITH (FORMAT csv, HEADER true, DELIMITER ',');
