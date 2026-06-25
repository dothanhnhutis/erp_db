# ERP Nhà máy Mỹ phẩm — Hướng dẫn & Dữ liệu mẫu

Tài liệu này giải thích **mô hình ERP** (schema ở [initdb/004_test.sql](initdb/004_test.sql)) một cách dễ
hiểu, kèm **dữ liệu seed** ([006_erp_seed.sql](initdb/006_erp_seed.sql) — danh mục,
[007_erp_demo.sql](initdb/007_erp_demo.sql) — một vòng sản xuất hoàn chỉnh) và **bộ truy vấn mẫu** để
bạn tự khám phá.

> Mô hình đi theo *item master*: mọi vật tư (nguyên liệu, bao bì, bán thành phẩm, thành phẩm) đều là
> một dòng trong bảng `item`. Quy trình quản lý theo **lô** (GMP/ISO 22716): mua → nhập → QC → tồn theo
> bin/lô → sản xuất → giá vốn.

---

## 1. Câu chuyện: Nhà máy "ABC"

Nhà máy ABC sản xuất **Kem dưỡng ẩm** và **Sữa rửa mặt**. Mỗi sản phẩm gồm 2 cấp:

```
Thành phẩm (FG)  =  Bulk (bán thành phẩm)  +  Bao bì
   Kem 50ml      =   50g Bulk Kem dưỡng    +  chai + nắp + nhãn + hộp
   Bulk Kem      =   nước + glycerin + dầu argan + lô hội + chất bảo quản
```

Dòng chảy công việc (ai làm gì):

```
Phòng Kế hoạch ──► Phòng Thu mua ──► Kho + QC ──► Phòng Sản xuất ──► Kế toán giá thành
  kế hoạch SX       PR → PO            nhập (GR)     xuất NVL          cuộn giá vốn
  + chạy MRP                           kiểm QC       làm bulk → TP     theo lô
```

---

## 2. Khởi động & cách xem dữ liệu

Sau khi init (Docker tự chạy `001`→`007`), vào psql:

```bash
docker exec -it postgres_container psql -U admin -d pgdb
```

Mọi truy vấn ở mục 7 dán thẳng vào đây. (Cài thủ công trên VPS: xem [DEPLOY.md](DEPLOY.md).)

---

## 3. Mô hình DANH MỤC (master — file 006)

```
          ┌────────────┐
          │    uom     │  đơn vị tính (dimension + ratio quy đổi) — xem §3b
          └─────┬──────┘
                │ base_uom (đơn vị lưu kho)
          ┌─────▼──────┐        ┌───────────────────────┐
          │    item    │◄───────┤ item_uom_conversion   │ quy đổi (1 thùng = 25 kg)
          │ (item_type)│        └───────────────────────┘
          └─────┬──────┘
                │ là thành phần / sản phẩm của
          ┌─────▼──────┐   1   ┌──────────────┐
          │    bom     ├──────►│   bom_line   │ định mức (qty, scrap%)
          │ (công thức)│   N   │ component →item (đa cấp)
          └────────────┘       └──────────────┘

  Kho 3 cấp:  location ──< warehouse_zone (zone_type) ──< storage_bin (bin_type)
              KHO-HCM        ZRM/ZPK/ZSOL/ZFG               TT/BQ/LB/TL
```

**`item_type`** quyết định khu lưu & yêu cầu QC: `RAW_MATERIAL`, `PACKAGING`, `SOLVENT`,
`SEMI_FINISHED` (bulk), `FINISHED_GOOD`.
**`bin_type`** (loại ô kệ): `TEMPORARY` (Tạm trữ – cách ly chờ QC), `PRESERVATION` (Bảo quản – đạt,
**khả dụng**), `DISPOSAL` (Loại bỏ), `RETURNS` (Hàng trả về).

Seed 006 tạo: **5 UOM, 3 nhà cung cấp, 17 item, 4 BOM (20 dòng), 1 kho → 4 khu → 16 bin.**

| Loại | Item |
|---|---|
| RAW_MATERIAL | RM-WATER, RM-GLYCERIN, RM-ARGAN, RM-ALOE, RM-PRESV, RM-SURFACT |
| SOLVENT | SOL-ETHANOL |
| PACKAGING | PK-BOTTLE50, PK-BOTTLE100, PK-CAP, PK-LABEL, PK-BOX, PK-CARTON |
| SEMI_FINISHED (bulk) | SF-CREAM, SF-WASH |
| FINISHED_GOOD | FG-CREAM50, FG-WASH100 |

Công thức (BOM) ví dụ — **Kem dưỡng 50ml** (đa cấp):

```
FG-CREAM50 (1 cái)
├── SF-CREAM 0.05 kg   ◄── bulk, có BOM riêng:
│       ├── RM-WATER     0.70 kg
│       ├── RM-GLYCERIN  0.15 kg
│       ├── RM-ARGAN     0.08 kg  (hao hụt scrap 5%)
│       ├── RM-ALOE      0.05 kg
│       └── RM-PRESV     0.02 kg
├── PK-BOTTLE50 1 cái
├── PK-CAP      1 cái
├── PK-LABEL    1 cái
└── PK-BOX      1 cái
```

---

## 3b. Đơn vị tính & quy đổi (đa đơn vị)

Mỗi item có **1 đơn vị gốc** (`item.base_uom_id`) để tính tồn/định mức/giá vốn. Nhưng **chứng từ có thể
nhập theo đơn vị khác** — hệ tự quy về base. Ví dụ Glycerin: base = **g**, mua bằng **kg**, nhận bằng **thùng**.

**Ba ca quy đổi** (đúng thứ tự ưu tiên của `fn_to_base`: trùng base → rule theo-item → toàn cục cùng dimension):

| Đơn vị nhập so với base | Cơ chế | Cần khai? | Ví dụ |
|---|---|---|---|
| **Cùng dimension, khác ratio** | `uom.ratio_to_anchor` (toàn cục) | Không — tự động | base g, nhập kg → ×1000 |
| **Khác dimension** | `item_uom_conversion` = tỷ trọng | **Có** | Cồn base kg, nhập lít: 20 lít = 15.7 kg → 1 lít = 0.785 kg |
| **Đóng gói PACK** (`ratio_to_anchor` NULL) | `item_uom_conversion` theo item | **Có** | 1 thùng glycerin = 20000 g; 1 thùng argan = 25 kg |

> `item_uom_conversion` không chỉ cho PACK — nó là cầu quy đổi **theo item cho bất kỳ cặp đơn vị nào**, kể cả
> **bắc cầu khác dimension** (VOLUME→MASS qua tỷ trọng). Cùng dimension (kg↔g) thì KHỎI khai — `ratio_to_anchor` lo.

Hàm `fn_to_base(item, qty, uom)` quy đổi (ưu tiên: trùng base → rule theo-item → toàn cục cùng dimension).
Mỗi dòng chứng từ giữ `(qty, uom_id)` **như nhập** + cột `*_base` do **trigger tự điền** = số lượng theo base.
**Mọi view/hàm tính toán dùng `*_base`** (tồn, MRP, giá vốn, tiến độ PO…), nên trộn đơn vị vẫn đúng.

```
Glycerin (base = g):
  PO đặt 20 kg  ──fn_to_base(global kg→g)──►  ordered_qty_base = 20000 g
  GR nhận 1 thùng ──fn_to_base(item PACK)──►  received_qty_base = 20000 g   (1 thùng = 20000 g)
  v_po_line_progress so khớp theo base: 20000 vs 20000 → đã nhận đủ.
  Giá vốn lô = tiền / số lượng_base = (1×800) / 20000 = 0.04 / g.
```

**Ca khác dimension** — Cồn Ethanol (base = **kg**), mua theo **lít** (tỷ trọng 15.7 kg / 20 lít → 0.785):

```
item_uom_conversion(SOL-ETHANOL, lít, 0.785)
  PO mua 200 lít  ─fn_to_base (khác dimension)─►  ordered_qty_base = 200 × 0.785 = 157 kg
  Nhận 200 lít (hoặc cân thẳng 157 kg)         →  khớp PO ở base (kg).
  lít↔kg KHÔNG tự quy đổi (khác dimension) → BẮT BUỘC khai dòng tỷ trọng, thiếu thì fn_to_base báo lỗi.
```

**Dropdown đơn vị cho UI:** view `v_item_valid_uom` liệt kê đơn vị **hợp lệ** mỗi item theo chính sách **HẸP**
(allow-list): `base_uom` + đơn vị khai ở `item_uom_conversion`. Vd cồn → {kg, lít}; glycerin → {g, kg, thùng};
FG-CREAM50 → {cái}. Muốn cho phép thêm đơn vị nào (kể cả cùng dimension) thì khai vào `item_uom_conversion`.

> Giá `unit_price` theo **đơn vị của dòng** (mua kg → giá/kg; nhận thùng → giá/thùng); `line_amount = qty × unit_price`
> (đúng theo mọi đơn vị). Đổi base của item KHÔNG làm sai giá vốn thành phẩm (vẫn 6.27/cái) vì mọi phép tính ở base.

---

## 4. Chuỗi CHỨNG TỪ (giao dịch — file 007)

```
[KẾ HOẠCH]            [THU MUA]                 [KHO + QC]
production_plan       purchase_requisition(PR)  goods_receipt(GR)
   │                       ▲   │                     │
   │ fn_run_mrp            │   ▼                     ▼
   ▼                  (item mua) purchase_order   lot ──► qc_inspection
mrp_run ─ mrp_requirement ──────────►(PO)──────────►│  (đạt → approved)
   │                                                 │
   │ fn_generate_production_orders                   ▼
   ▼                                          inventory_movement  ◄── SỔ CÁI TỒN (bất biến)
production_order ── production_order_material        ▲  (+ nhập / − xuất theo bin,lô)
   │   (định mức NVL)                                │
   ├── material_issue ───────(xuất NVL)──────────────┤
   └── production_receipt ───(nhập TP, lô mới)────────┘
   │ fn_roll_lot_cost
   ▼
lot.unit_cost  ──►  v_inventory_valuation (định giá tồn) , v_mo_cost (giá vốn lệnh)
```

**Nguyên tắc cốt lõi:** tồn kho KHÔNG lưu 1 con số — mà cộng dồn từ **sổ cái** `inventory_movement`
(mỗi nghiệp vụ +/− theo (bin, item, lô)). Tồn **khả dụng** = ở bin `PRESERVATION` **và** lô đã QC `approved`.

3 hàm tự động hoá:
- `fn_run_mrp(plan, run_no, by)` — nổ BOM đa cấp, trừ tồn ở **mọi cấp**, ra nhu cầu cần mua/sản xuất.
- `fn_generate_production_orders(run, prefix, by)` — tự tạo lệnh SX cho item cần làm + định mức NVL.
- `fn_roll_lot_cost()` — cuộn giá vốn thực theo lô: NVL (giá mua) → bulk → thành phẩm.

---

## 5. Kịch bản DEMO (007): sản xuất 1000 hộp Kem dưỡng 50ml

| Bước | Việc | Kết quả |
|---|---|---|
| 1 | Kế hoạch `MP-DEMO-01` | 1000 cái FG-CREAM50 |
| 2 | `fn_run_mrp` → nhu cầu | bulk SF-CREAM **50 kg**; WATER 35, GLYCERIN 7.5, **ARGAN 4.2** (=50×0.08×**1.05** scrap), ALOE 2.5, PRESV 1.0; bao bì 1000 mỗi loại |
| 3 | Sinh PR `PR-DEMO-01` | 9 dòng item đi mua (NVL + bao bì) |
| 4 | `fn_generate_production_orders` | **2 lệnh SX**: bulk SF-CREAM + thành phẩm FG-CREAM50 |
| 5 | Mua & nhập: PO (2 NCC) → GR → QC | NVL/bao bì vào bin **Bảo quản** (mua dư an toàn: WATER 40, ARGAN 5, bao bì 1100…) |
| 6 | SX bulk: xuất NVL → nhập lô `L-SF-CREAM-01` 50 kg → QC | bulk **khả dụng** |
| 7 | Đóng gói: xuất bulk + bao bì → lô `L-FG-CREAM50-01` 1000 cái → QC | thành phẩm **khả dụng** |
| 8 | `fn_roll_lot_cost` | bulk **61.4/kg**, FG-CREAM50 **6.27/cái** |

Giá vốn 1 hộp Kem 50ml = **6.27** được cuộn từ:

```
Bulk 1kg = 35·2(nước) + 7.5·40(glycerin) + 4.2·500(argan) + 2.5·120(lô hội) + 1.0·300(bảo quản)
         = 3070 / 50kg sản ra = 61.4/kg
1 hộp    = 0.05kg bulk·61.4 + chai 1.5 + nắp 0.5 + nhãn 0.2 + hộp 1.0
         = 3.07 + 3.20 = 6.27/cái   (tổng lô 1000 cái = 6270)
```

---

## 6. Bản đồ VIEW (xem gì ở đâu)

| Câu hỏi | View |
|---|---|
| Tồn theo bin/lô | `v_stock_on_hand` |
| Tồn **khả dụng** (Bảo quản + QC đạt) | `v_available_stock` |
| Tiến độ nhận hàng theo dòng PO | `v_po_line_progress` |
| Lệch cân nhận vs phiếu | `v_receipt_variance` |
| Nhu cầu MRP đã chốt | `mrp_requirement`; nhanh: `v_mrp_netting` |
| Lệnh SX cần bao nhiêu NVL, đã xuất chưa | `v_mo_material_status` |
| Lệnh SX làm xong chưa | `v_mo_completion` |
| Truy xuất XUÔI lô NVL → lô TP (thu hồi) | `v_lot_genealogy_forward` |
| Truy xuất NGƯỢC lô TP → NVL → PO → NCC | `v_lot_genealogy_backward`, `v_lot_traceability` |
| Bao nhiêu kg lô cha trong lô con | `v_lot_genealogy_alloc` |
| Giá vốn từng lệnh / định giá tồn | `v_mo_cost`, `v_inventory_valuation` |
| Đơn vị hợp lệ để nhập cho 1 item (UI dropdown) | `v_item_valid_uom` |

---

## 7. Truy vấn mẫu (dán vào psql)

### 7.1 Danh mục item theo loại
```sql
SELECT item_type, string_agg(code, ', ' ORDER BY code) FROM item GROUP BY item_type;
```

### 7.2 Nổ cây BOM của Kem 50ml (đệ quy đa cấp)
```sql
WITH RECURSIVE tree AS (
  SELECT b.id bom_id, bl.component_item_id, bl.qty, 1 lvl
  FROM bom b JOIN bom_line bl ON bl.bom_id=b.id
  WHERE b.item_id=(SELECT id FROM item WHERE code='FG-CREAM50') AND b.status='active'
  UNION ALL
  SELECT b2.id, bl2.component_item_id, t.qty*bl2.qty, t.lvl+1
  FROM tree t JOIN bom b2 ON b2.item_id=t.component_item_id AND b2.status='active'
              JOIN bom_line bl2 ON bl2.bom_id=b2.id)
SELECT repeat('  ', lvl-1)||i.code AS item, t.qty, i.item_type
FROM tree t JOIN item i ON i.id=t.component_item_id ORDER BY lvl, item;
```
→ Thấy FG → SF-CREAM + bao bì, rồi SF-CREAM → 5 nguyên liệu.

### 7.3 Tồn KHẢ DỤNG hiện có
```sql
SELECT i.code, SUM(av.qty_available) qty
FROM v_available_stock av JOIN item i ON i.id=av.item_id GROUP BY i.code ORDER BY i.code;
```
→ FG-CREAM50 **1000**; NVL/bao bì dư sau SX (WATER 5, ARGAN 0.8, bao bì 100…).

### 7.4 Định giá tồn kho (số lượng × giá vốn lô)
```sql
SELECT i.code, SUM(v.qty_on_hand) qty, MAX(v.unit_cost) gia_von, SUM(v.stock_value) gia_tri
FROM v_inventory_valuation v JOIN item i ON i.id=v.item_id
GROUP BY i.code ORDER BY gia_tri DESC NULLS LAST;
```
→ FG-CREAM50 = 1000 × 6.27 = **6270**; Glycerin tồn 12500 **g** × 0.04 = **500**; tổng giá trị kho ≈ **7860**.

### 7.5 Kết quả MRP (nhu cầu mọi cấp)
```sql
SELECT i.code, mr.gross_qty, mr.net_qty,
       (mr.production_order_id IS NOT NULL) "tạo_MO", (mr.pr_line_id IS NOT NULL) "tạo_PR"
FROM mrp_requirement mr JOIN item i ON i.id=mr.item_id
WHERE mr.mrp_run_id=1 ORDER BY mr.net_qty DESC;
```
→ Item có BOM (FG/SF) → tạo MO; item đi mua (NVL/bao bì) → tạo PR.

### 7.6 Lệnh SX tự tạo & định mức NVL
```sql
SELECT mo.mo_no, i.code sp, s.required_qty "cần", s.issued_qty "đã_xuất", s.open_qty "còn"
FROM v_mo_material_status s
JOIN production_order mo ON mo.id=s.mo_id
JOIN item i ON i.id=mo.item_id
ORDER BY mo.mo_no;
```
→ Định mức đã xuất đủ (`còn`=0) sau khi sản xuất.

### 7.7 Tiến độ nhận hàng theo PO (so khớp theo BASE — xem PO-CHEM-GLY: đặt kg, nhận thùng)
```sql
SELECT po.po_no, i.code, u.code AS don_vi_dat, p.ordered_qty,
       p.ordered_qty_base, p.received_qty_base, p.open_qty
FROM v_po_line_progress p
JOIN purchase_order po ON po.id=p.po_id
JOIN item i ON i.id=p.item_id
JOIN uom u  ON u.id=p.uom_id
ORDER BY po.po_no, i.code;
```
→ Glycerin (`PO-CHEM-GLY`): đặt **20 kg** → `ordered_qty_base` 20000 g; nhận **1 thùng** → `received_qty_base` 20000 g; open 0.

### 7.8 Giá vốn theo lô & theo lệnh
```sql
SELECT l.lot_no, i.code, l.unit_cost FROM lot l JOIN item i ON i.id=l.item_id
WHERE l.unit_cost IS NOT NULL ORDER BY l.unit_cost DESC;

SELECT mo_no, input_cost "chi_phí_NVL", out_qty "sản_lượng", unit_cost "đơn_giá"
FROM v_mo_cost WHERE input_cost IS NOT NULL;
```
→ ARGAN 500, …, **SF-CREAM 61.4**, **FG-CREAM50 6.27**.

### 7.9 Truy xuất XUÔI — thu hồi (recall): 1 lô NVL đi vào những lô TP nào
```sql
SELECT pl.lot_no "lô_NVL", dl.lot_no "lô_hậu_duệ", f.lvl
FROM v_lot_genealogy_forward f
JOIN lot pl ON pl.id=f.root_lot_id JOIN lot dl ON dl.id=f.descendant_lot_id
WHERE pl.lot_no='L-RM-ARGAN' ORDER BY f.lvl;
```
→ `L-RM-ARGAN` → `L-SF-CREAM-01` (cấp 1) → `L-FG-CREAM50-01` (cấp 2). *Nếu Argan lỗi, biết ngay lô TP nào dính.*

### 7.10 Truy xuất NGƯỢC — 1 lô thành phẩm gồm những gì, mua từ đâu
```sql
-- nguồn lô (đệ quy)
SELECT al.lot_no "lô_nguồn", b.lvl FROM v_lot_genealogy_backward b
JOIN lot cl ON cl.id=b.root_lot_id JOIN lot al ON al.id=b.ancestor_lot_id
WHERE cl.lot_no='L-FG-CREAM50-01' ORDER BY b.lvl;
-- lần tới tận PO/NCC
SELECT lot_no, po_no, pr_no, supplier_code, supplier_name
FROM v_lot_traceability WHERE lot_no='L-RM-ARGAN';
```
→ FG ← 5 đầu vào (bulk + bao bì) ← 5 NVL; lô Argan ← `PO-CHEM-01` ← `PR-DEMO-01` ← NCC `SUP-CHEM`.

### 7.11 Phân bổ ĐỊNH LƯỢNG (bao nhiêu kg lô cha trong lô con)
```sql
SELECT pl.lot_no cha, cl.lot_no con, a.consumed_qty "tiêu_hao", a.output_ratio "tỷ_lệ", a.alloc_qty "phân_bổ"
FROM v_lot_genealogy_alloc a JOIN lot pl ON pl.id=a.parent_lot_id JOIN lot cl ON cl.id=a.child_lot_id
WHERE pl.lot_no='L-RM-ARGAN';
```

### 7.12 Tồn chi tiết theo vị trí (bin) & lô
```sql
SELECT i.code, sb.code bin, z.name khu, l.lot_no, s.qty_on_hand
FROM v_stock_on_hand s
JOIN item i ON i.id=s.item_id
JOIN storage_bin sb ON sb.id=s.bin_id JOIN warehouse_zone z ON z.id=sb.zone_id
LEFT JOIN lot l ON l.id=s.lot_id
ORDER BY i.code;
```

---

## 8. Ghi chú

- **Chạy lại từ đầu:** `docker compose -f docker-compose.dev.yaml down -v && docker compose -f docker-compose.dev.yaml up --build -d`
  (xoá volume → init lại `001`→`007`). Seed chạy **1 lần** khi init, không idempotent.
- **Production:** `006` (danh mục) nên giữ; `007` chỉ là **dữ liệu demo**, có thể bỏ qua. Cài thủ công: [DEPLOY.md](DEPLOY.md).
- **Sao lưu/khôi phục:** [BACKUP.md](BACKUP.md). Lưu ý restore phải vào DB rỗng (trigger audit).
- Số liệu trong tài liệu này khớp với DB sau khi chạy `007` (đã kiểm thử trên PostgreSQL 18).
