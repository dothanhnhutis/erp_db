-- =============================================================================
-- 006 — SEED DANH MỤC ERP (MÔ HÌNH) — Nhà máy mỹ phẩm "ABC"
-- =============================================================================
-- Đây là phần DỮ LIỆU NỀN (master data) cho ERP ở 004_test.sql: đơn vị tính,
-- nhà cung cấp, item (NVL/bao bì/dung môi/bán thành phẩm/thành phẩm), quy đổi
-- đơn vị, kho 3 cấp (location -> zone -> bin) và công thức BOM đa cấp.
--
-- Cách viết: INSERT KHAI BÁO + tra cứu khoá tự nhiên bằng subquery theo `code`
--   (vd: base_uom_id = (SELECT id FROM uom WHERE code='kg')). Nhờ vậy mỗi dòng
--   tự giải thích, không phụ thuộc id sinh tự động, dễ đọc/sửa.
-- Chạy 1 LẦN khi init (sau 005). Giao dịch mẫu (mua/SX/giá vốn) nằm ở 007.
-- Xem giải thích đầy đủ + sơ đồ + truy vấn mẫu: ERP.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. ĐƠN VỊ TÍNH (UOM) — kg là đơn vị GỐC tính tồn/định mức (is_base_weight)
-- -----------------------------------------------------------------------------
-- dimension + ratio_to_anchor: đơn vị cùng dimension quy đổi TOÀN CỤC (kg=1000g, lit=1000ml).
-- thung = PACK (đóng gói theo-item) -> ratio NULL, khai hệ số ở item_uom_conversion bên dưới.
INSERT INTO uom (code, name, dimension, ratio_to_anchor) VALUES
    ('kg',    'Kilogram',  'MASS',   1000),   -- 1 kg = 1000 (mốc g)
    ('g',     'Gram',      'MASS',   1),
    ('lit',   'Lít',       'VOLUME', 1000),   -- 1 lít = 1000 (mốc ml)
    ('cai',   'Cái/Chiếc', 'COUNT',  1),      -- đơn vị cho bao bì & thành phẩm
    ('thung', 'Thùng',     'PACK',   NULL);   -- đóng gói: hệ số tuỳ item

-- -----------------------------------------------------------------------------
-- 2. NHÀ CUNG CẤP
-- -----------------------------------------------------------------------------
INSERT INTO supplier (code, name, tax_code, payment_terms, prepay_required, phone) VALUES
    ('SUP-CHEM', 'Cty Hoá Mỹ Phẩm Á Châu',    '0301111111', 'Công nợ 30 ngày',     false, '028-3811-1111'),
    ('SUP-PACK', 'Cty Bao Bì Sài Gòn',         '0302222222', 'Công nợ 15 ngày',     false, '028-3822-2222'),
    ('SUP-FRAG', 'Cty Hương Liệu Quốc Tế',     '0303333333', 'Trả trước 50%',        true,  '028-3833-3333');

-- -----------------------------------------------------------------------------
-- 3. ITEM MASTER — 17 item, 5 loại (item_type quyết định khu lưu & yêu cầu QC)
--    base_uom_id = đơn vị CHÍNH để lưu kho. requires_qc = bắt buộc IQC khi nhập.
-- -----------------------------------------------------------------------------
-- 3a. Nguyên liệu (RAW_MATERIAL) — lưu kg, bắt buộc QC
INSERT INTO item (code, name, item_type, base_uom_id, requires_qc, shelf_life_days) VALUES
    ('RM-WATER',    'Nước tinh khiết',              'RAW_MATERIAL', (SELECT id FROM uom WHERE code='kg'), true,  365),
    ('RM-GLYCERIN', 'Glycerin',                     'RAW_MATERIAL', (SELECT id FROM uom WHERE code='g'),  true,  730), -- base = GRAM (minh hoạ đa đơn vị)
    ('RM-ARGAN',    'Dầu Argan',                    'RAW_MATERIAL', (SELECT id FROM uom WHERE code='kg'), true,  540),
    ('RM-ALOE',     'Chiết xuất Lô hội',            'RAW_MATERIAL', (SELECT id FROM uom WHERE code='kg'), true,  365),
    ('RM-PRESV',    'Chất bảo quản Phenoxyethanol', 'RAW_MATERIAL', (SELECT id FROM uom WHERE code='kg'), true,  1095),
    ('RM-SURFACT',  'Chất tạo bọt SLES',            'RAW_MATERIAL', (SELECT id FROM uom WHERE code='kg'), true,  730);

-- 3b. Dung môi (SOLVENT)
INSERT INTO item (code, name, item_type, base_uom_id, requires_qc, shelf_life_days) VALUES
    ('SOL-ETHANOL', 'Cồn Ethanol',                  'SOLVENT',      (SELECT id FROM uom WHERE code='kg'), true,  1095);

-- 3c. Bao bì (PACKAGING) — lưu cái, KHÔNG cần QC
INSERT INTO item (code, name, item_type, base_uom_id, requires_qc) VALUES
    ('PK-BOTTLE50',  'Chai 50ml',   'PACKAGING', (SELECT id FROM uom WHERE code='cai'), false),
    ('PK-BOTTLE100', 'Chai 100ml',  'PACKAGING', (SELECT id FROM uom WHERE code='cai'), false),
    ('PK-CAP',       'Nắp chai',    'PACKAGING', (SELECT id FROM uom WHERE code='cai'), false),
    ('PK-LABEL',     'Nhãn dán',    'PACKAGING', (SELECT id FROM uom WHERE code='cai'), false),
    ('PK-BOX',       'Hộp giấy',    'PACKAGING', (SELECT id FROM uom WHERE code='cai'), false),
    ('PK-CARTON',    'Thùng carton','PACKAGING', (SELECT id FROM uom WHERE code='cai'), false);

-- 3d. Bán thành phẩm / Bulk (SEMI_FINISHED) — lưu kg, QC trước khi đóng gói
INSERT INTO item (code, name, item_type, base_uom_id, requires_qc, shelf_life_days) VALUES
    ('SF-CREAM', 'Bulk Kem dưỡng ẩm',   'SEMI_FINISHED', (SELECT id FROM uom WHERE code='kg'), true, 180),
    ('SF-WASH',  'Bulk Sữa rửa mặt',    'SEMI_FINISHED', (SELECT id FROM uom WHERE code='kg'), true, 180);

-- 3e. Thành phẩm (FINISHED_GOOD) — lưu cái, QC xuất xưởng
INSERT INTO item (code, name, item_type, base_uom_id, requires_qc, shelf_life_days) VALUES
    ('FG-CREAM50',  'Kem dưỡng ẩm 50ml', 'FINISHED_GOOD', (SELECT id FROM uom WHERE code='cai'), true, 730),
    ('FG-WASH100',  'Sữa rửa mặt 100ml', 'FINISHED_GOOD', (SELECT id FROM uom WHERE code='cai'), true, 730);

-- -----------------------------------------------------------------------------
-- 4. QUY ĐỔI ĐƠN VỊ THEO ITEM — 1 uom = factor_to_base × base_uom. Dùng cho 3 nhu cầu:
--    (a) đơn vị PACK đóng gói: Argan (base kg) 1 thùng = 25 kg; Glycerin (base g) 1 thùng = 20000 g;
--        Chai 50ml (base cái) 1 thùng = 100 cái.
--    (b) BẮC CẦU KHÁC DIMENSION qua tỷ trọng: Cồn (base kg) 1 lít = 0.785 kg (= 15.7 kg / 20 lít) —
--        lít↔kg KHÔNG quy đổi toàn cục được (khác dimension) nên BẮT BUỘC khai ở đây.
--    (c) khai TƯỜNG MINH đơn vị cùng dimension cho allow-list v_item_valid_uom: Glycerin (base g)
--        1 kg = 1000 g — để dropdown hiện 'kg' (dù kg↔g vốn tự quy đổi toàn cục qua ratio_to_anchor).
-- -----------------------------------------------------------------------------
INSERT INTO item_uom_conversion (item_id, uom_id, factor_to_base) VALUES
    ((SELECT id FROM item WHERE code='RM-ARGAN'),    (SELECT id FROM uom WHERE code='thung'), 25),
    ((SELECT id FROM item WHERE code='RM-GLYCERIN'), (SELECT id FROM uom WHERE code='thung'), 20000),  -- (a) base g, PACK
    ((SELECT id FROM item WHERE code='PK-BOTTLE50'), (SELECT id FROM uom WHERE code='thung'), 100),
    ((SELECT id FROM item WHERE code='SOL-ETHANOL'), (SELECT id FROM uom WHERE code='lit'),   0.785), -- (b) base kg, mua theo lít (tỷ trọng)
    ((SELECT id FROM item WHERE code='RM-GLYCERIN'), (SELECT id FROM uom WHERE code='kg'),    1000);  -- (c) base g, hiện kg trong allow-list

-- -----------------------------------------------------------------------------
-- 5. KHO 3 CẤP: location -> warehouse_zone -> storage_bin
--    1 kho tổng, 4 khu (NVL/Bao bì/Dung môi/Thành phẩm), mỗi khu 4 bin chuẩn:
--    Tạm trữ (cách ly chờ QC) / Bảo quản (đạt, khả dụng) / Loại bỏ / Hàng trả về
-- -----------------------------------------------------------------------------
INSERT INTO location (code, name, address) VALUES
    ('KHO-HCM', 'Kho Tổng TP.HCM', 'KCN Tân Bình, TP.HCM');

INSERT INTO warehouse_zone (location_id, code, name, zone_type) VALUES
    ((SELECT id FROM location WHERE code='KHO-HCM'), 'ZRM',  'Khu Nguyên liệu', 'RAW_MATERIAL'),
    ((SELECT id FROM location WHERE code='KHO-HCM'), 'ZPK',  'Khu Bao bì',      'PACKAGING'),
    ((SELECT id FROM location WHERE code='KHO-HCM'), 'ZSOL', 'Khu Dung môi',    'SOLVENT'),
    ((SELECT id FROM location WHERE code='KHO-HCM'), 'ZFG',  'Khu Thành phẩm',  'FINISHED_GOODS');

-- 16 bin = 4 khu × 4 loại bin (cùng bộ mã TT/BQ/LB/TL cho mỗi khu)
INSERT INTO storage_bin (zone_id, code, name, bin_type)
SELECT z.id, b.code, b.name, b.bin_type::bin_type
FROM warehouse_zone z
CROSS JOIN (VALUES
    ('TT', 'Tạm trữ (cách ly)', 'TEMPORARY'),
    ('BQ', 'Bảo quản',          'PRESERVATION'),
    ('LB', 'Loại bỏ',           'DISPOSAL'),
    ('TL', 'Hàng trả về',       'RETURNS')
) AS b(code, name, bin_type)
WHERE z.location_id = (SELECT id FROM location WHERE code='KHO-HCM');

-- -----------------------------------------------------------------------------
-- 6. CÔNG THỨC BOM (đa cấp) — output_qty là 1 mẻ cho ra (theo base uom của item)
--    Cấp 1: FG (thành phẩm)  ->  SF (bulk) + bao bì
--    Cấp 2: SF (bulk)        ->  nguyên liệu
--    uq_bom_active: mỗi item tối đa 1 BOM status='active'.
-- -----------------------------------------------------------------------------
-- 6a. Header BOM (đều active, created_by = admin đã seed ở 005)
INSERT INTO bom (item_id, version, output_qty, output_uom_id, status, created_by) VALUES
    ((SELECT id FROM item WHERE code='SF-CREAM'),   'v1', 1, (SELECT id FROM uom WHERE code='kg'),  'active', (SELECT id FROM users LIMIT 1)),
    ((SELECT id FROM item WHERE code='SF-WASH'),    'v1', 1, (SELECT id FROM uom WHERE code='kg'),  'active', (SELECT id FROM users LIMIT 1)),
    ((SELECT id FROM item WHERE code='FG-CREAM50'), 'v1', 1, (SELECT id FROM uom WHERE code='cai'), 'active', (SELECT id FROM users LIMIT 1)),
    ((SELECT id FROM item WHERE code='FG-WASH100'), 'v1', 1, (SELECT id FROM uom WHERE code='cai'), 'active', (SELECT id FROM users LIMIT 1));

-- Helper: BOM active của 1 item = (SELECT id FROM bom WHERE item_id=... AND status='active')

-- 6b. Bulk Kem dưỡng ẩm (1 kg) — Argan có 5% hao hụt (scrap) để minh hoạ
INSERT INTO bom_line (bom_id, component_item_id, qty, uom_id, scrap_pct) VALUES
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM') AND status='active'), (SELECT id FROM item WHERE code='RM-WATER'),    0.70, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM') AND status='active'), (SELECT id FROM item WHERE code='RM-GLYCERIN'), 0.15, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM') AND status='active'), (SELECT id FROM item WHERE code='RM-ARGAN'),    0.08, (SELECT id FROM uom WHERE code='kg'), 5),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM') AND status='active'), (SELECT id FROM item WHERE code='RM-ALOE'),     0.05, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-CREAM') AND status='active'), (SELECT id FROM item WHERE code='RM-PRESV'),    0.02, (SELECT id FROM uom WHERE code='kg'), 0);

-- 6c. Bulk Sữa rửa mặt (1 kg)
INSERT INTO bom_line (bom_id, component_item_id, qty, uom_id, scrap_pct) VALUES
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-WASH') AND status='active'), (SELECT id FROM item WHERE code='RM-WATER'),    0.60, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-WASH') AND status='active'), (SELECT id FROM item WHERE code='RM-SURFACT'),  0.25, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-WASH') AND status='active'), (SELECT id FROM item WHERE code='RM-GLYCERIN'), 0.10, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-WASH') AND status='active'), (SELECT id FROM item WHERE code='RM-PRESV'),    0.01, (SELECT id FROM uom WHERE code='kg'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='SF-WASH') AND status='active'), (SELECT id FROM item WHERE code='SOL-ETHANOL'), 0.04, (SELECT id FROM uom WHERE code='kg'), 0);

-- 6d. Kem dưỡng ẩm 50ml (1 cái) — 50g bulk + bộ bao bì
INSERT INTO bom_line (bom_id, component_item_id, qty, uom_id, scrap_pct) VALUES
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50') AND status='active'), (SELECT id FROM item WHERE code='SF-CREAM'),    0.05, (SELECT id FROM uom WHERE code='kg'),  0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50') AND status='active'), (SELECT id FROM item WHERE code='PK-BOTTLE50'), 1,    (SELECT id FROM uom WHERE code='cai'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50') AND status='active'), (SELECT id FROM item WHERE code='PK-CAP'),      1,    (SELECT id FROM uom WHERE code='cai'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50') AND status='active'), (SELECT id FROM item WHERE code='PK-LABEL'),    1,    (SELECT id FROM uom WHERE code='cai'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-CREAM50') AND status='active'), (SELECT id FROM item WHERE code='PK-BOX'),      1,    (SELECT id FROM uom WHERE code='cai'), 0);

-- 6e. Sữa rửa mặt 100ml (1 cái) — 100g bulk + bộ bao bì
INSERT INTO bom_line (bom_id, component_item_id, qty, uom_id, scrap_pct) VALUES
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-WASH100') AND status='active'), (SELECT id FROM item WHERE code='SF-WASH'),     0.10, (SELECT id FROM uom WHERE code='kg'),  0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-WASH100') AND status='active'), (SELECT id FROM item WHERE code='PK-BOTTLE100'),1,    (SELECT id FROM uom WHERE code='cai'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-WASH100') AND status='active'), (SELECT id FROM item WHERE code='PK-CAP'),      1,    (SELECT id FROM uom WHERE code='cai'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-WASH100') AND status='active'), (SELECT id FROM item WHERE code='PK-LABEL'),    1,    (SELECT id FROM uom WHERE code='cai'), 0),
    ((SELECT id FROM bom WHERE item_id=(SELECT id FROM item WHERE code='FG-WASH100') AND status='active'), (SELECT id FROM item WHERE code='PK-BOX'),      1,    (SELECT id FROM uom WHERE code='cai'), 0);

-- =============================================================================
-- Hết 006. Sau bước này DB đã có "mô hình" (danh mục + BOM). Luồng giao dịch
-- mẫu (mua → sản xuất → giá vốn) chạy ở 007_erp_demo.sql.
-- =============================================================================
