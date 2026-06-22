-- ==========================================================
-- Extension
-- ==========================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- ==========================================================
-- Config
-- ==========================================================
ALTER DATABASE pgdb
    SET
        datestyle = 'ISO, DMY';

ALTER DATABASE pgdb
    SET
        timezone = 'Asia/Ho_Chi_Minh';


-- create user_sessions table
CREATE TABLE user_sessions
(
    id            UUID           NOT NULL DEFAULT uuidv7(),
    user_id       UUID           NOT NULL,
    token_hash    CHAR(64)       NOT NULL UNIQUE,
    device_id     VARCHAR(255),            -- Fingerprint do client tự tạo, dùng để nhận ra "cùng máy" dù đổi IP
    device_name   VARCHAR(255),            -- Human-readable: "Chrome 124 · Windows 11", "MyApp 2.1 · macOS 14"
    device_type   VARCHAR(20)    NOT NULL, -- 'web' | 'desktop' | 'mobile'
    platform      VARCHAR(100),            -- "Windows 11" | "macOS 14.5" | "Ubuntu 22.04"
    app_version   VARCHAR(50),             -- Chỉ có trên desktop app, null với web
    user_agent    TEXT,                    -- Raw User-Agent header, dùng để debug
    ip_address    INET,                    -- IP lúc login, dùng để hiển thị "đăng nhập từ đâu"

    revoked_at    TIMESTAMPTZ(3),
    revoke_reason VARCHAR(20),
    -- 'LOGOUT'  : user tự logout
    -- 'FORCED'  : user logout tất cả thiết bị
    -- 'USER'   : user thu hồi
    -- 'EXPIRED' : cleanup job đánh dấu sau khi hết hạn

    expires_at    TIMESTAMPTZ(3) NOT NULL,
    created_at    TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    last_seen_at  TIMESTAMPTZ(3),          -- hoạt động gần nhất (cập nhật mỗi request; xem ghi chú audit B1)

    CONSTRAINT chk_revoke_reason
        CHECK (revoke_reason IN ('LOGOUT', 'FORCED', 'USER', 'EXPIRED')),
    CONSTRAINT chk_user_sessions_device_type
        CHECK (device_type IN ('web', 'desktop', 'mobile')),
    CONSTRAINT pk_user_sessions PRIMARY KEY (id)
);


-- ==========================================================
-- Danh mục file
-- ==========================================================
CREATE TABLE IF NOT EXISTS files
(
    id            UUID           NOT NULL DEFAULT uuidv7(),
    original_name TEXT           NOT NULL, -- tên file người dùng upload
    mime_type     VARCHAR(100)   NOT NULL, -- loại file
    destination   TEXT           NOT NULL, -- đường dẫn ngắn đến file
    file_name     TEXT           NOT NULL, -- tên file
    path          TEXT           NOT NULL, -- đường dẫn đầy đủ đến file
    size          BIGINT         NOT NULL, -- kích thước file
    uploaded_by   UUID           NOT NULL, -- upload bởi ai
    deleted_at    TIMESTAMPTZ(3),          -- xoá lúc nào
    created_at    TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_files PRIMARY KEY (id)
);

-- ==========================================================
-- audit_logs table
-- ==========================================================
CREATE TABLE IF NOT EXISTS audit_logs
(
    id             UUID         NOT NULL DEFAULT uuidv7(), -- Dùng kiểu UUID thực thụ
    table_name     VARCHAR(100) NOT NULL,
    record_id      TEXT         NOT NULL,
    action         VARCHAR(10)  NOT NULL,                  -- INSERT, UPDATE, DELETE
    old_data       JSONB,
    new_data       JSONB,
    changed_by     TEXT         NOT NULL,
    transaction_id TEXT,
    changed_at     TIMESTAMPTZ(3)        DEFAULT NOW() NOT NULL,
    CONSTRAINT pk_audit_logs PRIMARY KEY (id, changed_at)  -- Phải bao gồm cột phân mảnh
) PARTITION BY RANGE (changed_at);

-- ==========================================================
-- Danh mục quyền và vai trò
-- ==========================================================
CREATE TABLE IF NOT EXISTS permissions
(
    id          UUID           NOT NULL DEFAULT uuidv7(),
    code        VARCHAR(100)   NOT NULL, -- vd: CHEMICAL_CREATE, PO_VIEW
    description TEXT           NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_permissions PRIMARY KEY (id),
    CONSTRAINT permissions_code_unique UNIQUE (code)
);

CREATE TABLE IF NOT EXISTS role_permissions
(
    role_id       UUID           NOT NULL,
    permission_id UUID           NOT NULL,
    created_at    TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_role_permissions PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS roles
(
    id             UUID           NOT NULL DEFAULT uuidv7(),
    name           VARCHAR(255)   NOT NULL,
    description    TEXT           NOT NULL DEFAULT '',
    status         VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE', -- ACTIVE | DEACTIVATED
    deactivated_at TIMESTAMPTZ(3),                           -- vô hiệu hoá lúc nào
    deleted_at     TIMESTAMPTZ(3),                           -- xoá mềm
    can_delete     BOOLEAN        NOT NULL DEFAULT TRUE,
    can_update     BOOLEAN        NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_roles PRIMARY KEY (id),
    CONSTRAINT chk_roles_status CHECK (status IN ('ACTIVE', 'DEACTIVATED'))
);

-- ==========================================================
-- Danh mục người dùng
-- ==========================================================
CREATE TABLE IF NOT EXISTS user_roles
(
    user_id    UUID           NOT NULL,
    role_id    UUID           NOT NULL,
    created_at TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_user_roles PRIMARY KEY (user_id, role_id)
);

CREATE TABLE IF NOT EXISTS users
(
    id                  UUID           NOT NULL DEFAULT uuidv7(),
    email               VARCHAR(255)   NOT NULL,
    password_hash       TEXT,
    username            VARCHAR(100),
    status              VARCHAR(20)    NOT NULL DEFAULT 'PENDING_PASSWORD', -- ACTIVE | DEACTIVATED | PENDING_PASSWORD
    deactivated_at      TIMESTAMPTZ(3),                                     -- vô hiệu hoá lúc nào
    deleted_at          TIMESTAMPTZ(3),                                     -- xoá mềm
    password_changed_at TIMESTAMPTZ(3),                                     -- lần cuối đổi mật khẩu
    created_at          TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT chk_users_pending_password
        CHECK (status = 'PENDING_PASSWORD' OR password_hash IS NOT NULL),
    CONSTRAINT chk_users_status
        CHECK (status IN ('ACTIVE', 'DEACTIVATED', 'PENDING_PASSWORD'))
);

CREATE TABLE IF NOT EXISTS user_avatars
(
    file_id    UUID           NOT NULL,
    user_id    UUID           NOT NULL,
    width      INTEGER        NOT NULL,
    height     INTEGER        NOT NULL,
    is_primary BOOLEAN        NOT NULL DEFAULT FALSE, -- Hình đại diện
    deleted_at TIMESTAMPTZ(3),                        -- xoá lúc nào
    created_at TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_user_avatars PRIMARY KEY (file_id, user_id)
);

CREATE TABLE IF NOT EXISTS password_tokens
(
    id         UUID           NOT NULL DEFAULT uuidv7(),
    user_id    UUID           NOT NULL,
    token_hash TEXT           NOT NULL,
    type       VARCHAR(20)    NOT NULL, -- INIT | RESET_PASSWORD
    expires_at TIMESTAMPTZ(3) NOT NULL,
    used_at    TIMESTAMPTZ(3),
    created_at TIMESTAMPTZ(3) NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_password_tokens PRIMARY KEY (id),
    CONSTRAINT uq_password_tokens_token_hash UNIQUE (token_hash),
    CONSTRAINT chk_password_tokens_type CHECK (type IN ('INIT', 'RESET_PASSWORD'))
);



-- ==========================================================
-- Index
-- ==========================================================

-- create user_sessions index
CREATE INDEX idx_user_revoked ON user_sessions (user_id, revoked_at);
-- liệt kê nhanh phiên đang hoạt động + hỗ trợ "đăng xuất mọi thiết bị khác"
CREATE INDEX idx_user_sessions_active
    ON user_sessions (user_id, expires_at)
    WHERE revoked_at IS NULL;

-- create file index
CREATE INDEX idx_files_deleted_at ON files (deleted_at)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uix_files_path ON files (path)
    WHERE deleted_at IS NULL;

--create audit_logs index
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_record ON audit_logs (table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_tx ON audit_logs (transaction_id);

-- create roles index
CREATE INDEX IF NOT EXISTS idx_roles_status ON roles (status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_roles_name ON roles (name) WHERE deleted_at IS NULL;

-- create users index
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_status ON users (status) WHERE deleted_at IS NULL;

-- create user_avatars index
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_avatars_one_primary
    ON user_avatars (user_id) WHERE is_primary IS TRUE AND deleted_at IS NULL;

-- create password_tokens index
CREATE INDEX idx_password_tokens_user_id ON password_tokens (user_id);
CREATE INDEX idx_password_tokens_expires_at ON password_tokens (expires_at);

-- index chiều ngược cho bảng nối (FK enforcement + "ai có permission/role X")
CREATE INDEX IF NOT EXISTS idx_role_permissions_permission_id ON role_permissions (permission_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role_id ON user_roles (role_id);

-- index cho FK files.uploaded_by
CREATE INDEX IF NOT EXISTS idx_files_uploaded_by ON files (uploaded_by);


-- ==========================================================
-- Khoá ngoại
-- ==========================================================

--- AddForeignKey password_tokens table
ALTER TABLE password_tokens
    ADD CONSTRAINT fk_password_tokens_user_id FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE;

--- AddForeignKey user_sessions table
ALTER TABLE user_sessions
    ADD CONSTRAINT fk_user_sessions_user_id FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE;

-- AddForeignKey role_permissions table
ALTER TABLE role_permissions
    ADD CONSTRAINT fk_role_permissions_role_id FOREIGN KEY (role_id)
        REFERENCES roles (id) ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE role_permissions
    ADD CONSTRAINT fk_role_permissions_permission_id FOREIGN KEY (permission_id)
        REFERENCES permissions (id) ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey user_roles table
ALTER TABLE user_roles
    ADD CONSTRAINT fk_user_roles_user_id FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE user_roles
    ADD CONSTRAINT fk_user_roles_role_id FOREIGN KEY (role_id)
        REFERENCES roles (id) ON DELETE RESTRICT ON UPDATE CASCADE;

--- AddForeignKey user_avatars table
ALTER TABLE user_avatars
    ADD CONSTRAINT fk_user_avatars_user_id FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE user_avatars
    ADD CONSTRAINT fk_user_avatars_file_id FOREIGN KEY (file_id)
        REFERENCES files (id) ON DELETE CASCADE ON UPDATE CASCADE;

--- AddForeignKey files table
ALTER TABLE files
    ADD CONSTRAINT fk_files_uploaded_by FOREIGN KEY (uploaded_by)
        REFERENCES users (id) ON DELETE RESTRICT ON UPDATE CASCADE;


-- ==========================================================
-- View: phiên đăng nhập đang hoạt động (phục vụ "quản lý phiên của tôi")
-- KHÔNG lộ token_hash / user_agent. App PHẢI tự lọc WHERE user_id = <current user>.
-- ==========================================================
CREATE OR REPLACE VIEW active_user_sessions AS
SELECT id,
       user_id,
       device_id,
       device_name,
       device_type,
       platform,
       app_version,
       ip_address,
       COALESCE(last_seen_at, created_at) AS last_seen_at,
       created_at,
       expires_at
FROM user_sessions
WHERE revoked_at IS NULL
  AND expires_at > NOW();
