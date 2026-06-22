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
    v_mo_sf    bigint;
    v_mo_fg    bigint;
    v_mi       bigint;
    v_prf      bigint;
    v_lot_sf   bigint;
    v_lot_fg   bigint;
    v_n_mo     int;
    v_fg_cost  numeric;
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
    FROM item i JOIN (VALUES
        ('RM-WATER',     2,   40),   -- cần 35  -> mua 40
        ('RM-GLYCERIN',  40,  10),   -- cần 7.5 -> mua 10
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

    -- 5e. Ledger NHẬP (+) vào bin của dòng nhập (TT cho NVL, BQ cho bao bì).
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'receipt', grl.item_id, grl.to_bin_id, grl.lot_id, grl.received_qty, grl.unit_price, 'goods_receipt', grl.id
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
    SELECT 'transfer', grl.item_id, grl.to_bin_id, grl.lot_id, -grl.received_qty, grl.unit_price, 'qc_release', grl.id
    FROM goods_receipt_line grl JOIN item i ON i.id=grl.item_id
    WHERE grl.gr_id IN (v_gr_chem, v_gr_pack) AND i.requires_qc;
    INSERT INTO inventory_movement(movement_type, item_id, bin_id, lot_id, qty, unit_cost, source_type, source_id)
    SELECT 'qc_release', grl.item_id, bn.bq_bin, grl.lot_id, grl.received_qty, grl.unit_price, 'qc_release', grl.id
    FROM goods_receipt_line grl JOIN item i ON i.id=grl.item_id JOIN _bin bn ON bn.item_id=grl.item_id
    WHERE grl.gr_id IN (v_gr_chem, v_gr_pack) AND i.requires_qc;
    RAISE NOTICE 'Bước 5: Nhập kho 2 PO, QC đạt, nguyên liệu & bao bì đã vào bin Bảo quản (khả dụng).';

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
    SELECT 'production_issue', mil.component_item_id, mil.from_bin_id, mil.lot_id, -mil.qty, 'material_issue', mil.id
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
    SELECT 'production_issue', mil.component_item_id, mil.from_bin_id, mil.lot_id, -mil.qty, 'material_issue', mil.id
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

    RAISE NOTICE '== DEMO HOÀN TẤT: kế hoạch -> MRP -> mua/nhập/QC -> SX -> giá vốn. Xem ERP.md để khám phá. ==';
END
$$;
