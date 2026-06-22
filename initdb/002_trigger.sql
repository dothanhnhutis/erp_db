--- trigger set_updated_at
CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS TRIGGER
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW IS DISTINCT FROM OLD THEN
        NEW.updated_at := NOW();
    END IF;

    RETURN NEW;
END;
$$;

--- tạo trigger tự động cập nhật updated_at cho tất cả table nào có field updated_at
DO
$$
    DECLARE
        r        RECORD;
        trg_name TEXT;
    BEGIN
        FOR r IN
            SELECT table_schema, table_name
            FROM information_schema.columns
            WHERE column_name = 'updated_at'
              AND table_schema = 'public'
            LOOP
                trg_name := format('trg_updated_at_%s', r.table_name);

                EXECUTE format(
                        'DROP TRIGGER IF EXISTS %I ON %I.%I;',
                        trg_name,
                        r.table_schema,
                        r.table_name
                        );

                EXECUTE format(
                        'CREATE TRIGGER %I
                         BEFORE UPDATE ON %I.%I
                         FOR EACH ROW
                         EXECUTE FUNCTION set_updated_at();',
                        trg_name,
                        r.table_schema,
                        r.table_name
                        );
            END LOOP;
    END;
$$;


--- trigger fn_generic_audit_log
CREATE OR REPLACE FUNCTION fn_generic_audit_log()
    RETURNS TRIGGER AS
$$
DECLARE
    v_tx_id     TEXT;
    v_user_id   TEXT;
    v_record_id TEXT;

    -- Biến lưu dữ liệu Diff
    v_old_data  JSONB := NULL;
    v_new_data  JSONB := NULL;

    v_pk_values TEXT[] := '{}';
    v_row_data  JSONB;

    -- cột nhạy cảm cần che trong audit (mask theo TÊN cột, áp dụng cho mọi bảng)
    v_sensitive TEXT[] := ARRAY['password_hash', 'token_hash', 'password', 'secret', 'refresh_token'];
    v_key       TEXT;
BEGIN

    -- 1. Transaction ID (batch id)
    v_tx_id := current_setting('ich_app.current_transaction_id', true);
    IF v_tx_id = '' OR v_tx_id IS NULL THEN
        v_tx_id := uuidv7()::TEXT;
        PERFORM set_config('ich_app.current_transaction_id', v_tx_id, true);
    END IF;

    -- 2. User ID (từ app context)
    v_user_id := current_setting('ich_app.current_user_id', true);
    IF v_user_id = '' OR v_user_id IS NULL THEN
        v_user_id := 'SYSTEM';
        PERFORM set_config('ich_app.current_user_id', v_user_id, true);
    END IF;

    -- 2. XỬ LÝ DIFF JSONB THEO HÀNH ĐỘNG
    IF TG_OP = 'UPDATE' THEN
        -- Thực hiện phép so sánh (Diff)
        SELECT
            jsonb_object_agg(key, o.value),
            jsonb_object_agg(key, n.value)
        INTO v_old_data, v_new_data
        FROM jsonb_each(to_jsonb(OLD)) o
        JOIN jsonb_each(to_jsonb(NEW)) n USING (key)
        WHERE o.value IS DISTINCT FROM n.value;

        -- Nếu UPDATE nhưng dữ liệu thực tế không thay đổi (bỏ qua để không lưu rác)
        IF v_new_data IS NULL THEN
            RETURN NULL;
        END IF;

    ELSIF TG_OP = 'INSERT' THEN
        v_new_data := to_jsonb(NEW);
    ELSIF TG_OP = 'DELETE' THEN
        v_old_data := to_jsonb(OLD);
    END IF;

    -- 2b. CHE dữ liệu nhạy cảm (mask value nhưng GIỮ key để vẫn biết trường đó có thay đổi)
    FOREACH v_key IN ARRAY v_sensitive LOOP
        IF v_old_data ? v_key THEN
            v_old_data := jsonb_set(v_old_data, ARRAY[v_key], '"***REDACTED***"');
        END IF;
        IF v_new_data ? v_key THEN
            v_new_data := jsonb_set(v_new_data, ARRAY[v_key], '"***REDACTED***"');
        END IF;
    END LOOP;

    -- 3. XÁC ĐỊNH KHÓA CHÍNH (Từ NEW hoặc OLD)
    -- Dùng NEW cho INSERT/UPDATE, dùng OLD cho DELETE
    v_row_data := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;

    IF TG_NARGS > 0 THEN
        FOR i IN 0 .. (TG_NARGS - 1) LOOP
            v_pk_values := array_append(v_pk_values, (v_row_data ->> TG_ARGV[i]));
        END LOOP;
        v_record_id := array_to_string(v_pk_values, ':');
    ELSE
        -- Fallback an toàn nếu lúc cài trigger quên truyền tham số
        v_record_id := COALESCE(v_row_data ->> 'id', 'UNKNOWN');
    END IF;

    -- 4. GHI LOG
    INSERT INTO audit_logs (transaction_id, table_name, record_id, action, old_data, new_data, changed_by)
    VALUES (
        v_tx_id,
        TG_TABLE_NAME,
        v_record_id,
        TG_OP,
        v_old_data,
        v_new_data,
        v_user_id
    );

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- thêm trigger fn_generic_audit_log cho tất cả bảng trừ bảng audit_logs
DO $$
DECLARE
    rec RECORD;
    v_pk_cols TEXT;
BEGIN
    FOR rec IN
        -- Query này sinh ra danh sách bảng kèm theo các cột PK định dạng thành chuỗi cách nhau bằng dấu phẩy
        SELECT t.table_name,
               COALESCE((
                   SELECT string_agg('''' || a.attname || '''', ', ')
                   FROM pg_index i
                   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                   WHERE i.indrelid = t.table_name::regclass AND i.indisprimary
               ), '''id''') as pk_args
        FROM information_schema.tables t
        WHERE t.table_schema = 'public'
          AND t.table_type = 'BASE TABLE'
          AND t.table_name NOT LIKE 'audit_logs%'
          AND t.table_name <> 'user_sessions'   -- loại trừ: tránh audit phình + lọt token_hash do last_seen_at cập nhật mỗi request
    LOOP
        -- Khai báo Trigger Insert/Delete
        EXECUTE format('
            DROP TRIGGER IF EXISTS trg_audit_ins_del_%I ON %I;
            CREATE TRIGGER trg_audit_ins_del_%I
            AFTER INSERT OR DELETE ON %I
            FOR EACH ROW EXECUTE FUNCTION fn_generic_audit_log(%s);',
            rec.table_name, rec.table_name, rec.table_name, rec.table_name, rec.pk_args);

        -- Khai báo Trigger Update (Có thêm mệnh đề IS DISTINCT FROM)
        EXECUTE format('
            DROP TRIGGER IF EXISTS trg_audit_upd_%I ON %I;
            CREATE TRIGGER trg_audit_upd_%I
            AFTER UPDATE ON %I
            FOR EACH ROW
            WHEN (OLD.* IS DISTINCT FROM NEW.*) -- Bỏ qua nếu data không đổi
            EXECUTE FUNCTION fn_generic_audit_log(%s);',
            rec.table_name, rec.table_name, rec.table_name, rec.table_name, rec.pk_args);
    END LOOP;
END $$;
