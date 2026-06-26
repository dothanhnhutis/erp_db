-- =============================================================================
-- 007 — LUỒNG GIAO DỊCH MẪU (DEMO) — chạy 1 vòng sản xuất hoàn chỉnh
-- =============================================================================
-- Kịch bản: Nhà máy ABC lập kế hoạch sản xuất 1000 hộp "Kem dưỡng ẩm 50ml"
--   (FG-CREAM50), rồi đi qua TOÀN BỘ chuỗi: MRP -> tự tạo lệnh SX -> mua & nhập
--   nguyên liệu -> QC -> sản xuất bulk -> đóng gói thành phẩm -> QC -> giá vốn.
-- Sau 007, MỌI view trong 004 đều có dữ liệu thật để xem (xem ERP.md).
--
-- DEMO/optional: chỉ là dữ liệu minh hoạ. Trên production có thể BỎ QUA file này
--   (giữ 006 là đủ "mô hình"). Chạy 1 lần khi init (không idempotent).
-- Toàn bộ gói trong 1 DO block, dùng biến để giữ id sinh tự động; RAISE NOTICE
--   kể từng bước. Ledger inventory_movement ghi kiểu app (đồng nhất đợt 1–4).
-- =============================================================================
DO
$$
DECLARE
    v_admin    uuid   := (SELECT id FROM users LIMIT 1);                 -- người thao tác (RBAC)
    v_loc      bigint := (SELECT id FROM location WHERE code='KHO-HCM');
    v_kg       bigint := (SELECT id FROM uom WHERE code='kg');
    v_cai      bigint := (SELECT id FROM uom WHERE code='cai');
    v_plan     bigint;
    v_run      bigint;
    v_pr       bigint;
    v_po_chem  bigint;
    v_po_pack  bigint;
    v_gr_chem  bigint;
    v_gr_pack  bigint;
    v_po_gly   bigint;   -- PO riêng cho glycerin (minh hoạ mua kg)
    v_gr_gly   bigint;   -- GR riêng cho glycerin (minh hoạ nhận thùng)
    v_lot_gly  bigint;
    v_gr_walk  bigint;   -- phiếu nhận XÁCH TAY (không PO)
    v_lot_cart bigint;   -- lô PK-CARTON xách tay (thủ kho duyệt ĐẠT)
    v_lot_btl  bigint;   -- lô PK-BOTTLE100 xách tay (thủ kho LOẠI -> tạm trữ)
    v_lot_eth  bigint;   -- lô SOL-ETHANOL xách tay (COA sai -> QC/QA)
    v_loan      bigint;  -- khoản cho mượn (đối tác ngoài)
    v_loan_line bigint;  -- dòng cho mượn glycerin
    v_gr_ret    bigint;  -- phiếu nhận trả (loan_return)
    v_bin_gly   bigint;  -- bin Bảo quản của glycerin
    v_mo_sf    bigint;
    v_mo_fg    bigint;
    v_mi       bigint;
    v_prf      bigint;
    v_lot_sf   bigint;
    v_lot_fg   bigint;
    v_n_mo     int;
    v_fg_cost  numeric;
    -- ĐỢT 5b — bán hàng
    v_cust_z         bigint := (SELECT id FROM customer WHERE code='CUST-Z');
    v_cust_xyz       bigint := (SELECT id FROM customer WHERE code='CUST-XYZ');
    v_bin_fg         bigint;   -- bin Bảo quản thành phẩm FG-CREAM50
    v_so             bigint;   -- đơn bán
    v_so_line        bigint;
    v_ship           bigint;   -- phiếu giao bán thường
    v_ship_line      bigint;
    v_ship_loan      bigint;   -- phiếu giao bán hàng cho-mượn (loan->sale)
    v_ship_line_loan bigint;
    v_inv_z          bigint;   -- hoá đơn CUST-Z
    v_inv_xyz        bigint;   -- hoá đơn CUST-XYZ (loan->sale)
    -- ĐỢT 6 — vật chứa (handling unit)
    v_lot_drum   bigint;
    v_hu_drum    bigint;
    v_hu_can1    bigint;
    v_hu_can2    bigint;
    v_hu_can3    bigint;
    v_hu_plt     bigint;
    v_bin_d_bq   bigint;
    v_bin_d_tt   bigint;
BEGIN
    -- Bảng tra cứu tạm: bin Tạm trữ (TT) & Bảo quản (BQ) theo KHU của từng item.
    --   item_type -> zone_type: RAW_MATERIAL->ZRM, PACKAGING->ZPK, SOLVENT->ZSOL,
    --   SEMI_FINISHED & FINISHED_GOOD -> ZFG (bulk lưu chung khu thành phẩm).
    CREATE TEMP TABLE _bin ON COMMIT DROP AS
    SELECT i.id AS item_id,
           (SELECT b.id FROM storage_bin b JOIN warehouse_zone z ON z.id=b.zone_id
            WHERE z.code = CASE i.item_type WHEN 'RAW_MATERIAL' THEN 'ZRM' WHEN 'PACKAGING' THEN 'ZPK'
                                            WHEN 'SOLVENT' THEN 'ZSOL' ELSE 'ZFG' END
              AND b.code='TT' AND z.location_id=v_loc) AS tt_bin,
           (SELECT b.id FROM storage_bin b JOIN warehouse_zone z ON z.id=b.zone_id
            WHERE z.code = CASE i.item_type WHEN 'RAW_MATERIAL' THEN 'ZRM' WHEN 'PACKAGING' THEN 'ZPK'
                                            WHEN 'SOLVENT' THEN 'ZSOL' ELSE 'ZFG' END
              AND b.code='BQ' AND z.location_id=v_loc) AS bq_bin
    FROM item i;

    -- Đơn giá mua (giá vốn nhập) + Số lượng mua (làm tròn LÊN so với nhu cầu = tồn an toàn).
    CREATE TEMP TABLE _buy ON COMMIT DROP AS
    SELECT i.id AS item_id, d.price::numeric AS price, d.qty::numeric AS qty
    -- (RM-GLYCERIN xử lý RIÊNG bên dưới: base=g, mua kg, nhận thùng — minh hoạ đa đơn vị.)
    FROM item i JOIN (VALUES
        ('RM-WATER',     2,   40),   -- cần 35  -> mua 40
        ('RM-ARGAN',     500, 5),    -- cần 4.2 -> mua 5
        ('RM-ALOE',      120, 3),    -- cần 2.5 -> mua 3
        ('RM-PRESV',     300, 2),    -- cần 1.0 -> mua 2
        ('PK-BOTTLE50',  1.5, 1100), -- cần 1000-> mua 1100
        ('PK-CAP',       0.5, 1100),
        ('PK-LABEL',     0.2, 1100),
        ('PK-BOX',       1.0, 1100)
    ) AS d(code, price, qty) ON d.code=i.code;

    -- ===== BƯỚC 1: PHÒNG KẾ HOẠCH lập kế hoạch sản xuất =====
    INSERT INTO production_plan(plan_no, status, planned_by, note)
    VALUES ('MP-DEMO-01', 'confirmed', v_admin, 'Demo: sản xuất 1000 Kem dưỡng ẩm 50ml')
    RETURNING id INTO v_plan;
    INSERT INTO production_plan_line(plan_id, item_id, planned_qty, uom_id, note)
    VALUES (v_plan, (SELECT id FROM item WHERE code='FG-CREAM50'), 1000, v_cai, 'Đơn hàng kênh phân phối');
    RAISE NOTICE 'Bước 1: Kế hoạch MP-DEMO-01 -> 1000 cái FG-CREAM50 (confirmed).';

    -- ===== BƯỚC 2: CHẠY MRP (nổ BOM đa cấp, net tồn = 0 vì DB mới) =====
    v_run := fn_run_mrp(v_plan, 'RUN-DEMO-01', v_admin);
    RAISE NOTICE 'Bước 2: MRP RUN-DEMO-01 (id=%) -> mrp_requirement mọi cấp (SF-CREAM 50kg; WATER 35; ARGAN 4.2 do scrap 5%%; bao bì 1000).', v_run;

    -- ===== BƯỚC 3: SINH PR cho item ĐI MUA (không có active BOM) net>0 =====
    INSERT INTO purchase_requisition(pr_no, mrp_run_id, requested_by, department, status, note)
    VALUES ('PR-DEMO-01', v_run, v_admin, 'Kế hoạch', 'submitted', 'PR tự sinh từ MRP demo')
    RETURNING id INTO v_pr;
    WITH purchased AS (
        SELECT mr.id AS req_id, mr.item_id, mr.net_qty, mr.uom_id
        FROM mrp_requirement mr
        WHERE mr.mrp_run_id = v_run AND mr.net_qty > 0
          AND NOT EXISTS (SELECT 1 FROM bom b WHERE b.item_id=mr.item_id AND b.status='active')
    ),
    ins AS (
        INSERT INTO purchase_requisition_line(pr_id, item_id, qty, uom_id)
        SELECT v_pr, item_id, net_qty, uom_id FROM purchased
        RETURNING id, item_id
    )
    UPDATE mrp_requirement mr SET pr_line_id = ins.id
    FROM ins WHERE mr.mrp_run_id=v_run AND mr.item_id=ins.item_id;
    RAISE NOTICE 'Bước 3: PR-DEMO-01 -> % dòng nguyên liệu/bao bì cần mua.',
                 (SELECT count(*) FROM purchase_requisition_line WHERE pr_id=v_pr);

    -- ===== BƯỚC 4: TỰ TẠO LỆNH SX (FG + SF) + định mức NVL =====
    v_n_mo := fn_generate_production_orders(v_run, 'MO-DEMO', v_admin);
    SELECT id INTO v_mo_sf FROM production_order WHERE mrp_run_id=v_run AND item_id=(SELECT id FROM item WHERE code='SF-CREAM');
    SELECT id INTO v_mo_fg FROM production_order WHERE mrp_run_id=v_run AND item_id=(SELECT id FROM item WHERE code='FG-CREAM50');
    RAISE NOTICE 'Bước 4: Tạo % lệnh SX (MO-DEMO): bulk SF-CREAM + thành phẩm FG-CREAM50.', v_n_mo;

    -- ===== BƯỚC 5: PHÒNG THU MUA — PO (2 NCC) -> nhập kho (GR) -> QC -> Bảo quản =====
    -- 5a. 2 PO (hoá chất / bao bì), line lấy từ PR (truy nguồn pr_line_id), số lượng = _buy.qty
    INSERT INTO purchase_order(po_no, supplier_id, status, created_by)
    VALUES ('PO-CHEM-01', (SELECT id FROM supplier WHERE code='SUP-CHEM'), 'confirmed', v_admin) RETURNING id INTO v_po_chem;
    INSERT INTO purchase_order(po_no, supplier_id, status, created_by)
    VALUES ('PO-PACK-01', (SELECT id FROM supplier WHERE code='SUP-PACK'), 'confirmed', v_admin) RETURNING id INTO v_po_pack;

    INSERT INTO purchase_order_line(po_id, pr_line_id, item_id, ordered_qty, uom_id, unit_price)
    SELECT CASE WHEN i.item_type='PACKAGING' THEN v_po_pack ELSE v_po_chem END,
           prl.id, prl.item_id, b.qty, prl.uom_id, b.price
    FROM purchase_requisition_line prl
    JOIN item i  ON i.id = prl.item_id
    JOIN _buy b  ON b.item_id = prl.item_id
    WHERE prl.pr_id = v_pr;

    -- 5b. Tạo lô nhập cho từng item (lô NCC: 'L-<code>'). Item cần QC -> quarantine, còn lại approved.
    INSERT INTO lot(lot_no, item_id, supplier_id, qc_status, manufacture_date)
    SELECT 'L-'||i.code, pol.item_id, po.supplier_id,
           (CASE WHEN i.requires_qc THEN 'quarantine' ELSE 'approved' END)::qc_status, current_date
    FROM purchase_order_line pol
    JOIN purchase_order po ON po.id = pol.po_id
    JOIN item i ON i.id = pol.item_id
    WHERE pol.po_id IN (v_po_chem, v_po_pack);

    -- 5c. 2 phiếu nhập (GR) đã posted
    INSERT INTO goods_receipt(gr_no, po_id, supplier_id, location_id, received_by, status)
    VALUES ('GR-CHEM-01', v_po_chem, (SELECT id FROM supplier WHERE code='SUP-CHEM'), v_loc, v_admin, 'posted') RETURNING id INTO v_gr_chem;
    INSERT INTO goods_receipt(gr_no, po_id, supplier_id, location_id, received_by, status)
    VALUES ('GR-PACK-01', v_po_pack, (SELECT id FROM supplier WHERE code='SUP-PACK'), v_loc, v_admin, 'posted') RETURNING id INTO v_gr_pack;

    -- 5d. Dòng nhập: cần QC -> vào bin Tạm trữ (TT); không QC -> thẳng Bảo quản (BQ).
    INSERT INTO goods_receipt_line(gr_id, po_line_id, item_id, lot_id, to_bin_id,
                                   declared_qty, received_qty, qty_uom_id, unit_price, qc_status)
    SELECT CASE WHEN i.item_type='PACKAGING' THEN v_gr_pack ELSE v_gr_chem END,
           pol.id, pol.item_id,
           (SELECT id FROM lot WHERE item_id=pol.item_id AND lot_no='L-'||i.code),
           CASE WHEN i.requires_qc THEN bn.tt_bin ELSE bn.bq_bin END,
           pol.ordered_qty, pol.ordered_qty, pol.uom_id, pol.unit_price,
           (CASE WHEN i.requires_qc THEN 'quarantine' ELSE 'approved' END)::qc_status
    FROM purchase_order_line pol
    JOIN item i  ON i.id = pol.item_id
    JOIN _bin bn ON bn.item_id = pol.item_id
    WHERE pol.po_id IN (v_po_chem, v_po_pack);

    -- 5e. Ledger NHẬP (+) vào bin của dòng nhập (ghi theo BASE: received_qty_base).
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'receipt', grl.item_id, grl.to_bin_id, grl.lot_id, grl.received_qty_base, grl.unit_price, 'goods_receipt', grl.id
    FROM goods_receipt_line grl WHERE grl.gr_id IN (v_gr_chem, v_gr_pack);

    -- 5f. QC NHẬP đạt cho NVL (requires_qc): ghi qc_inspection -> lô approved -> chuyển TT sang BQ.
    INSERT INTO qc_inspection(gr_line_id, lot_id, inspected_by, result, note)
    SELECT grl.id, grl.lot_id, v_admin, 'approved', 'IQC đạt'
    FROM goods_receipt_line grl JOIN item i ON i.id=grl.item_id
    WHERE grl.gr_id IN (v_gr_chem, v_gr_pack) AND i.requires_qc;

    UPDATE lot SET qc_status='approved'
    WHERE id IN (SELECT grl.lot_id FROM goods_receipt_line grl JOIN item i ON i.id=grl.item_id
                 WHERE grl.gr_id IN (v_gr_chem, v_gr_pack) AND i.requires_qc);

    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'transfer', grl.item_id, grl.to_bin_id, grl.lot_id, -grl.received_qty_base, grl.unit_price, 'qc_release', grl.id
    FROM goods_receipt_line grl JOIN item i ON i.id=grl.item_id
    WHERE grl.gr_id IN (v_gr_chem, v_gr_pack) AND i.requires_qc;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'qc_release', grl.item_id, bn.bq_bin, grl.lot_id, grl.received_qty_base, grl.unit_price, 'qc_release', grl.id
    FROM goods_receipt_line grl JOIN item i ON i.id=grl.item_id JOIN _bin bn ON bn.item_id=grl.item_id
    WHERE grl.gr_id IN (v_gr_chem, v_gr_pack) AND i.requires_qc;
    RAISE NOTICE 'Bước 5: Nhập kho 2 PO, QC đạt, nguyên liệu & bao bì đã vào bin Bảo quản (khả dụng).';

    -- 5g. GLYCERIN — MINH HOẠ ĐA ĐƠN VỊ: base = GRAM, ĐẶT MUA bằng KG, NHẬN bằng THÙNG.
    --     PO 20 kg @ 40/kg ; GR 1 thùng @ 800/thùng (1 thùng = 20000 g). fn_to_base tự quy:
    --     ordered_qty_base = 20×1000 = 20000 g (toàn cục kg→g); received_qty_base = 1×20000 = 20000 g (item PACK).
    INSERT INTO purchase_order(po_no, supplier_id, status, created_by)
    VALUES ('PO-CHEM-GLY', (SELECT id FROM supplier WHERE code='SUP-CHEM'), 'confirmed', v_admin) RETURNING id INTO v_po_gly;
    INSERT INTO purchase_order_line(po_id, pr_line_id, item_id, ordered_qty, uom_id, unit_price)
    VALUES (v_po_gly,
            (SELECT id FROM purchase_requisition_line WHERE pr_id=v_pr AND item_id=(SELECT id FROM item WHERE code='RM-GLYCERIN')),
            (SELECT id FROM item WHERE code='RM-GLYCERIN'), 20, v_kg, 40);   -- MUA 20 KG @ 40/kg
    INSERT INTO lot(lot_no, item_id, supplier_id, qc_status, manufacture_date)
    VALUES ('L-RM-GLYCERIN', (SELECT id FROM item WHERE code='RM-GLYCERIN'),
            (SELECT id FROM supplier WHERE code='SUP-CHEM'), 'quarantine', current_date) RETURNING id INTO v_lot_gly;
    INSERT INTO goods_receipt(gr_no, po_id, supplier_id, location_id, received_by, status)
    VALUES ('GR-GLY-01', v_po_gly, (SELECT id FROM supplier WHERE code='SUP-CHEM'), v_loc, v_admin, 'posted') RETURNING id INTO v_gr_gly;
    INSERT INTO goods_receipt_line(gr_id, po_line_id, item_id, lot_id, to_bin_id,
                                   declared_qty, received_qty, qty_uom_id, unit_price, qc_status)
    VALUES (v_gr_gly, (SELECT id FROM purchase_order_line WHERE po_id=v_po_gly),
            (SELECT id FROM item WHERE code='RM-GLYCERIN'), v_lot_gly,
            (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='RM-GLYCERIN')),
            1, 1, (SELECT id FROM uom WHERE code='thung'), 800, 'quarantine');  -- NHẬN 1 THÙNG @ 800/thùng
    -- ledger nhập (BASE g) + QC đạt + chuyển TT->BQ ; unit_cost quy về /g = price*qty/qty_base
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'receipt', grl.item_id, grl.to_bin_id, grl.lot_id, grl.received_qty_base,
           grl.unit_price*grl.received_qty/NULLIF(grl.received_qty_base,0), 'goods_receipt', grl.id
    FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_gly;
    INSERT INTO qc_inspection(gr_line_id, lot_id, inspected_by, result, note)
    SELECT grl.id, grl.lot_id, v_admin, 'approved', 'IQC đạt' FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_gly;
    UPDATE lot SET qc_status='approved' WHERE id = v_lot_gly;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'transfer', grl.item_id, grl.to_bin_id, grl.lot_id, -grl.received_qty_base,
           grl.unit_price*grl.received_qty/NULLIF(grl.received_qty_base,0), 'qc_release', grl.id
    FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_gly;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'qc_release', grl.item_id, bn.bq_bin, grl.lot_id, grl.received_qty_base,
           grl.unit_price*grl.received_qty/NULLIF(grl.received_qty_base,0), 'qc_release', grl.id
    FROM goods_receipt_line grl JOIN _bin bn ON bn.item_id=grl.item_id WHERE grl.gr_id = v_gr_gly;
    RAISE NOTICE 'Bước 5b: Glycerin base=g — đặt 20 kg, nhận 1 thùng -> tồn 20000 g (tiêu hao 7500 g khi SX bulk).';

    -- 5h. NHẬN HÀNG KHÔNG QUA PO (mua xách tay) — po_id/po_line_id/supplier_id = NULL, receipt_source='walk_in'.
    --     + Hàng KHÔNG cần QC: thủ kho duyệt ngay — ĐẠT -> Bảo quản (khả dụng); KHÔNG đạt -> Tạm trữ (chờ trả/bỏ).
    --     + Hàng CẦN QC (hoá chất): đối chiếu COA lúc nhận (đúng/sai vẫn nhận Tạm trữ) -> QC/QA kiểm -> Bảo quản.
    --     Dùng PK-CARTON / PK-BOTTLE100 / SOL-ETHANOL (KHÔNG thuộc BOM kem) + lô '…-WALK' để tách khỏi luồng SX.
    INSERT INTO goods_receipt(gr_no, receipt_source, po_id, supplier_id, source_note, location_id, received_by, status)
    VALUES ('GR-WALK-01', 'walk_in', NULL, NULL, 'Mua xách tay tại cửa hàng vật tư — NV mua hàng mang về',
            v_loc, v_admin, 'posted')
    RETURNING id INTO v_gr_walk;

    INSERT INTO lot(lot_no, item_id, qc_status, manufacture_date)
    VALUES ('L-PK-CARTON-WALK',    (SELECT id FROM item WHERE code='PK-CARTON'),    'approved',   current_date) RETURNING id INTO v_lot_cart;
    INSERT INTO lot(lot_no, item_id, qc_status, manufacture_date)
    VALUES ('L-PK-BOTTLE100-WALK', (SELECT id FROM item WHERE code='PK-BOTTLE100'), 'on_hold',    current_date) RETURNING id INTO v_lot_btl;
    INSERT INTO lot(lot_no, item_id, qc_status, manufacture_date)
    VALUES ('L-SOL-ETHANOL-WALK',  (SELECT id FROM item WHERE code='SOL-ETHANOL'),  'quarantine', current_date) RETURNING id INTO v_lot_eth;

    INSERT INTO goods_receipt_line(gr_id, po_line_id, item_id, lot_id, to_bin_id,
                                   declared_qty, received_qty, qty_uom_id, unit_price, qc_status, coa_status, note)
    VALUES
      (v_gr_walk, NULL, (SELECT id FROM item WHERE code='PK-CARTON'), v_lot_cart,
       (SELECT bq_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='PK-CARTON')),
       50, 50, v_cai, 3.0, 'approved',   'not_required', 'Thủ kho duyệt: thùng carton đạt -> nhập kho'),
      (v_gr_walk, NULL, (SELECT id FROM item WHERE code='PK-BOTTLE100'), v_lot_btl,
       (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='PK-BOTTLE100')),
       20, 20, v_cai, 2.0, 'on_hold',    'not_required', 'Thủ kho: chai trầy xước -> tạm trữ chờ trả'),
      (v_gr_walk, NULL, (SELECT id FROM item WHERE code='SOL-ETHANOL'), v_lot_eth,
       (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='SOL-ETHANOL')),
       10, 10, v_kg,  30,  'quarantine', 'mismatch',     'COA không khớp số lô -> đã báo NCC, vẫn nhận tạm trữ chờ QC');

    -- Ledger NHẬP (+) vào bin của từng dòng (theo BASE). Cả 3 đều ghi nhận tồn vật lý.
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'receipt', grl.item_id, grl.to_bin_id, grl.lot_id, grl.received_qty_base, grl.unit_price, 'goods_receipt', grl.id
    FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_walk;

    -- SOL-ETHANOL: QC/QA kiểm ĐẠT -> lô approved -> chuyển Tạm trữ sang Bảo quản (khả dụng).
    INSERT INTO qc_inspection(gr_line_id, lot_id, inspected_by, result, note)
    SELECT grl.id, grl.lot_id, v_admin, 'approved', 'QC/QA đạt dù COA lệch nhãn'
    FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_walk AND grl.lot_id = v_lot_eth;
    UPDATE lot SET qc_status='approved' WHERE id = v_lot_eth;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'transfer', grl.item_id, grl.to_bin_id, grl.lot_id, -grl.received_qty_base, grl.unit_price, 'qc_release', grl.id
    FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_walk AND grl.lot_id = v_lot_eth;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'qc_release', grl.item_id, bn.bq_bin, grl.lot_id, grl.received_qty_base, grl.unit_price, 'qc_release', grl.id
    FROM goods_receipt_line grl JOIN _bin bn ON bn.item_id=grl.item_id
    WHERE grl.gr_id = v_gr_walk AND grl.lot_id = v_lot_eth;
    RAISE NOTICE 'Bước 5c: Nhận XÁCH TAY (không PO) — PK-CARTON đạt->Bảo quản; PK-BOTTLE100 lỗi->Tạm trữ; SOL-ETHANOL COA sai->QC đạt->Bảo quản.';

    -- ===== BƯỚC 6: SẢN XUẤT BULK (lệnh MO SF-CREAM) =====
    -- 6a. Xuất NVL theo định mức của lệnh (production_order_material) từ bin Bảo quản.
    INSERT INTO material_issue(issue_no, mo_id, location_id, issued_by, status)
    VALUES ('MI-SF-01', v_mo_sf, v_loc, v_admin, 'posted') RETURNING id INTO v_mi;
    INSERT INTO material_issue_line(issue_id, component_item_id, lot_id, from_bin_id, qty, uom_id)
    SELECT v_mi, mom.component_item_id,
           (SELECT id FROM lot WHERE item_id=mom.component_item_id AND lot_no='L-'||i.code),
           bn.bq_bin, mom.required_qty, mom.uom_id
    FROM production_order_material mom
    JOIN item i  ON i.id = mom.component_item_id
    JOIN _bin bn ON bn.item_id = mom.component_item_id
    WHERE mom.mo_id = v_mo_sf;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id)
    SELECT 'production_issue', mil.component_item_id, mil.from_bin_id, mil.lot_id, -mil.qty_base, 'material_issue', mil.id
    FROM material_issue_line mil WHERE mil.issue_id = v_mi;

    -- 6b. Nhập bulk: tạo lô SF-CREAM 50kg (quarantine) vào bin Tạm trữ khu TP.
    INSERT INTO lot(lot_no, item_id, qc_status, manufacture_date)
    VALUES ('L-SF-CREAM-01', (SELECT id FROM item WHERE code='SF-CREAM'), 'quarantine', current_date)
    RETURNING id INTO v_lot_sf;
    INSERT INTO production_receipt(receipt_no, mo_id, item_id, location_id, received_by, status)
    VALUES ('PRF-SF-01', v_mo_sf, (SELECT id FROM item WHERE code='SF-CREAM'), v_loc, v_admin, 'posted')
    RETURNING id INTO v_prf;
    INSERT INTO production_receipt_line(receipt_id, lot_id, to_bin_id, produced_qty, uom_id)
    VALUES (v_prf, v_lot_sf, (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM')), 50, v_kg);
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id)
    VALUES ('production_receipt', (SELECT id FROM item WHERE code='SF-CREAM'),
            (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM')), v_lot_sf, 50, 'production_receipt', v_prf);

    -- 6c. QC bulk đạt -> lô approved -> chuyển sang bin Bảo quản (khả dụng để đóng gói).
    INSERT INTO qc_inspection(production_receipt_line_id, lot_id, inspected_by, result, note)
    VALUES ((SELECT id FROM production_receipt_line WHERE receipt_id=v_prf), v_lot_sf, v_admin, 'approved', 'QC bulk đạt');
    UPDATE lot SET qc_status='approved' WHERE id=v_lot_sf;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id)
    SELECT m.t, (SELECT id FROM item WHERE code='SF-CREAM'), m.bin, v_lot_sf, m.q, 'qc_release', v_prf
    FROM (VALUES
        ('transfer'::movement_type,   (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM')), -50::numeric),
        ('qc_release'::movement_type, (SELECT bq_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM')),  50::numeric)
    ) AS m(t, bin, q);
    RAISE NOTICE 'Bước 6: SX bulk -> lô L-SF-CREAM-01 (50kg) đã QC đạt & vào Bảo quản.';

    -- ===== BƯỚC 7: ĐÓNG GÓI THÀNH PHẨM (lệnh MO FG-CREAM50) =====
    -- 7a. Xuất bulk (lô vừa SX) + bao bì theo định mức.
    INSERT INTO material_issue(issue_no, mo_id, location_id, issued_by, status)
    VALUES ('MI-FG-01', v_mo_fg, v_loc, v_admin, 'posted') RETURNING id INTO v_mi;
    INSERT INTO material_issue_line(issue_id, component_item_id, lot_id, from_bin_id, qty, uom_id)
    SELECT v_mi, mom.component_item_id,
           CASE WHEN mom.component_item_id=(SELECT id FROM item WHERE code='SF-CREAM') THEN v_lot_sf
                ELSE (SELECT id FROM lot WHERE item_id=mom.component_item_id AND lot_no='L-'||i.code) END,
           bn.bq_bin, mom.required_qty, mom.uom_id
    FROM production_order_material mom
    JOIN item i  ON i.id = mom.component_item_id
    JOIN _bin bn ON bn.item_id = mom.component_item_id
    WHERE mom.mo_id = v_mo_fg;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id)
    SELECT 'production_issue', mil.component_item_id, mil.from_bin_id, mil.lot_id, -mil.qty_base, 'material_issue', mil.id
    FROM material_issue_line mil WHERE mil.issue_id = v_mi;

    -- 7b. Nhập thành phẩm: lô FG-CREAM50 x1000 (quarantine) vào Tạm trữ khu TP.
    INSERT INTO lot(lot_no, item_id, qc_status, manufacture_date, expiry_date)
    VALUES ('L-FG-CREAM50-01', (SELECT id FROM item WHERE code='FG-CREAM50'), 'quarantine', current_date, current_date + 730)
    RETURNING id INTO v_lot_fg;
    INSERT INTO production_receipt(receipt_no, mo_id, item_id, location_id, received_by, status)
    VALUES ('PRF-FG-01', v_mo_fg, (SELECT id FROM item WHERE code='FG-CREAM50'), v_loc, v_admin, 'posted')
    RETURNING id INTO v_prf;
    INSERT INTO production_receipt_line(receipt_id, lot_id, to_bin_id, produced_qty, uom_id)
    VALUES (v_prf, v_lot_fg, (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50')), 1000, v_cai);
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id)
    VALUES ('production_receipt', (SELECT id FROM item WHERE code='FG-CREAM50'),
            (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50')), v_lot_fg, 1000, 'production_receipt', v_prf);

    -- 7c. QC xuất xưởng đạt -> approved -> Bảo quản (sẵn sàng giao).
    INSERT INTO qc_inspection(production_receipt_line_id, lot_id, inspected_by, result, note)
    VALUES ((SELECT id FROM production_receipt_line WHERE receipt_id=v_prf), v_lot_fg, v_admin, 'approved', 'QC xuất xưởng đạt');
    UPDATE lot SET qc_status='approved' WHERE id=v_lot_fg;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id)
    SELECT m.t, (SELECT id FROM item WHERE code='FG-CREAM50'), m.bin, v_lot_fg, m.q, 'qc_release', v_prf
    FROM (VALUES
        ('transfer'::movement_type,   (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50')), -1000::numeric),
        ('qc_release'::movement_type, (SELECT bq_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50')),  1000::numeric)
    ) AS m(t, bin, q);
    RAISE NOTICE 'Bước 7: Đóng gói -> lô L-FG-CREAM50-01 (1000 cái) QC đạt & vào Bảo quản.';

    -- ===== BƯỚC 8: CUỘN GIÁ VỐN THỰC THEO LÔ (NVL -> bulk -> thành phẩm) =====
    PERFORM fn_roll_lot_cost();
    SELECT unit_cost INTO v_fg_cost FROM lot WHERE id=v_lot_fg;
    RAISE NOTICE 'Bước 8: Giá vốn -> bulk SF-CREAM = % /kg ; FG-CREAM50 = % /cái.',
                 (SELECT unit_cost FROM lot WHERE id=v_lot_sf), v_fg_cost;

    -- ===== BƯỚC 9: CHO MƯỢN NGUYÊN LIỆU (đối tác NGOÀI) -> THEO DÕI -> NHẬN LẠI =====
    -- Cho "Nhà máy XYZ" mượn 5 kg glycerin (lô đang tồn 12500 g, đã QC approved ở Bảo quản).
    v_bin_gly := (SELECT bq_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='RM-GLYCERIN'));
    INSERT INTO material_loan(loan_no, borrower_name, borrower_contact, location_id, expected_return_date, issued_by, note)
    VALUES ('MLOAN-01', 'Nhà máy XYZ', 'A. Tâm 0909-xxx', v_loc, current_date + 30, v_admin, 'Cho mượn glycerin dùng tạm')
    RETURNING id INTO v_loan;
    INSERT INTO material_loan_line(loan_id, item_id, lot_id, from_bin_id, qty, uom_id)
    VALUES (v_loan, (SELECT id FROM item WHERE code='RM-GLYCERIN'), v_lot_gly, v_bin_gly, 5, v_kg)  -- 5 kg = 5000 g
    RETURNING id INTO v_loan_line;
    -- Ledger: vật tư RỜI tồn (loan_out, -base) từ bin Bảo quản.
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'loan_out', mll.item_id, mll.from_bin_id, mll.lot_id, -mll.qty_base,
           (SELECT unit_cost FROM lot WHERE id=mll.lot_id), 'material_loan', mll.id
    FROM material_loan_line mll WHERE mll.id = v_loan_line;

    -- Nhận lại 3 kg (trả 1 phần) -> phiếu nhận 'loan_return' (KHÔNG PO), về lại Bảo quản cùng lô.
    INSERT INTO goods_receipt(gr_no, receipt_source, po_id, supplier_id, loan_id, source_note, location_id, received_by, status)
    VALUES ('GR-RET-01', 'loan_return', NULL, NULL, v_loan, 'Nhà máy XYZ trả lại glycerin', v_loc, v_admin, 'posted')
    RETURNING id INTO v_gr_ret;
    INSERT INTO goods_receipt_line(gr_id, po_line_id, loan_line_id, item_id, lot_id, to_bin_id,
                                   declared_qty, received_qty, qty_uom_id, unit_price, qc_status, coa_status, note)
    VALUES (v_gr_ret, NULL, v_loan_line, (SELECT id FROM item WHERE code='RM-GLYCERIN'), v_lot_gly, v_bin_gly,
            3, 3, v_kg, 0, 'approved', 'not_required', 'Trả 1 phần; còn cho mượn lại');
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'loan_return', grl.item_id, grl.to_bin_id, grl.lot_id, grl.received_qty_base,
           (SELECT unit_cost FROM lot WHERE id=grl.lot_id), 'goods_receipt', grl.id
    FROM goods_receipt_line grl WHERE grl.gr_id = v_gr_ret;
    RAISE NOTICE 'Bước 9: Cho NM-XYZ mượn 5 kg glycerin (5000 g) -> nhận lại 3 kg (3000 g) -> còn cho mượn 2000 g.';

    -- ===== BƯỚC 10: BÁN HÀNG (đợt 5b) — bán thường + bán hàng đang-cho-mượn (loan->sale) =====
    -- 10a. BÁN THƯỜNG: CUST-Z mua 100 hộp FG-CREAM50 @20 (giá vốn 6.27/cái) -> xuất kho + COGS.
    v_bin_fg := (SELECT bq_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50'));
    INSERT INTO sales_order(so_no, customer_id, status, created_by, approved_by, expected_ship_date, note)
    VALUES ('SO-DEMO-01', v_cust_z, 'confirmed', v_admin, v_admin, current_date, 'Đơn bán kem dưỡng')
    RETURNING id INTO v_so;
    INSERT INTO sales_order_line(so_id, item_id, ordered_qty, uom_id, unit_price)
    VALUES (v_so, (SELECT id FROM item WHERE code='FG-CREAM50'), 100, v_cai, 20)
    RETURNING id INTO v_so_line;
    -- Phiếu giao (posted) -> xuất từ bin Bảo quản TP.
    INSERT INTO sales_shipment(shipment_no, so_id, customer_id, location_id, shipped_by, status, note)
    VALUES ('DO-DEMO-01', v_so, v_cust_z, v_loc, v_admin, 'posted', 'Giao 100 hộp')
    RETURNING id INTO v_ship;
    INSERT INTO sales_shipment_line(shipment_id, so_line_id, item_id, lot_id, from_bin_id, shipped_qty, uom_id, unit_price)
    VALUES (v_ship, v_so_line, (SELECT id FROM item WHERE code='FG-CREAM50'), v_lot_fg, v_bin_fg, 100, v_cai, 20)
    RETURNING id INTO v_ship_line;
    -- Ledger: xuất bán (sales_issue, -base) từ bin Bảo quản — CHỈ dòng bán thường (loan_line_id NULL).
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'sales_issue', ssl.item_id, ssl.from_bin_id, ssl.lot_id, -ssl.shipped_qty_base,
           (SELECT unit_cost FROM lot WHERE id=ssl.lot_id), 'sales_shipment', ssl.id
    FROM sales_shipment_line ssl WHERE ssl.id = v_ship_line AND ssl.loan_line_id IS NULL;
    UPDATE sales_order SET status='shipped' WHERE id=v_so;
    -- Hoá đơn VAT 8% (net 2000 / thuế 160 / tổng 2160) + thu 1 phần 1000 -> còn nợ 1160.
    INSERT INTO sales_invoice(invoice_no, customer_id, due_date, tax_rate, status, created_by, note)
    VALUES ('INV-DEMO-01', v_cust_z, current_date + 30, 8.0, 'issued', v_admin, 'HĐ kem dưỡng')
    RETURNING id INTO v_inv_z;
    INSERT INTO sales_invoice_line(invoice_id, shipment_line_id, item_id, qty, uom_id, unit_price)
    VALUES (v_inv_z, v_ship_line, (SELECT id FROM item WHERE code='FG-CREAM50'), 100, v_cai, 20);
    INSERT INTO customer_payment(payment_no, customer_id, invoice_id, amount, method, received_by)
    VALUES ('PAY-DEMO-01', v_cust_z, v_inv_z, 1000, 'bank', v_admin);
    UPDATE sales_invoice SET status='partially_paid' WHERE id=v_inv_z;

    -- 10b. LOAN->SALE: NM-XYZ không trả 2 kg glycerin còn lại -> MUA luôn (giá bán 50/kg; giá vốn 0.04/g).
    --   Hàng đã RỜI kho từ loan_out -> phiếu giao KHÔNG post ledger (from_bin NULL, loan_line_id set).
    INSERT INTO sales_shipment(shipment_no, so_id, customer_id, location_id, shipped_by, status, loan_id, note)
    VALUES ('DO-DEMO-02', NULL, v_cust_xyz, v_loc, v_admin, 'posted', v_loan, 'Bán phần glycerin đang cho mượn')
    RETURNING id INTO v_ship_loan;
    INSERT INTO sales_shipment_line(shipment_id, so_line_id, item_id, lot_id, from_bin_id, shipped_qty, uom_id, unit_price, loan_line_id)
    VALUES (v_ship_loan, NULL, (SELECT id FROM item WHERE code='RM-GLYCERIN'), v_lot_gly, NULL, 2, v_kg, 50, v_loan_line)
    RETURNING id INTO v_ship_line_loan;
    -- (KHÔNG post inventory_movement: hàng đã trừ kho ở loan_out — chống trừ trùng/âm kho.)
    -- Outstanding cho mượn về 0 (mượn 5000 − trả 3000 − bán 2000) -> đóng khoản mượn.
    UPDATE material_loan SET status='closed' WHERE id=v_loan;
    -- Hoá đơn cho phần bán (VAT 8%: net 100 / thuế 8 / tổng 108) — chưa thu -> nằm trong công nợ phải thu.
    INSERT INTO sales_invoice(invoice_no, customer_id, due_date, tax_rate, status, created_by, note)
    VALUES ('INV-DEMO-02', v_cust_xyz, current_date, 8.0, 'issued', v_admin, 'HĐ bán glycerin (loan->sale)')
    RETURNING id INTO v_inv_xyz;
    INSERT INTO sales_invoice_line(invoice_id, shipment_line_id, item_id, qty, uom_id, unit_price)
    VALUES (v_inv_xyz, v_ship_line_loan, (SELECT id FROM item WHERE code='RM-GLYCERIN'), 2, v_kg, 50);
    RAISE NOTICE 'Bước 10: Bán 100 hộp FG-CREAM50 (doanh thu 2000, COGS 627) + loan->sale 2 kg glycerin cho NM-XYZ -> khoản mượn ĐÓNG (outstanding 0); phải thu: Z 1160, XYZ 108.';

    -- ===== BƯỚC 11: QUẢN LÝ VẬT CHỨA NÂNG CAO (đợt 6) — phuy -> chiết can -> cân/gộp/mở nắp/pallet/move/dùng =====
    -- Item RM-DRUM300 (base kg, KHÔNG QC -> nhập thẳng Bảo quản), NGOÀI BOM kem -> không đụng hồi quy 6.27/61.4.
    -- HU tường minh (truyền hu_id) -> trigger trg_fill_hu bỏ qua, cho phép NHIỀU HU/lô (chiết).
    v_bin_d_bq := (SELECT bq_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='RM-DRUM300'));
    v_bin_d_tt := (SELECT tt_bin FROM _bin WHERE item_id=(SELECT id FROM item WHERE code='RM-DRUM300'));

    -- 11a. NHẬP 1 phuy 300 kg -> lô + vật chứa DRUM + ledger nhập (hu = phuy).
    INSERT INTO lot(lot_no, item_id, qc_status, manufacture_date)
    VALUES ('L-DRUM-01', (SELECT id FROM item WHERE code='RM-DRUM300'), 'approved', current_date) RETURNING id INTO v_lot_drum;
    v_hu_drum := fn_new_hu('DRUM', (SELECT id FROM item WHERE code='RM-DRUM300'), v_lot_drum, v_bin_d_bq, 'HU-DRUM-01');
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id, hu_id)
    VALUES ('receipt', (SELECT id FROM item WHERE code='RM-DRUM300'), v_bin_d_bq, v_lot_drum, 300, 25, 'goods_receipt', NULL, v_hu_drum);

    -- 11b. CHIẾT (decant) phuy -> 3 can 100 kg (cùng bin/lô). repack: phuy(-300), can(+100)x3. Net=0 -> tồn lô không đổi.
    v_hu_can1 := fn_new_hu('CAN', (SELECT id FROM item WHERE code='RM-DRUM300'), v_lot_drum, v_bin_d_bq, 'HU-CAN-01');
    v_hu_can2 := fn_new_hu('CAN', (SELECT id FROM item WHERE code='RM-DRUM300'), v_lot_drum, v_bin_d_bq, 'HU-CAN-02');
    v_hu_can3 := fn_new_hu('CAN', (SELECT id FROM item WHERE code='RM-DRUM300'), v_lot_drum, v_bin_d_bq, 'HU-CAN-03');
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id, hu_id)
    SELECT 'repack', (SELECT id FROM item WHERE code='RM-DRUM300'), v_bin_d_bq, v_lot_drum, d.q, 'repack', v_hu_drum, d.h
    FROM (VALUES (-300::numeric, v_hu_drum), (100::numeric, v_hu_can1), (100::numeric, v_hu_can2), (100::numeric, v_hu_can3)) AS d(q, h);
    UPDATE handling_unit SET status='empty', current_bin_id=NULL WHERE id=v_hu_drum;   -- phuy RỖNG sau khi chiết

    -- 11c. CÂN TỪNG HU (catch-weight) can1: bì 2 kg, cả bì 102 kg -> net 100 kg (= lượng chứa).
    UPDATE handling_unit SET tare_weight=2, gross_weight=102 WHERE id=v_hu_can1;

    -- 11d. GỘP (merge) can2 -> can3 (cùng bin/lô). repack: can2(-100), can3(+100) -> can3=200, can2 rỗng/merged.
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id, hu_id)
    SELECT 'repack', (SELECT id FROM item WHERE code='RM-DRUM300'), v_bin_d_bq, v_lot_drum, d.q, 'repack', v_hu_can2, d.h
    FROM (VALUES (-100::numeric, v_hu_can2), (100::numeric, v_hu_can3)) AS d(q, h);
    UPDATE handling_unit SET status='merged', current_bin_id=NULL WHERE id=v_hu_can2;

    -- 11e. MỞ NẮP can1 -> opened_at = nay; hạn sau mở = nay + 30 ngày (item.shelf_life_after_open_days).
    UPDATE handling_unit SET opened_at = now() WHERE id=v_hu_can1;

    -- 11f. PALLET LỒNG: tạo 1 pallet, lồng can1 + can3 (parent_hu_id = pallet) -> v_hu_tree.
    v_hu_plt := fn_new_hu('PALLET', NULL, NULL, v_bin_d_bq, 'HU-PLT-01');
    UPDATE handling_unit SET parent_hu_id=v_hu_plt WHERE id IN (v_hu_can1, v_hu_can3);

    -- 11g. DI CHUYỂN pallet (kéo theo HU con) Bảo quản -> Tạm trữ. Mỗi can: transfer (-BQ, +TT) cùng hu.
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id, hu_id)
    SELECT 'transfer', (SELECT id FROM item WHERE code='RM-DRUM300'), b.bin, v_lot_drum, b.q, 'hu_move', v_hu_plt, b.h
    FROM (VALUES
        (v_bin_d_bq, -100::numeric, v_hu_can1), (v_bin_d_tt, 100::numeric, v_hu_can1),
        (v_bin_d_bq, -200::numeric, v_hu_can3), (v_bin_d_tt, 200::numeric, v_hu_can3)
    ) AS b(bin, q, h);
    UPDATE handling_unit SET current_bin_id=v_bin_d_tt WHERE id IN (v_hu_plt, v_hu_can1, v_hu_can3);

    -- 11h. DÙNG 1 phần: xuất 50 kg từ can3 (200 -> 150). movement 'issue' gắn hu=can3.
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, source_type, source_id, hu_id)
    VALUES ('issue', (SELECT id FROM item WHERE code='RM-DRUM300'), v_bin_d_tt, v_lot_drum, -50, 'manual_use', NULL, v_hu_can3);
    RAISE NOTICE 'Bước 11: HU — nhập phuy 300kg -> chiết 3 can -> cân can1(net 100) -> gộp can2 vào can3(200) -> mở nắp can1 -> pallet lồng can1+can3 -> move sang Tạm trữ -> dùng 50 từ can3. Tồn RM-DRUM300: can1 100 + can3 150 = 250.';

    RAISE NOTICE '== DEMO HOÀN TẤT: kế hoạch -> MRP -> mua/nhập/QC -> SX -> giá vốn -> cho mượn/nhận lại -> BÁN HÀNG -> VẬT CHỨA(HU). Xem ERP.md. ==';
END
$$;
