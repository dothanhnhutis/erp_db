-- =============================================================================
-- ERP NHÀ MÁY MỸ PHẨM — Mua hàng, Nhập kho, WMS, QC, Tồn kho  (ĐỢT 1)
-- Chuỗi chứng từ: PR (Yêu cầu mua) -> PO (Đơn đặt hàng) -> Phiếu nhập (GR)
--   -> QC (cách ly chờ kiểm) -> nhập kho theo bin/lô.
-- PostgreSQL 18 — chạy CHUNG DB với core 001/002: DÙNG LẠI trigger updated_at + audit của 002.
--
-- Nguyên tắc thiết kế:
--   * Tiền & khối lượng: NUMERIC (KHÔNG float).
--   * PK ERP = bigint identity; "ai làm" (requested/approved/received/inspected_by) = FK uuid -> users(id).
--   * Catch weight: tách declared_qty (theo phiếu) và received_qty (cân thực, đi vào tồn).
--   * 1 PO : nhiều phiếu nhập (giao nhiều đợt). Truy nguồn: PR line -> PO line -> GR line -> lô.
--   * GMP/ISO 22716: bắt buộc theo lô; NVL nhập vào bin "Tạm trữ" cách ly, QC đạt mới chuyển "Bảo quản".
--   * Kho 3 cấp: location -> warehouse_zone -> storage_bin. Tồn ghi theo (bin, item, lô) qua inventory_movement.
--
-- ĐỢT 2 (XONG): bom/bom_line (công thức đa cấp) + production_plan/production_order + MRP -> sinh PR.
-- ĐỢT 3 (XONG): xuất NVL theo lô (material_issue) + nhập thành phẩm (production_receipt) + QC TP
--   + genealogy (truy xuất xuôi) + fn_run_mrp() level-by-level (net tồn bán-thành-phẩm).
-- ĐỢT 4 (XONG): fn_generate_production_orders() auto tạo MO từ MRP + v_lot_genealogy_alloc (định lượng)
--   + fn_roll_lot_cost() giá vốn thực theo lô (NVL->SF->FG) + v_inventory_valuation/v_mo_cost.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. KIỂU TRẠNG THÁI / PHÂN LOẠI (ENUM)
-- -----------------------------------------------------------------------------
CREATE TYPE pr_status      AS ENUM ('draft','submitted','approved','rejected','converted','cancelled');
CREATE TYPE po_status      AS ENUM ('draft','sent','confirmed','partially_received','received','closed','cancelled');
CREATE TYPE receipt_status AS ENUM ('draft','posted','cancelled');
CREATE TYPE qc_status      AS ENUM ('quarantine','approved','rejected','on_hold'); -- cách ly / đạt / loại / tạm giữ
CREATE TYPE weight_source  AS ENUM ('weighed_full','weighed_sample','declared');  -- cân toàn bộ / cân mẫu / theo phiếu

CREATE TYPE item_type      AS ENUM ('RAW_MATERIAL','PACKAGING','FINISHED_GOOD','SEMI_FINISHED','SOLVENT');
CREATE TYPE zone_type      AS ENUM ('RAW_MATERIAL','PACKAGING','FINISHED_GOODS','SOLVENT');
CREATE TYPE bin_type       AS ENUM ('TEMPORARY','PRESERVATION','DISPOSAL','RETURNS'); -- Tạm trữ/Bảo quản/Loại bỏ/Hàng trả về
CREATE TYPE movement_type  AS ENUM ('receipt','transfer','qc_release','issue','adjustment','return',
                                   'production_issue','production_receipt'); -- đợt 3: xuất NVL cho SX / nhập thành phẩm

-- =============================================================================
-- 1. DANH MỤC (MASTER DATA)
-- =============================================================================

-- Đơn vị tính: kg, g, thung, phuy, can, bao...
CREATE TABLE uom (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            varchar(20)  NOT NULL UNIQUE,
    name            varchar(100) NOT NULL,
    is_base_weight  boolean      NOT NULL DEFAULT false,   -- true cho 'kg' (đơn vị gốc tính tồn & định mức)
    created_at      timestamptz  NOT NULL DEFAULT now()
);

-- Nhà cung cấp
CREATE TABLE supplier (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            varchar(30)  NOT NULL UNIQUE,
    name            varchar(255) NOT NULL,
    tax_code        varchar(20),
    payment_terms   varchar(150),                          -- mô tả điều khoản (vd: "Trả trước 100%")
    prepay_required boolean      NOT NULL DEFAULT false,    -- NCC yêu cầu thanh toán trước
    address         text,
    phone           varchar(30),
    is_active       boolean      NOT NULL DEFAULT true,
    created_at      timestamptz  NOT NULL DEFAULT now()
);

-- Item master (NVL / bao bì / dung môi / bán thành phẩm / thành phẩm)
CREATE TABLE item (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            varchar(40)  NOT NULL UNIQUE,           -- mã item
    name            varchar(255) NOT NULL,
    item_type       item_type    NOT NULL,                  -- quyết định zone lưu & yêu cầu QC
    base_uom_id     bigint       NOT NULL REFERENCES uom(id), -- ĐƠN VỊ CHÍNH để lưu kho (thường là kg)
    is_lot_managed  boolean      NOT NULL DEFAULT true,     -- mỹ phẩm: bắt buộc theo lô
    requires_qc     boolean      NOT NULL DEFAULT true,     -- bắt buộc kiểm nhập (IQC) trước khi nhập kho
    shelf_life_days integer,                                -- hạn dùng mặc định (ngày)
    created_at      timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX idx_item_type ON item(item_type);

-- Quy đổi đơn vị danh nghĩa cho từng item: 1 thùng = 20 kg, 1 phuy = 200 kg...
-- (mỗi item có UOM riêng; khi nhập thực tế vẫn lưu cân thực ở phiếu nhập)
CREATE TABLE item_uom_conversion (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id     bigint NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    from_uom_id bigint NOT NULL REFERENCES uom(id),        -- vd: thung
    to_uom_id   bigint NOT NULL REFERENCES uom(id),        -- vd: kg (base)
    factor      numeric(18,6) NOT NULL CHECK (factor > 0), -- 1 from_uom = factor * to_uom
    UNIQUE (item_id, from_uom_id, to_uom_id)
);

-- -----------------------------------------------------------------------------
-- 1b. KHO 3 CẤP: location -> warehouse_zone -> storage_bin
-- -----------------------------------------------------------------------------
CREATE TABLE location (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code      varchar(20)  NOT NULL UNIQUE,
    name      varchar(150) NOT NULL,
    address   text,
    is_active boolean      NOT NULL DEFAULT true
);

CREATE TABLE warehouse_zone (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_id bigint       NOT NULL REFERENCES location(id),
    code        varchar(20)  NOT NULL,
    name        varchar(150) NOT NULL,
    zone_type   zone_type    NOT NULL,                      -- RAW_MATERIAL/PACKAGING/FINISHED_GOODS/SOLVENT
    is_active   boolean      NOT NULL DEFAULT true,
    UNIQUE (location_id, code)
);
CREATE INDEX idx_zone_location ON warehouse_zone(location_id);

CREATE TABLE storage_bin (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone_id   bigint       NOT NULL REFERENCES warehouse_zone(id),
    code      varchar(20)  NOT NULL,
    name      varchar(150) NOT NULL,
    bin_type  bin_type     NOT NULL,                        -- TEMPORARY/PRESERVATION/DISPOSAL/RETURNS
    is_active boolean      NOT NULL DEFAULT true,
    UNIQUE (zone_id, code)
);
CREATE INDEX idx_bin_zone ON storage_bin(zone_id);

-- =============================================================================
-- 2. PR — YÊU CẦU MUA HÀNG (do KH/SX/MRP tạo, trả lời "vì sao mua")
-- =============================================================================
CREATE TABLE purchase_requisition (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pr_no          varchar(30) NOT NULL UNIQUE,            -- PR-2026-0001
    request_date   date        NOT NULL DEFAULT current_date,
    department     varchar(100),                           -- phòng kế hoạch / sản xuất
    requested_by   uuid        REFERENCES users(id),       -- người yêu cầu (RBAC)
    approved_by    uuid        REFERENCES users(id),       -- người duyệt
    needed_by_date date,                                   -- cần hàng trước ngày (đặt sớm theo lead time)
    status         pr_status   NOT NULL DEFAULT 'draft',
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE purchase_requisition_line (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pr_id   bigint        NOT NULL REFERENCES purchase_requisition(id) ON DELETE CASCADE,
    item_id bigint        NOT NULL REFERENCES item(id),
    qty     numeric(18,4) NOT NULL CHECK (qty > 0),        -- theo base uom (kg)
    uom_id  bigint        NOT NULL REFERENCES uom(id),
    note    text
);
CREATE INDEX idx_prl_pr   ON purchase_requisition_line(pr_id);
CREATE INDEX idx_prl_item ON purchase_requisition_line(item_id);

-- =============================================================================
-- 3. PO — ĐƠN ĐẶT HÀNG (giá thoả thuận; KHÔNG phải giá vốn cuối cùng)
-- =============================================================================
CREATE TABLE purchase_order (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_no         varchar(30)  NOT NULL UNIQUE,            -- PO-2026-0001
    supplier_id   bigint       NOT NULL REFERENCES supplier(id),
    order_date    date         NOT NULL DEFAULT current_date,
    currency      varchar(3)   NOT NULL DEFAULT 'VND',
    status        po_status    NOT NULL DEFAULT 'draft',
    created_by    uuid         REFERENCES users(id),       -- người lập PO (phòng thu mua)
    approved_by   uuid         REFERENCES users(id),
    prepay_amount numeric(18,2) NOT NULL DEFAULT 0,        -- số tiền cần trả trước cho PO này
    tolerance_pct numeric(5,2) NOT NULL DEFAULT 1.0,       -- dung sai nhận hàng (%) so với phiếu
    note          text,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX idx_po_supplier ON purchase_order(supplier_id);

CREATE TABLE purchase_order_line (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_id         bigint        NOT NULL REFERENCES purchase_order(id) ON DELETE CASCADE,
    pr_line_id    bigint        REFERENCES purchase_requisition_line(id), -- truy nguồn về PR
    item_id       bigint        NOT NULL REFERENCES item(id),
    ordered_qty   numeric(18,4) NOT NULL CHECK (ordered_qty > 0),         -- base uom (kg)
    uom_id        bigint        NOT NULL REFERENCES uom(id),
    unit_price    numeric(18,4) NOT NULL CHECK (unit_price >= 0),         -- giá thoả thuận
    expected_date date,                                                   -- ngày giao (đợt) dự kiến
    line_amount   numeric(18,2) GENERATED ALWAYS AS (ordered_qty * unit_price) STORED,
    note          text
);
CREATE INDEX idx_pol_po   ON purchase_order_line(po_id);
CREATE INDEX idx_pol_item ON purchase_order_line(item_id);

-- =============================================================================
-- 4. LÔ HÀNG (BATCH/LOT) — bắt buộc cho mỹ phẩm, truy xuất & thu hồi
-- =============================================================================
CREATE TABLE lot (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_no           varchar(50) NOT NULL,                 -- số lô NỘI BỘ (mỗi lần nhập mỗi item)
    item_id          bigint      NOT NULL REFERENCES item(id),
    supplier_id      bigint      REFERENCES supplier(id),
    supplier_lot_no  varchar(50),                          -- số lô của NCC (nếu khác)
    manufacture_date date,
    expiry_date      date,                                 -- hạn dùng
    retest_date      date,                                 -- ngày tái kiểm
    qc_status        qc_status   NOT NULL DEFAULT 'quarantine', -- mặc định CÁCH LY chờ QC
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (item_id, lot_no)
);
CREATE INDEX idx_lot_item ON lot(item_id);
CREATE INDEX idx_lot_qc   ON lot(qc_status);

-- =============================================================================
-- 5. PHIẾU NHẬP KHO (GOODS RECEIPT) — 1 PO : nhiều phiếu nhập (giao nhiều đợt)
-- =============================================================================
CREATE TABLE goods_receipt (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gr_no          varchar(30)    NOT NULL UNIQUE,         -- GR-2026-0001
    po_id          bigint         NOT NULL REFERENCES purchase_order(id),
    supplier_id    bigint         NOT NULL REFERENCES supplier(id),
    location_id    bigint         NOT NULL REFERENCES location(id),   -- nhận về site nào
    received_by    uuid           REFERENCES users(id),               -- thủ kho nhận
    receipt_date   date           NOT NULL DEFAULT current_date,
    supplier_do_no varchar(50),                            -- số phiếu xuất kho/giao hàng bên bán
    status         receipt_status NOT NULL DEFAULT 'draft',
    note           text,
    created_at     timestamptz    NOT NULL DEFAULT now(),
    updated_at     timestamptz    NOT NULL DEFAULT now()
);
CREATE INDEX idx_gr_po       ON goods_receipt(po_id);
CREATE INDEX idx_gr_supplier ON goods_receipt(supplier_id);

CREATE TABLE goods_receipt_line (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gr_id         bigint        NOT NULL REFERENCES goods_receipt(id) ON DELETE CASCADE,
    po_line_id    bigint        NOT NULL REFERENCES purchase_order_line(id), -- nhận cho dòng PO nào
    item_id       bigint        NOT NULL REFERENCES item(id),
    lot_id        bigint        REFERENCES lot(id),        -- lô được tạo/gán khi nhập
    to_bin_id     bigint        REFERENCES storage_bin(id),-- bin nhận ban đầu (NVL: bin Tạm trữ/cách ly)

    -- (a) Đếm kiện — phục vụ logistics (đếm 100% số kiện)
    package_qty    numeric(18,3),                          -- 100 thùng / 10 phuy
    package_uom_id bigint REFERENCES uom(id),              -- thùng / phuy

    -- (b) CATCH WEIGHT — tách "khai báo" và "thực nhận"
    declared_qty  numeric(18,4) NOT NULL CHECK (declared_qty >= 0), -- theo phiếu bên bán (kg) -> công nợ/hoá đơn
    received_qty  numeric(18,4) NOT NULL CHECK (received_qty >= 0), -- cân thực (kg) -> ĐI VÀO TỒN KHO
    qty_uom_id    bigint        NOT NULL REFERENCES uom(id),        -- kg (base)
    weight_source weight_source NOT NULL DEFAULT 'declared',        -- cân toàn bộ / cân mẫu / theo phiếu

    -- (c) Giá & QC
    unit_price    numeric(18,4) NOT NULL DEFAULT 0,        -- lấy từ PO line (giá vốn tạm tính)
    qc_status     qc_status     NOT NULL DEFAULT 'quarantine',
    note          text
);
CREATE INDEX idx_grl_gr     ON goods_receipt_line(gr_id);
CREATE INDEX idx_grl_poline ON goods_receipt_line(po_line_id);
CREATE INDEX idx_grl_lot    ON goods_receipt_line(lot_id);
CREATE INDEX idx_grl_bin    ON goods_receipt_line(to_bin_id);

-- =============================================================================
-- 6. QC NHẬP (IQC) — NVL phải kiểm ĐẠT trước khi chuyển sang bin Bảo quản
-- =============================================================================
CREATE TABLE qc_inspection (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gr_line_id      bigint      REFERENCES goods_receipt_line(id) ON DELETE CASCADE, -- đợt 3: NULLable -> QC dùng chung NVL & thành phẩm (xem chk_qc_one_source)
    lot_id          bigint      REFERENCES lot(id),
    inspected_by    uuid        REFERENCES users(id),      -- nhân viên QC (RBAC)
    inspection_date timestamptz NOT NULL DEFAULT now(),
    result          qc_status   NOT NULL DEFAULT 'on_hold'
                    CHECK (result IN ('approved','rejected','on_hold')),
    sampling_note   text,                                  -- mô tả lấy mẫu / chỉ tiêu kiểm
    note            text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_qc_grline ON qc_inspection(gr_line_id);
CREATE INDEX idx_qc_lot    ON qc_inspection(lot_id);

-- =============================================================================
-- 7. (MỞ RỘNG) TRẢ TRƯỚC CHO NGƯỜI BÁN — tài sản, cấn trừ dần khi hàng về
-- =============================================================================
CREATE TABLE supplier_advance (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    advance_no     varchar(30)   NOT NULL UNIQUE,
    po_id          bigint        REFERENCES purchase_order(id),    -- gắn với PO
    supplier_id    bigint        NOT NULL REFERENCES supplier(id),
    paid_date      date          NOT NULL DEFAULT current_date,
    amount         numeric(18,2) NOT NULL CHECK (amount > 0),      -- số đã trả trước
    settled_amount numeric(18,2) NOT NULL DEFAULT 0,               -- đã cấn trừ theo các đợt nhận
    note           text,
    created_at     timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_adv_po       ON supplier_advance(po_id);
CREATE INDEX idx_adv_supplier ON supplier_advance(supplier_id);

-- =============================================================================
-- 8. TỒN KHO — LEDGER bất biến theo (bin, item, lô). Mỗi nghiệp vụ sinh 1+ bút toán.
--    Nhập (+) vào bin Tạm trữ; QC đạt -> transfer (- Tạm trữ, + Bảo quản); loại -> Loại bỏ/Trả về.
--    (Bảng này KHÔNG gắn audit trigger — bản thân nó đã là sổ cái bất biến; xem mục 10.)
-- =============================================================================
CREATE TABLE inventory_movement (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    movement_date timestamptz   NOT NULL DEFAULT now(),
    movement_type movement_type NOT NULL,                  -- receipt/transfer/qc_release/issue/adjustment/return
    item_id       bigint        NOT NULL REFERENCES item(id),
    bin_id        bigint        NOT NULL REFERENCES storage_bin(id),
    lot_id        bigint        REFERENCES lot(id),
    qty           numeric(18,4) NOT NULL,                  -- + nhập / - xuất (base uom kg)
    unit_cost     numeric(18,4) NOT NULL DEFAULT 0,
    source_type   varchar(30)   NOT NULL,                  -- 'goods_receipt' | 'qc_release' | 'transfer' ...
    source_id     bigint,                                  -- id chứng từ nguồn (vd goods_receipt_line.id)
    created_at    timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_invmov_item_bin ON inventory_movement(item_id, bin_id);
CREATE INDEX idx_invmov_lot      ON inventory_movement(lot_id);
CREATE INDEX idx_invmov_bin      ON inventory_movement(bin_id);

-- =============================================================================
-- 9. VIEW HỖ TRỢ
-- =============================================================================

-- 9.1 Tiến độ nhận theo từng dòng PO (tính động) -> biết đã nhận luỹ kế & còn lại.
CREATE VIEW v_po_line_progress AS
SELECT
    pol.id                                                    AS po_line_id,
    pol.po_id,
    pol.item_id,
    pol.ordered_qty,
    COALESCE(SUM(grl.received_qty), 0)                        AS received_qty,
    pol.ordered_qty - COALESCE(SUM(grl.received_qty), 0)      AS open_qty
FROM purchase_order_line pol
LEFT JOIN goods_receipt_line grl ON grl.po_line_id = pol.id
LEFT JOIN goods_receipt      gr  ON gr.id = grl.gr_id AND gr.status = 'posted'
GROUP BY pol.id;

-- 9.2 Chênh lệch nhận vs phiếu & cờ vượt dung sai (cảnh báo để lập biên bản).
CREATE VIEW v_receipt_variance AS
SELECT
    grl.id                                                    AS gr_line_id,
    gr.gr_no,
    grl.declared_qty,
    grl.received_qty,
    grl.received_qty - grl.declared_qty                       AS qty_diff,
    CASE WHEN grl.declared_qty > 0
         THEN round((grl.received_qty - grl.declared_qty) / grl.declared_qty * 100, 2)
         ELSE 0 END                                           AS diff_pct,
    po.tolerance_pct,
    CASE WHEN grl.declared_qty > 0
              AND abs((grl.received_qty - grl.declared_qty) / grl.declared_qty * 100) > po.tolerance_pct
         THEN true ELSE false END                             AS out_of_tolerance
FROM goods_receipt_line grl
JOIN goods_receipt   gr ON gr.id = grl.gr_id
JOIN purchase_order  po ON po.id = gr.po_id;

-- 9.3 Tồn hiện có theo (bin, item, lô) — cộng dồn ledger.
CREATE VIEW v_stock_on_hand AS
SELECT im.bin_id, im.item_id, im.lot_id, SUM(im.qty) AS qty_on_hand
FROM inventory_movement im
GROUP BY im.bin_id, im.item_id, im.lot_id
HAVING SUM(im.qty) <> 0;

-- 9.4 Tồn KHẢ DỤNG — ở bin Bảo quản (PRESERVATION) và lô đã QC đạt (hoặc item không theo lô).
CREATE VIEW v_available_stock AS
SELECT
    soh.item_id,
    soh.lot_id,
    wz.location_id,
    SUM(soh.qty_on_hand) AS qty_available
FROM v_stock_on_hand soh
JOIN storage_bin    sb ON sb.id = soh.bin_id
JOIN warehouse_zone wz ON wz.id = sb.zone_id
LEFT JOIN lot       l  ON l.id  = soh.lot_id
WHERE sb.bin_type = 'PRESERVATION'
  AND (l.id IS NULL OR l.qc_status = 'approved')
GROUP BY soh.item_id, soh.lot_id, wz.location_id
HAVING SUM(soh.qty_on_hand) <> 0;

-- 9.5 Truy xuất NGƯỢC 1 lô về tận PO/PR/NCC.
CREATE VIEW v_lot_traceability AS
SELECT
    l.id          AS lot_id,
    l.lot_no,
    l.item_id,
    l.qc_status,
    l.expiry_date,
    grl.id        AS gr_line_id,
    gr.gr_no,
    gr.receipt_date,
    po.po_no,
    pol.id        AS po_line_id,
    pr.pr_no,
    prl.id        AS pr_line_id,
    sup.code      AS supplier_code,
    sup.name      AS supplier_name
FROM lot l
LEFT JOIN goods_receipt_line        grl ON grl.lot_id = l.id
LEFT JOIN goods_receipt             gr  ON gr.id  = grl.gr_id
LEFT JOIN purchase_order_line       pol ON pol.id = grl.po_line_id
LEFT JOIN purchase_order            po  ON po.id  = pol.po_id
LEFT JOIN purchase_requisition_line prl ON prl.id = pol.pr_line_id
LEFT JOIN purchase_requisition      pr  ON pr.id  = prl.pr_id
LEFT JOIN supplier                  sup ON sup.id = l.supplier_id;

-- #############################################################################
-- ##########################  PHẦN ĐỢT 2  #####################################
-- BOM (công thức) đa cấp + Kế hoạch SX + Lệnh SX + MRP net -> sinh PR.
-- Đặt TRƯỚC mục 10 để vòng lặp trigger tự gắn audit + updated_at cho bảng mới.
-- #############################################################################

-- 0b. ENUM đợt 2
CREATE TYPE bom_status              AS ENUM ('draft','active','obsolete');
CREATE TYPE production_plan_status  AS ENUM ('draft','confirmed','closed','cancelled');
CREATE TYPE production_order_status AS ENUM ('draft','planned','released','in_progress','done','cancelled');
CREATE TYPE mrp_status              AS ENUM ('draft','confirmed');

-- =============================================================================
-- P2.B  BOM / CÔNG THỨC (đa cấp: component có thể là bán thành phẩm có BOM riêng)
-- =============================================================================
CREATE TABLE bom (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id        bigint        NOT NULL REFERENCES item(id),   -- thành phẩm / bán thành phẩm công thức này tạo ra
    version        varchar(20)   NOT NULL DEFAULT 'v1',
    output_qty     numeric(18,4) NOT NULL DEFAULT 1 CHECK (output_qty > 0), -- 1 mẻ công thức cho ra (base uom item)
    output_uom_id  bigint        NOT NULL REFERENCES uom(id),
    status         bom_status    NOT NULL DEFAULT 'draft',
    effective_from date,
    effective_to   date,
    note           text,
    created_by     uuid          REFERENCES users(id),
    created_at     timestamptz   NOT NULL DEFAULT now(),
    updated_at     timestamptz   NOT NULL DEFAULT now()
);
-- mỗi item tối đa 1 công thức ĐANG ÁP DỤNG
CREATE UNIQUE INDEX uq_bom_active ON bom(item_id) WHERE status = 'active';
CREATE INDEX idx_bom_item ON bom(item_id);

CREATE TABLE bom_line (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bom_id            bigint        NOT NULL REFERENCES bom(id) ON DELETE CASCADE,
    component_item_id bigint        NOT NULL REFERENCES item(id),  -- NVL hoặc bán thành phẩm
    qty               numeric(18,6) NOT NULL CHECK (qty > 0),      -- định mức cho output_qty của BOM (base uom component)
    uom_id            bigint        NOT NULL REFERENCES uom(id),
    scrap_pct         numeric(7,4)  NOT NULL DEFAULT 0 CHECK (scrap_pct >= 0), -- % hao hụt
    note              text,
    UNIQUE (bom_id, component_item_id)
);
CREATE INDEX idx_bomline_bom       ON bom_line(bom_id);
CREATE INDEX idx_bomline_component ON bom_line(component_item_id);

-- =============================================================================
-- P2.C  KẾ HOẠCH SẢN XUẤT (phòng kế hoạch)
-- =============================================================================
CREATE TABLE production_plan (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_no     varchar(30)            NOT NULL UNIQUE,    -- MP-2026-0001
    plan_date   date                   NOT NULL DEFAULT current_date,
    period_from date,
    period_to   date,
    status      production_plan_status NOT NULL DEFAULT 'draft',
    planned_by  uuid                   REFERENCES users(id),
    note        text,
    created_at  timestamptz            NOT NULL DEFAULT now(),
    updated_at  timestamptz            NOT NULL DEFAULT now()
);

CREATE TABLE production_plan_line (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_id        bigint        NOT NULL REFERENCES production_plan(id) ON DELETE CASCADE,
    item_id        bigint        NOT NULL REFERENCES item(id),  -- thành phẩm cần SX
    planned_qty    numeric(18,4) NOT NULL CHECK (planned_qty > 0),
    uom_id         bigint        NOT NULL REFERENCES uom(id),
    needed_by_date date,
    note           text
);
CREATE INDEX idx_ppl_plan ON production_plan_line(plan_id);
CREATE INDEX idx_ppl_item ON production_plan_line(item_id);

-- =============================================================================
-- P2.D  LỆNH SẢN XUẤT (phòng sản xuất)
-- =============================================================================
CREATE TABLE production_order (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mo_no           varchar(30)             NOT NULL UNIQUE,   -- MO-2026-0001
    item_id         bigint                  NOT NULL REFERENCES item(id),  -- thành phẩm/bán thành phẩm SX
    bom_id          bigint                  REFERENCES bom(id),            -- công thức áp dụng
    plan_line_id    bigint                  REFERENCES production_plan_line(id), -- truy nguồn về kế hoạch
    planned_qty     numeric(18,4)           NOT NULL CHECK (planned_qty > 0),
    uom_id          bigint                  NOT NULL REFERENCES uom(id),
    location_id     bigint                  REFERENCES location(id),       -- nơi SX / nhập thành phẩm
    scheduled_start date,
    scheduled_end   date,
    status          production_order_status NOT NULL DEFAULT 'draft',
    created_by      uuid                    REFERENCES users(id),
    approved_by     uuid                    REFERENCES users(id),
    note            text,
    created_at      timestamptz             NOT NULL DEFAULT now(),
    updated_at      timestamptz             NOT NULL DEFAULT now()
);
CREATE INDEX idx_mo_item ON production_order(item_id);
CREATE INDEX idx_mo_plan ON production_order(plan_line_id);

-- Định mức NVL TRỰC TIẾP (1 cấp) của lệnh — để đợt-3 xuất kho theo lệnh.
CREATE TABLE production_order_material (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mo_id             bigint        NOT NULL REFERENCES production_order(id) ON DELETE CASCADE,
    component_item_id bigint        NOT NULL REFERENCES item(id),
    required_qty      numeric(18,6) NOT NULL CHECK (required_qty >= 0),   -- gồm scrap
    uom_id            bigint        NOT NULL REFERENCES uom(id),
    note              text,
    UNIQUE (mo_id, component_item_id)
);
CREATE INDEX idx_mom_mo   ON production_order_material(mo_id);
CREATE INDEX idx_mom_item ON production_order_material(component_item_id);

-- =============================================================================
-- P2.E  MRP — tính NVL CẦN MUA (nổ BOM đệ quy, net theo tồn + đang về) -> sinh PR
--   Giới hạn đã biết: netting ở mức NVL đi mua; CHƯA trừ tồn bán-thành-phẩm trung gian
--   (giả định pha mới toàn bộ bulk). Level-by-level netting để refine đợt sau.
--   MRP chạy theo production_plan status = 'confirmed'.
-- =============================================================================

-- E1. Nổ BOM ĐỆ QUY từ kế hoạch -> nhu cầu GỘP các item LEAF (đi mua = không có active BOM).
CREATE VIEW v_mrp_gross_requirement AS
WITH RECURSIVE explosion AS (
    SELECT ppl.plan_id,
           ppl.item_id           AS component_item_id,
           ppl.planned_qty::numeric AS req_qty,   -- ép numeric không ràng buộc để khớp kiểu nhánh đệ quy
           ARRAY[ppl.item_id]    AS path,
           1                     AS lvl
    FROM production_plan_line ppl
    JOIN production_plan pp ON pp.id = ppl.plan_id AND pp.status = 'confirmed'

    UNION ALL

    SELECT e.plan_id,
           bl.component_item_id,
           e.req_qty * bl.qty / b.output_qty * (1 + bl.scrap_pct / 100.0),
           e.path || bl.component_item_id,
           e.lvl + 1
    FROM explosion e
    JOIN bom      b  ON b.item_id = e.component_item_id AND b.status = 'active'
    JOIN bom_line bl ON bl.bom_id = b.id
    WHERE NOT bl.component_item_id = ANY (e.path)   -- chống vòng lặp công thức
      AND e.lvl < 20
)
SELECT plan_id,
       component_item_id AS item_id,
       SUM(req_qty)      AS gross_qty
FROM explosion e
WHERE NOT EXISTS (SELECT 1 FROM bom b WHERE b.item_id = e.component_item_id AND b.status = 'active')
GROUP BY plan_id, component_item_id;

-- E2. Netting: net = gross - tồn khả dụng - PO đang về (kẹp >= 0).
CREATE VIEW v_mrp_netting AS
SELECT
    g.plan_id,
    g.item_id,
    g.gross_qty,
    COALESCE(av.available_qty, 0) AS available_qty,
    COALESCE(oo.on_order_qty, 0)  AS on_order_qty,
    GREATEST(g.gross_qty - COALESCE(av.available_qty, 0) - COALESCE(oo.on_order_qty, 0), 0) AS net_qty
FROM v_mrp_gross_requirement g
LEFT JOIN (
    SELECT item_id, SUM(qty_available) AS available_qty
    FROM v_available_stock
    GROUP BY item_id
) av ON av.item_id = g.item_id
LEFT JOIN (
    SELECT pol.item_id, SUM(prog.open_qty) AS on_order_qty
    FROM v_po_line_progress prog
    JOIN purchase_order_line pol ON pol.id = prog.po_line_id
    JOIN purchase_order      po  ON po.id  = pol.po_id AND po.status NOT IN ('closed','cancelled')
    GROUP BY pol.item_id
) oo ON oo.item_id = g.item_id;

-- E3. Snapshot 1 lần chạy MRP + dòng nhu cầu (truy nguồn ra PR).
CREATE TABLE mrp_run (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_no     varchar(30) NOT NULL UNIQUE,
    plan_id    bigint      NOT NULL REFERENCES production_plan(id),
    run_date   timestamptz NOT NULL DEFAULT now(),
    run_by     uuid        REFERENCES users(id),
    status     mrp_status  NOT NULL DEFAULT 'draft',
    note       text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE mrp_requirement (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mrp_run_id    bigint        NOT NULL REFERENCES mrp_run(id) ON DELETE CASCADE,
    item_id       bigint        NOT NULL REFERENCES item(id),
    gross_qty     numeric(18,6) NOT NULL,
    available_qty numeric(18,6) NOT NULL DEFAULT 0,
    on_order_qty  numeric(18,6) NOT NULL DEFAULT 0,
    net_qty       numeric(18,6) NOT NULL,
    uom_id        bigint        REFERENCES uom(id),
    pr_line_id    bigint        REFERENCES purchase_requisition_line(id), -- PR sinh ra từ dòng này
    UNIQUE (mrp_run_id, item_id)
);
CREATE INDEX idx_mrpreq_run  ON mrp_requirement(mrp_run_id);
CREATE INDEX idx_mrpreq_item ON mrp_requirement(item_id);

-- PR có thể sinh từ MRP (truy nguồn) hoặc lập tay -> thêm liên kết, không bắt buộc.
ALTER TABLE purchase_requisition ADD COLUMN mrp_run_id bigint REFERENCES mrp_run(id);

-- #############################################################################
-- ##########################  PHẦN ĐỢT 3  #####################################
-- THỰC THI SẢN XUẤT: xuất NVL theo lô (issue) + nhập thành phẩm (lô FG) + QC TP
--   + truy xuất XUÔI (genealogy) + MRP level-by-level (trừ tồn bán-thành-phẩm).
-- Đặt TRƯỚC mục 10 để vòng lặp trigger tự gắn audit + updated_at cho bảng mới.
-- Quy ước giữ như đợt 1/2: bigint PK, who-fields uuid FK->users, NUMERIC,
--   ledger inventory_movement ghi bằng APP (không auto-post trigger).
-- #############################################################################

-- =============================================================================
-- P3.F  XUẤT NVL THEO LÔ (MATERIAL ISSUE) — tiêu hao tồn khả dụng cho lệnh SX
--   Post (app): mỗi line -> inventory_movement(production_issue, qty ÂM, from_bin, lô).
-- =============================================================================
CREATE TABLE material_issue (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_no    varchar(30)    NOT NULL UNIQUE,             -- MI-2026-0001
    mo_id       bigint         NOT NULL REFERENCES production_order(id), -- xuất cho lệnh SX nào
    location_id bigint         REFERENCES location(id),
    issued_by   uuid           REFERENCES users(id),        -- thủ kho xuất (RBAC)
    issue_date  date           NOT NULL DEFAULT current_date,
    status      receipt_status NOT NULL DEFAULT 'draft',    -- tái dùng: draft/posted/cancelled
    note        text,
    created_at  timestamptz    NOT NULL DEFAULT now(),
    updated_at  timestamptz    NOT NULL DEFAULT now()
);
CREATE INDEX idx_mi_mo ON material_issue(mo_id);

CREATE TABLE material_issue_line (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_id          bigint        NOT NULL REFERENCES material_issue(id) ON DELETE CASCADE,
    component_item_id bigint        NOT NULL REFERENCES item(id),
    lot_id            bigint        REFERENCES lot(id),          -- lô NVL/SF bị tiêu hao (chọn FEFO)
    from_bin_id       bigint        NOT NULL REFERENCES storage_bin(id), -- bin Bảo quản xuất ra
    qty               numeric(18,4) NOT NULL CHECK (qty > 0),   -- base uom (kg) -> ledger ghi ÂM
    uom_id            bigint        NOT NULL REFERENCES uom(id),
    note              text
);
CREATE INDEX idx_mil_issue ON material_issue_line(issue_id);
CREATE INDEX idx_mil_item  ON material_issue_line(component_item_id);
CREATE INDEX idx_mil_lot   ON material_issue_line(lot_id);

-- F-view: trạng thái cấp phát NVL của lệnh (định mức vs đã xuất).
CREATE VIEW v_mo_material_status AS
SELECT
    mom.mo_id,
    mom.component_item_id,
    mom.required_qty,
    COALESCE(iss.issued_qty, 0)                  AS issued_qty,
    mom.required_qty - COALESCE(iss.issued_qty, 0) AS open_qty
FROM production_order_material mom
LEFT JOIN (
    SELECT mi.mo_id, mil.component_item_id, SUM(mil.qty) AS issued_qty
    FROM material_issue mi
    JOIN material_issue_line mil ON mil.issue_id = mi.id
    WHERE mi.status = 'posted'
    GROUP BY mi.mo_id, mil.component_item_id
) iss ON iss.mo_id = mom.mo_id AND iss.component_item_id = mom.component_item_id;

-- F-view: gợi ý lô để xuất theo FEFO (hết hạn trước, kèm bin Bảo quản + tồn khả dụng).
CREATE VIEW v_issue_fefo_candidate AS
SELECT
    soh.item_id,
    soh.lot_id,
    soh.bin_id,
    wz.location_id,
    l.lot_no,
    l.expiry_date,
    soh.qty_on_hand AS qty_available
FROM v_stock_on_hand soh
JOIN storage_bin    sb ON sb.id = soh.bin_id  AND sb.bin_type = 'PRESERVATION'
JOIN warehouse_zone wz ON wz.id = sb.zone_id
JOIN lot            l  ON l.id  = soh.lot_id  AND l.qc_status = 'approved'
WHERE soh.qty_on_hand > 0
ORDER BY soh.item_id, l.expiry_date NULLS LAST, soh.lot_id;

-- =============================================================================
-- P3.G  NHẬP THÀNH PHẨM (PRODUCTION RECEIPT) + QC THÀNH PHẨM
--   Mỗi receipt tạo LÔ FG MỚI (sản xuất nội bộ -> lot.supplier_id NULL).
--   Post (app): mỗi line -> inventory_movement(production_receipt, qty DƯƠNG, to_bin, lô).
--   QC theo item.requires_qc: true -> lô quarantine vào bin TEMPORARY (zone FINISHED_GOODS),
--     QC đạt -> lô approved + transfer sang PRESERVATION -> khả dụng (v_available_stock).
--     false -> lô approved nhập thẳng PRESERVATION -> khả dụng ngay.
-- =============================================================================
CREATE TABLE production_receipt (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_no   varchar(30)    NOT NULL UNIQUE,            -- FG-2026-0001
    mo_id        bigint         NOT NULL REFERENCES production_order(id),
    item_id      bigint         NOT NULL REFERENCES item(id),  -- thành phẩm/bán TP SX ra (= mo.item_id)
    location_id  bigint         REFERENCES location(id),
    received_by  uuid           REFERENCES users(id),
    receipt_date date           NOT NULL DEFAULT current_date,
    status       receipt_status NOT NULL DEFAULT 'draft',
    note         text,
    created_at   timestamptz    NOT NULL DEFAULT now(),
    updated_at   timestamptz    NOT NULL DEFAULT now()
);
CREATE INDEX idx_prcpt_mo ON production_receipt(mo_id);

CREATE TABLE production_receipt_line (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_id   bigint        NOT NULL REFERENCES production_receipt(id) ON DELETE CASCADE,
    lot_id       bigint        NOT NULL REFERENCES lot(id),  -- LÔ FG MỚI (item nội bộ)
    to_bin_id    bigint        NOT NULL REFERENCES storage_bin(id), -- requires_qc: TEMPORARY; else PRESERVATION
    produced_qty numeric(18,4) NOT NULL CHECK (produced_qty > 0),   -- base uom -> ledger ghi DƯƠNG
    uom_id       bigint        NOT NULL REFERENCES uom(id),
    note         text
);
CREATE INDEX idx_prcptl_receipt ON production_receipt_line(receipt_id);
CREATE INDEX idx_prcptl_lot     ON production_receipt_line(lot_id);

-- Tổng quát hoá qc_inspection: thêm nguồn TP; ràng buộc đúng 1 nguồn (NVL HOẶC thành phẩm).
ALTER TABLE qc_inspection
    ADD COLUMN production_receipt_line_id bigint REFERENCES production_receipt_line(id) ON DELETE CASCADE;
ALTER TABLE qc_inspection
    ADD CONSTRAINT chk_qc_one_source CHECK (num_nonnulls(gr_line_id, production_receipt_line_id) = 1);
CREATE INDEX idx_qc_prline ON qc_inspection(production_receipt_line_id);

-- G-view: tiến độ hoàn thành lệnh SX (kế hoạch vs đã nhập kho).
CREATE VIEW v_mo_completion AS
SELECT
    mo.id        AS mo_id,
    mo.mo_no,
    mo.item_id,
    mo.planned_qty,
    COALESCE(rc.produced_qty, 0)                  AS produced_qty,
    mo.planned_qty - COALESCE(rc.produced_qty, 0) AS remaining_qty
FROM production_order mo
LEFT JOIN (
    SELECT pr.mo_id, SUM(prl.produced_qty) AS produced_qty
    FROM production_receipt pr
    JOIN production_receipt_line prl ON prl.receipt_id = pr.id
    WHERE pr.status = 'posted'
    GROUP BY pr.mo_id
) rc ON rc.mo_id = mo.id;

-- =============================================================================
-- P3.H  TRUY XUẤT XUÔI — GENEALOGY (lô NVL -> ... -> lô thành phẩm)
--   Granularity = MO: mọi lô tiêu hao của 1 lệnh là CHA của mọi lô SX ra ở lệnh đó
--   (chuẩn batch genealogy; phân bổ theo tỷ lệ tiêu hao để refine ở đợt sau).
-- =============================================================================
CREATE VIEW v_lot_genealogy_edge AS
SELECT DISTINCT
    mil.lot_id AS parent_lot_id,   -- lô tiêu hao (NVL/SF)
    prl.lot_id AS child_lot_id,    -- lô sản xuất ra (SF/FG)
    mo.id      AS mo_id,
    mo.mo_no
FROM production_order mo
JOIN material_issue          mi  ON mi.mo_id      = mo.id AND mi.status = 'posted'
JOIN material_issue_line     mil ON mil.issue_id  = mi.id AND mil.lot_id IS NOT NULL
JOIN production_receipt       pr  ON pr.mo_id      = mo.id AND pr.status = 'posted'
JOIN production_receipt_line  prl ON prl.receipt_id = pr.id;

-- XUÔI: từ 1 lô gốc -> mọi lô hậu duệ qua nhiều cấp SX (use-case thu hồi/recall).
CREATE VIEW v_lot_genealogy_forward AS
WITH RECURSIVE g AS (
    SELECT parent_lot_id AS root_lot_id, parent_lot_id, child_lot_id, mo_id, mo_no,
           1 AS lvl, ARRAY[parent_lot_id, child_lot_id] AS path
    FROM v_lot_genealogy_edge
  UNION ALL
    SELECT g.root_lot_id, e.parent_lot_id, e.child_lot_id, e.mo_id, e.mo_no,
           g.lvl + 1, g.path || e.child_lot_id
    FROM g
    JOIN v_lot_genealogy_edge e ON e.parent_lot_id = g.child_lot_id
    WHERE NOT e.child_lot_id = ANY (g.path) AND g.lvl < 20
)
SELECT root_lot_id, child_lot_id AS descendant_lot_id, mo_id, mo_no, lvl FROM g;

-- NGƯỢC: từ 1 lô thành phẩm -> mọi lô NVL/SF nguồn (nối v_lot_traceability ra PO/NCC).
CREATE VIEW v_lot_genealogy_backward AS
WITH RECURSIVE g AS (
    SELECT child_lot_id AS root_lot_id, parent_lot_id, child_lot_id, mo_id, mo_no,
           1 AS lvl, ARRAY[child_lot_id, parent_lot_id] AS path
    FROM v_lot_genealogy_edge
  UNION ALL
    SELECT g.root_lot_id, e.parent_lot_id, e.child_lot_id, e.mo_id, e.mo_no,
           g.lvl + 1, g.path || e.parent_lot_id
    FROM g
    JOIN v_lot_genealogy_edge e ON e.child_lot_id = g.parent_lot_id
    WHERE NOT e.parent_lot_id = ANY (g.path) AND g.lvl < 20
)
SELECT root_lot_id, parent_lot_id AS ancestor_lot_id, mo_id, mo_no, lvl FROM g;

-- =============================================================================
-- P3.I  MRP LEVEL-BY-LEVEL — fn_run_mrp() (low-level-code, net tồn ĐÚNG mọi cấp)
--   Gỡ giới hạn đợt 2: gộp nhu cầu 1 item qua MỌI nhánh TRƯỚC khi net tồn, rồi mới
--   nổ tiếp -> 1 bán-thành-phẩm dùng nhiều nơi chỉ trừ tồn 1 lần. Ghi mrp_requirement
--   cho mọi cấp (FG/SF/RM). Leaf (không active BOM) net>0 = đi mua -> sinh PR.
--   View đợt-2 v_mrp_gross_requirement/v_mrp_netting GIỮ NGUYÊN (quick-look 1 mức);
--   fn_run_mrp là đường netting đa cấp CHUẨN.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_run_mrp(p_plan_id bigint, p_run_no varchar, p_run_by uuid DEFAULT NULL)
    RETURNS bigint   -- trả mrp_run_id
    LANGUAGE plpgsql AS
$$
DECLARE
    v_run_id  bigint;
    v_max_llc int;
    v_llc     int;
BEGIN
    PERFORM 1 FROM production_plan WHERE id = p_plan_id AND status = 'confirmed';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Plan % chưa confirmed, không chạy MRP', p_plan_id;
    END IF;

    INSERT INTO mrp_run(run_no, plan_id, run_by, status)
    VALUES (p_run_no, p_plan_id, p_run_by, 'confirmed')
    RETURNING id INTO v_run_id;

    DROP TABLE IF EXISTS _llc;   -- an toàn nếu gọi lại trong cùng transaction
    DROP TABLE IF EXISTS _req;

    -- low-level-code: độ sâu LỚN NHẤT của item trong cây BOM của kế hoạch.
    CREATE TEMP TABLE _llc ON COMMIT DROP AS
    WITH RECURSIVE expl AS (
        SELECT ppl.item_id, 0 AS lvl, ARRAY[ppl.item_id] AS path
        FROM production_plan_line ppl
        WHERE ppl.plan_id = p_plan_id
      UNION ALL
        SELECT bl.component_item_id, e.lvl + 1, e.path || bl.component_item_id
        FROM expl e
        JOIN bom      b  ON b.item_id = e.item_id AND b.status = 'active'
        JOIN bom_line bl ON bl.bom_id = b.id
        WHERE NOT bl.component_item_id = ANY (e.path) AND e.lvl < 20
    )
    SELECT item_id, MAX(lvl) AS llc FROM expl GROUP BY item_id;

    -- nhu cầu GỘP đang tích luỹ; khởi tạo bằng kế hoạch (thành phẩm, LLC nhỏ nhất).
    CREATE TEMP TABLE _req (
        item_id bigint PRIMARY KEY,
        gross   numeric(18,6) NOT NULL DEFAULT 0
    ) ON COMMIT DROP;
    INSERT INTO _req(item_id, gross)
    SELECT item_id, SUM(planned_qty)
    FROM production_plan_line
    WHERE plan_id = p_plan_id
    GROUP BY item_id;

    SELECT MAX(llc) INTO v_max_llc FROM _llc;

    -- Duyệt theo low-level-code TĂNG DẦN: item ở cấp này đã gộp đủ gross từ mọi cha
    -- (cha luôn có LLC nhỏ hơn) -> net tồn rồi nổ net>0 xuống component.
    FOR v_llc IN 0 .. COALESCE(v_max_llc, 0) LOOP
        WITH netted AS (
            SELECT r.item_id,
                   r.gross,
                   COALESCE(av.q, 0) AS avail,
                   COALESCE(oo.q, 0) AS on_order,
                   GREATEST(r.gross - COALESCE(av.q, 0) - COALESCE(oo.q, 0), 0) AS net
            FROM _req r
            JOIN _llc c ON c.item_id = r.item_id AND c.llc = v_llc
            LEFT JOIN (
                SELECT item_id, SUM(qty_available) AS q
                FROM v_available_stock GROUP BY item_id
            ) av ON av.item_id = r.item_id
            LEFT JOIN (
                SELECT pol.item_id, SUM(prog.open_qty) AS q
                FROM v_po_line_progress prog
                JOIN purchase_order_line pol ON pol.id = prog.po_line_id
                JOIN purchase_order      po  ON po.id  = pol.po_id AND po.status NOT IN ('closed','cancelled')
                GROUP BY pol.item_id
            ) oo ON oo.item_id = r.item_id
        ),
        ins AS (   -- ghi mrp_requirement cho MỌI item ở cấp này (FG/SF/RM)
            INSERT INTO mrp_requirement(mrp_run_id, item_id, gross_qty, available_qty, on_order_qty, net_qty, uom_id)
            SELECT v_run_id, n.item_id, n.gross, n.avail, n.on_order, n.net, i.base_uom_id
            FROM netted n
            JOIN item i ON i.id = n.item_id
            RETURNING 1
        )
        -- nổ net>0 của item CÓ active BOM xuống component (cộng dồn gross cấp dưới).
        INSERT INTO _req(item_id, gross)
        SELECT bl.component_item_id,
               SUM(n.net * bl.qty / b.output_qty * (1 + bl.scrap_pct / 100.0))
        FROM netted n
        JOIN bom      b  ON b.item_id = n.item_id AND b.status = 'active'
        JOIN bom_line bl ON bl.bom_id = b.id
        WHERE n.net > 0
        GROUP BY bl.component_item_id
        ON CONFLICT (item_id) DO UPDATE SET gross = _req.gross + EXCLUDED.gross;
    END LOOP;

    RETURN v_run_id;
END;
$$;

-- #############################################################################
-- ##########################  PHẦN ĐỢT 4  #####################################
-- Auto tạo lệnh SX từ MRP + Genealogy theo tỷ lệ tiêu hao + Giá vốn theo lô.
-- Đặt SAU fn_run_mrp, TRƯỚC mục 10. Đợt 4 KHÔNG thêm bảng (chỉ +cột/+hàm/+view)
--   -> mục 10 không đổi; cột mới tự được audit (trigger dùng to_jsonb(NEW)).
-- #############################################################################

-- 0c. Cột liên kết (truy nguồn MRP->MO) + cột giá vốn thực theo lô
ALTER TABLE production_order ADD COLUMN mrp_run_id bigint REFERENCES mrp_run(id);          -- MO sinh từ lần MRP nào
ALTER TABLE mrp_requirement  ADD COLUMN production_order_id bigint REFERENCES production_order(id); -- song song pr_line_id (item mua)
ALTER TABLE lot              ADD COLUMN unit_cost numeric(18,6);                            -- giá vốn thực/đơn vị (NULL tới khi cuộn)

-- =============================================================================
-- P4.F1  AUTO TẠO LỆNH SX TỪ MRP — fn_generate_production_orders()
--   Sinh production_order cho MỌI item SẢN XUẤT (có active BOM) net>0 của 1 lần MRP
--   (cả FG lẫn SF, theo net đã trừ tồn). Tự sinh production_order_material (nổ BOM 1 cấp
--   + scrap) để chạy issue/shortage (đợt 3). Idempotent. Item MUA (không BOM) vẫn đi PR.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_generate_production_orders(
        p_mrp_run_id bigint, p_mo_prefix varchar DEFAULT 'MO-AUTO', p_created_by uuid DEFAULT NULL)
    RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_count int;
BEGIN
    WITH cand AS (
        SELECT mr.id AS req_id, mr.item_id, mr.net_qty, mr.uom_id, b.id AS bom_id
        FROM mrp_requirement mr
        JOIN bom b ON b.item_id = mr.item_id AND b.status = 'active'   -- chỉ item sản xuất
        WHERE mr.mrp_run_id = p_mrp_run_id AND mr.net_qty > 0
          AND mr.production_order_id IS NULL                           -- idempotent: bỏ req đã có MO
    ),
    ins_mo AS (
        INSERT INTO production_order(mo_no, item_id, bom_id, planned_qty, uom_id, status, mrp_run_id, created_by)
        SELECT format('%s-%s-%s', p_mo_prefix, p_mrp_run_id, c.req_id),
               c.item_id, c.bom_id, c.net_qty, c.uom_id, 'planned', p_mrp_run_id, p_created_by
        FROM cand c
        RETURNING id AS mo_id, item_id, bom_id, planned_qty
    ),
    upd AS (   -- gắn ngược MO vào dòng MRP (truy nguồn)
        UPDATE mrp_requirement mr SET production_order_id = im.mo_id
        FROM ins_mo im
        WHERE mr.mrp_run_id = p_mrp_run_id AND mr.item_id = im.item_id
        RETURNING 1
    ),
    ins_mat AS (   -- định mức NVL 1 cấp của MO (gồm scrap) -> để xuất kho theo lệnh
        INSERT INTO production_order_material(mo_id, component_item_id, required_qty, uom_id)
        SELECT im.mo_id, bl.component_item_id,
               im.planned_qty * bl.qty / b.output_qty * (1 + bl.scrap_pct / 100.0), bl.uom_id
        FROM ins_mo im
        JOIN bom      b  ON b.id = im.bom_id
        JOIN bom_line bl ON bl.bom_id = b.id
        RETURNING 1
    )
    SELECT count(*) INTO v_count FROM ins_mo;   -- các CTE sửa-dữ-liệu vẫn chạy hết
    RETURN v_count;
END;
$$;

-- =============================================================================
-- P4.F2  GENEALOGY THEO TỶ LỆ TIÊU HAO — v_lot_genealogy_alloc
--   Định lượng từng cạnh cha->con trong 1 MO theo tỷ lệ sản lượng lô con
--   (bảo toàn khối lượng: Σ alloc_qty theo con = consumed_qty của cha). Cơ sở chia chi phí.
-- =============================================================================
CREATE VIEW v_lot_genealogy_alloc AS
WITH mo_consume AS (   -- (mo, lô cha): tổng tiêu hao
    SELECT mi.mo_id, mil.lot_id AS parent_lot_id, SUM(mil.qty) AS consumed_qty
    FROM material_issue mi
    JOIN material_issue_line mil ON mil.issue_id = mi.id AND mil.lot_id IS NOT NULL
    WHERE mi.status = 'posted'
    GROUP BY mi.mo_id, mil.lot_id
),
mo_produce AS (        -- (mo, lô con): sản lượng
    SELECT pr.mo_id, prl.lot_id AS child_lot_id, SUM(prl.produced_qty) AS produced_qty
    FROM production_receipt pr
    JOIN production_receipt_line prl ON prl.receipt_id = pr.id
    WHERE pr.status = 'posted'
    GROUP BY pr.mo_id, prl.lot_id
),
mo_total AS (
    SELECT mo_id, SUM(produced_qty) AS total_produced FROM mo_produce GROUP BY mo_id
)
SELECT c.mo_id, mo.mo_no, c.parent_lot_id, p.child_lot_id,
       c.consumed_qty, p.produced_qty, t.total_produced,
       p.produced_qty / t.total_produced                  AS output_ratio,
       c.consumed_qty * p.produced_qty / t.total_produced AS alloc_qty   -- kg lô cha nằm trong lô con
FROM mo_consume c
JOIN mo_produce p ON p.mo_id = c.mo_id
JOIN mo_total   t ON t.mo_id = c.mo_id
JOIN production_order mo ON mo.id = c.mo_id;

-- =============================================================================
-- P4.F3  GIÁ VỐN THEO LÔ (actual lot costing) — fn_roll_lot_cost() + view định giá
--   Lô MUA = bình quân giá GR; lô SX = Σ(NVL tiêu hao × giá lô) / sản lượng MO
--   (đồng giá mọi lô ra của MO). Cuộn bottom-up tới điểm bất động. CHỈ NVL (không overhead).
--   Đồng bộ về lot CHỈ lô đổi giá (audit tối thiểu). Lô thiếu cơ sở giá -> để NULL.
--   Định giá tồn = số lượng ledger (v_stock_on_hand) × lot.unit_cost (ledger giữ bất biến).
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_roll_lot_cost() RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_pass     int := 0;
    v_progress int;
BEGIN
    DROP TABLE IF EXISTS _lc;   -- an toàn nếu gọi lại trong cùng transaction
    CREATE TEMP TABLE _lc(lot_id bigint PRIMARY KEY, unit_cost numeric(18,6)) ON COMMIT DROP;

    -- 1. lô MUA: bình quân gia quyền theo giá GR
    INSERT INTO _lc(lot_id, unit_cost)
    SELECT grl.lot_id, SUM(grl.received_qty * grl.unit_price) / SUM(grl.received_qty)
    FROM goods_receipt_line grl
    WHERE grl.lot_id IS NOT NULL
    GROUP BY grl.lot_id
    HAVING SUM(grl.received_qty) > 0;

    -- 2. lô SX: cuộn từ dưới lên (lô con costable khi MỌI lô input đã có giá)
    LOOP
        v_pass := v_pass + 1;
        WITH mo_in AS (
            SELECT mi.mo_id, SUM(mil.qty * lc.unit_cost) AS input_cost,
                   bool_and(lc.unit_cost IS NOT NULL) AS ready
            FROM material_issue mi
            JOIN material_issue_line mil ON mil.issue_id = mi.id AND mil.lot_id IS NOT NULL
            LEFT JOIN _lc lc ON lc.lot_id = mil.lot_id
            WHERE mi.status = 'posted'
            GROUP BY mi.mo_id
        ),
        mo_out AS (
            SELECT pr.mo_id, SUM(prl.produced_qty) AS out_qty
            FROM production_receipt pr
            JOIN production_receipt_line prl ON prl.receipt_id = pr.id
            WHERE pr.status = 'posted'
            GROUP BY pr.mo_id
        ),
        mo_cost AS (
            SELECT i.mo_id, i.input_cost / o.out_qty AS unit_cost
            FROM mo_in i JOIN mo_out o ON o.mo_id = i.mo_id
            WHERE i.ready AND o.out_qty > 0
        ),
        tgt AS (
            SELECT DISTINCT prl.lot_id, mc.unit_cost
            FROM mo_cost mc
            JOIN production_receipt pr ON pr.mo_id = mc.mo_id AND pr.status = 'posted'
            JOIN production_receipt_line prl ON prl.receipt_id = pr.id
            WHERE NOT EXISTS (SELECT 1 FROM _lc x WHERE x.lot_id = prl.lot_id)   -- chưa tính
        )
        INSERT INTO _lc(lot_id, unit_cost) SELECT lot_id, unit_cost FROM tgt
        ON CONFLICT (lot_id) DO NOTHING;
        GET DIAGNOSTICS v_progress = ROW_COUNT;
        EXIT WHEN v_progress = 0 OR v_pass >= 20;
    END LOOP;

    -- 3. đồng bộ vào lot (chỉ lô đổi giá -> ít audit)
    UPDATE lot l SET unit_cost = lc.unit_cost
    FROM _lc lc WHERE l.id = lc.lot_id AND l.unit_cost IS DISTINCT FROM lc.unit_cost;
    RETURN (SELECT count(*) FROM _lc);
END;
$$;

-- Định giá tồn QUA LEDGER: số lượng tồn × giá vốn lô.
CREATE VIEW v_inventory_valuation AS
SELECT soh.bin_id, soh.item_id, soh.lot_id, soh.qty_on_hand, l.unit_cost,
       soh.qty_on_hand * COALESCE(l.unit_cost, 0) AS stock_value
FROM v_stock_on_hand soh
LEFT JOIN lot l ON l.id = soh.lot_id;

-- Giá vốn từng lệnh SX (review): tổng NVL vào / sản lượng = đơn giá.
CREATE VIEW v_mo_cost AS
SELECT mo.id AS mo_id, mo.mo_no, mo.item_id,
       inp.input_cost, outp.out_qty,
       inp.input_cost / NULLIF(outp.out_qty, 0) AS unit_cost
FROM production_order mo
LEFT JOIN (
    SELECT mi.mo_id, SUM(mil.qty * il.unit_cost) AS input_cost
    FROM material_issue mi
    JOIN material_issue_line mil ON mil.issue_id = mi.id AND mil.lot_id IS NOT NULL
    JOIN lot il ON il.id = mil.lot_id
    WHERE mi.status = 'posted'
    GROUP BY mi.mo_id
) inp ON inp.mo_id = mo.id
LEFT JOIN (
    SELECT pr.mo_id, SUM(prl.produced_qty) AS out_qty
    FROM production_receipt pr
    JOIN production_receipt_line prl ON prl.receipt_id = pr.id
    WHERE pr.status = 'posted'
    GROUP BY pr.mo_id
) outp ON outp.mo_id = mo.id;

-- =============================================================================
-- 10. TÍCH HỢP TRIGGER CỦA CORE (002) CHO BẢNG ERP
--   * KHÔNG định nghĩa lại set_updated_at() — dùng lại hàm của 002.
--   * Re-attach (idempotent) updated_at + audit cho các bảng mới ở 004.
--   * LOẠI inventory_movement khỏi audit (ledger bất biến — audit sẽ phình vô ích).
-- =============================================================================

-- 10.1 updated_at cho mọi bảng có cột updated_at (gồm pr/po/gr của ERP)
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
                EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_name, r.table_schema, r.table_name);
                EXECUTE format(
                        'CREATE TRIGGER %I BEFORE UPDATE ON %I.%I
                         FOR EACH ROW EXECUTE FUNCTION set_updated_at();',
                        trg_name, r.table_schema, r.table_name);
            END LOOP;
    END;
$$;

-- 10.2 audit cho bảng ERP (loại audit_logs%, user_sessions, inventory_movement)
DO
$$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN
            SELECT t.table_name,
                   COALESCE((
                       SELECT string_agg('''' || a.attname || '''', ', ')
                       FROM pg_index i
                       JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                       WHERE i.indrelid = t.table_name::regclass AND i.indisprimary
                   ), '''id''') AS pk_args
            FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_type = 'BASE TABLE'
              AND t.table_name NOT LIKE 'audit_logs%'
              AND t.table_name <> 'user_sessions'
              AND t.table_name <> 'inventory_movement'
            LOOP
                EXECUTE format('
                    DROP TRIGGER IF EXISTS trg_audit_ins_del_%I ON %I;
                    CREATE TRIGGER trg_audit_ins_del_%I
                    AFTER INSERT OR DELETE ON %I
                    FOR EACH ROW EXECUTE FUNCTION fn_generic_audit_log(%s);',
                    rec.table_name, rec.table_name, rec.table_name, rec.table_name, rec.pk_args);

                EXECUTE format('
                    DROP TRIGGER IF EXISTS trg_audit_upd_%I ON %I;
                    CREATE TRIGGER trg_audit_upd_%I
                    AFTER UPDATE ON %I
                    FOR EACH ROW
                    WHEN (OLD.* IS DISTINCT FROM NEW.*)
                    EXECUTE FUNCTION fn_generic_audit_log(%s);',
                    rec.table_name, rec.table_name, rec.table_name, rec.table_name, rec.pk_args);
            END LOOP;
    END;
$$;

-- =============================================================================
-- TRẠNG THÁI & GIỚI HẠN ĐÃ BIẾT
--   * ĐỢT 1/2/3/4 đã dựng đầy đủ trong file này (xem header).
--   * Ledger inventory_movement ghi bằng APP khi post chứng từ (GR/transfer/QC/issue/FG receipt);
--     KHÔNG có trigger auto-post — đồng nhất từ đợt 1. Định giá tồn = SL ledger × lot.unit_cost.
--   * fn_run_mrp() net đa cấp -> fn_generate_production_orders() auto tạo MO (FG+SF) + định mức NVL.
--   * fn_roll_lot_cost() cuộn giá vốn thực theo lô (CHỈ NVL). Genealogy định lượng: v_lot_genealogy_alloc
--     (mức MO, 1 cấp). ĐỢT 5 (nếu cần): overhead/nhân công, truyền định lượng genealogy đa cấp, GL.
-- =============================================================================
