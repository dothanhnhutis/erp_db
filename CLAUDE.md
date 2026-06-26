# CLAUDE.md — Ngữ cảnh dự án (đọc trước khi làm)

> File này tự nạp khi mở repo bằng Claude Code. Mục tiêu: nắm trọn dự án + quy ước để làm tiếp ngay.
> Giao tiếp với user bằng **tiếng Việt**.

## 1. Tổng quan
Đây là **database PostgreSQL 18 thuần** (SQL + Docker, **không có app code**) gồm 2 phần chạy CHUNG 1 DB:
- **Core RBAC**: tài khoản – role – permission – phiên đăng nhập (`initdb/001`,`002`,`003` + seed `005`).
- **Module ERP** nhà máy mỹ phẩm "ABC" (kem dưỡng + sữa rửa mặt): mua → nhập → QC → tồn theo bin/lô → sản
  xuất → giá vốn lô. Quản lý theo **lô** (GMP/ISO 22716). Toàn bộ ở `initdb/004` + seed `006`/demo `007`.

Tài liệu sâu: [ERP.md](ERP.md) (hướng dẫn + sơ đồ + 12 truy vấn mẫu), [DEPLOY.md](DEPLOY.md) (cài thủ
công/VPS), [BACKUP.md](BACKUP.md) (sao lưu/khôi phục).

## 2. Chạy & xem dữ liệu
```bash
# Khởi động (Docker tự init initdb/001 -> 007 theo thứ tự)
docker compose -f docker-compose.dev.yaml up --build -d
# Vào psql
docker exec -it postgres_container psql -U admin -d pgdb        # mật khẩu DB: secret, DB: pgdb
# Reset sạch (xoá volume -> init lại từ đầu)
docker compose -f docker-compose.dev.yaml down -v && docker compose -f docker-compose.dev.yaml up --build -d
```
`docker-compose.dev.yaml` mount `./initdb:/docker-entrypoint-initdb.d` và `./data:/tmp`, bind `127.0.0.1:5432`.

## 3. Bố cục `initdb/` (chạy theo thứ tự, mỗi file 1 transaction, `ON_ERROR_STOP=1`)
| File | Nội dung |
|---|---|
| `001_init.sql` | Schema Core RBAC: users/roles/permissions/sessions. PK **uuidv7**, CHECK enum, bảng partition. |
| `002_trigger.sql` | `set_updated_at()` + audit chung. `fn_generic_audit_log` **che secret theo tên cột** (password_hash/token_hash/... → `***REDACTED***`). `user_sessions` loại khỏi audit. |
| `003_partition.sql` | pg_partman cho `audit_logs` (partition theo THÁNG, retention 1 năm). |
| **`004_test.sql`** | **MODULE ERP — MỌI schema ERP nằm ở ĐÂY** (item, UOM, WMS, BOM, MRP, sản xuất, giá vốn lô, genealogy, view). File lớn nhất. |
| `005_seed.sql` | Seed Core RBAC, `\copy` từ `data/*.csv` (mount tại `/tmp`). |
| `006_erp_seed.sql` | Seed DANH MỤC ERP: uom, supplier, 17 item, BOM, kho 3 cấp. |
| `007_erp_demo.sql` | LUỒNG demo end-to-end 1 vòng sản xuất (RAISE NOTICE kể bước). Tuỳ chọn cho prod. |

## 4. QUY ƯỚC & RÀNG BUỘC BẮT BUỘC
- **Sửa IN-PLACE, KHÔNG viết ALTER migration**: dự án init-from-scratch, chưa production. Core sửa
  `001`/`002`; **ERP sửa `004`**; seed ERP ở `006`; demo ở `007`. Đổi schema = sửa thẳng file rồi re-init.
- **Verify mọi thay đổi bằng re-init đầy đủ** (`down -v && up --build -d`) rồi soi log:
  - Lỗi thật = dòng có `ERROR:` / `FATAL:`.
  - **Bỏ qua các cảnh báo vô hại**: `database "pgdb" does not exist` (race pg_partman BGW lúc khởi động) và
    `NOTICE: ... does not exist, skipping` (DROP TRIGGER IF EXISTS trong DO-block re-attach).
- **Quy ước Module ERP** (khác Core có chủ đích — chấp nhận khác nhau giữa 2 module):
  - PK = `bigint GENERATED ALWAYS AS IDENTITY`; các cột "ai làm" (`*_by`) = **uuid FK → users(id)**.
  - Dùng **native ENUM** (pr_status, item_type, movement_type, qc_status, uom_dimension...). Core dùng CHECK.
  - Tiền/khối lượng = `numeric`. Catch-weight: `declared_qty` vs `received_qty`.
  - KHÔNG định nghĩa lại `set_updated_at()` (tái dùng của 002). Cuối `004` có DO-block re-attach updated_at +
    audit cho bảng ERP, **loại `inventory_movement`** (sổ cái bất biến).
- **Sổ cái `inventory_movement` post bằng APP** (không auto-post trigger — đồng nhất toàn module). Tồn kho =
  Σ ledger theo (bin, item, lô). Tồn **khả dụng** = bin `PRESERVATION` + lô QC `approved`.
- **Đa đơn vị (multi-UOM)**: mỗi dòng chứng từ giữ `(qty, uom_id)` **như nhập** + cột `*_base` do trigger
  `fn_to_base` tự điền; **MỌI view/hàm tính ở base**. 3 ca quy đổi: (1) cùng dimension → `uom.ratio_to_anchor`
  (tự động); (2) khác dimension → `item_uom_conversion` (tỷ trọng, vd cồn lít→kg); (3) PACK → `item_uom_conversion`
  theo item. Dropdown đơn vị hợp lệ/item: view `v_item_valid_uom` (chính sách HẸP = base + item_uom_conversion).
- **Bẫy SQL đã gặp**: `%` literal trong `RAISE` phải escape `%%`; CASE trả `text` gán cột ENUM phải ép `::<enum>`;
  KHÔNG `jsonb_populate_record` trên row có cột **generated** (dùng trigger gán trực tiếp như `fn_fill_pol_base`).

## 5. Trạng thái Module ERP (đã xong + verify trên DB thật)
- **Đợt 1**: item master, WMS 3 cấp (location→zone→bin), QC-trước-khi-nhập, ledger + view (`v_stock_on_hand`,
  `v_available_stock`, `v_lot_traceability`, `v_po_line_progress`...).
- **Đợt 2**: BOM đa cấp, production_plan/order, MRP (view đệ quy gross → netting → sinh PR).
- **Đợt 3**: thực thi SX (material_issue, production_receipt, QC thành phẩm), genealogy (mức MO), MRP
  level-by-level `fn_run_mrp()`.
- **Đợt 4**: auto-MO `fn_generate_production_orders()`, genealogy định lượng `v_lot_genealogy_alloc`, giá vốn
  thực theo lô `fn_roll_lot_cost()` (CHỈ NVL).
- **Đa đơn vị**: `uom.dimension`+`ratio_to_anchor`, `item_uom_conversion.factor_to_base`, `fn_to_base`, cột
  `*_base` + trigger (mục 11 của 004), view `v_item_valid_uom` (mục 11.5).
- **Đợt 5a**: nhận hàng KHÔNG-PO (`receipt_source` walk_in/loan_return, `coa_status`); **cho mượn** nguyên liệu
  đối tác ngoài (`material_loan`+`material_loan_line`, ledger `loan_out`/`loan_return`, `v_material_loan_status`).
- **Đợt 5b**: **BÁN HÀNG** (khối 5b của 004) — `customer`, `sales_order(_line)`, `sales_shipment(_line)` (ledger
  `sales_issue` + COGS theo lô), `sales_invoice(_line)` (VAT), `customer_payment`; view `v_sales_margin`,
  `v_invoice_totals`, `v_ar_aging`, `v_so_line_fulfillment`. **loan→sale**: bán hàng đang-cho-mượn → dòng giao
  `loan_line_id` + `from_bin_id NULL` → KHÔNG post ledger (hàng đã rời kho ở `loan_out`); `v_material_loan_status`
  trừ thêm `sold_qty_base`. Bán chỉ ĐỌC giá lô → `fn_roll_lot_cost` KHÔNG đổi.
- **Đợt 6**: **VẬT CHỨA (handling unit)** (khối 6 của 004) — theo dõi TỪNG phuy/can/pallet. `container_type` +
  `handling_unit` (hu_no/barcode, item, lô, current_bin suy-từ-ledger, parent_hu pallet lồng, status, tare/gross
  catch-weight, opened_at). Thêm `inventory_movement.hu_id` **NOT NULL** (bắt buộc mọi item) — trigger `trg_fill_hu`
  (BEFORE INSERT) tự điền (tìm HU của lô / tạo vật chứa mặc định theo item_type) → demo Bước 5-10 KHÔNG sửa dòng nào,
  hồi quy bất biến. movement_type `repack` (chiết/gộp). View `v_hu_stock`/`v_bin_hu`/`v_hu_tree`(đệ quy)/
  `v_hu_reconcile`(guard: Σ HU = v_stock_on_hand, lệch=0)/`v_hu_expiring_after_open`. `item.shelf_life_after_open_days`.
  Demo Bước 11 (item `RM-DRUM300` ngoài BOM): chiết→cân→gộp→mở nắp→pallet lồng→move→dùng.
- **Số chốt demo (007)**: SF-CREAM **61.4/kg**, FG-CREAM50 **6.27/cái**, glycerin **0.04/g** (mốc hồi quy giá vốn,
  BẤT BIẾN). Tổng giá trị **tồn kho = 7643** sau Bước 10; **55 dòng ledger đều có hu_id** (NOT NULL), `v_hu_reconcile`
  **0 lệch**. Công nợ phải thu demo: Z 1160 + XYZ 108.
- **Đợt 5 (còn lại — chỉ gợi ý nếu user hỏi)**: overhead/nhân công vào giá vốn; truyền định lượng genealogy ĐA
  CẤP; cấp phát lô SX tự động theo FEFO; GL kế toán nâng cao (double-entry, trả hàng bán, bảng giá).

## 6. Chạy tiếp "context" ở máy khác
- File này (`CLAUDE.md`) **tự nạp** khi mở repo bằng Claude Code → có ngay ngữ cảnh.
- Snapshot **bộ nhớ Claude** (ghi chú kỹ thuật của các phiên trước) ở [docs/context/](docs/context/) — xem
  `docs/context/README.md` để khôi phục vào `~/.claude` nếu muốn (không bắt buộc).
- Sao lưu/khôi phục DB: [BACKUP.md](BACKUP.md) (lưu ý **restore phải vào DB rỗng** vì trigger audit).

## 7. Lưu ý dữ liệu seed
`data/*.csv` là seed Core RBAC. `data/users.csv` ở repo đã **sanitize** (admin demo: `admin@example.com`,
hash placeholder) — KHÔNG phải tài khoản thật. Thay bằng hash thật nếu xây tầng auth. 006/007 chỉ dùng
`(SELECT id FROM users LIMIT 1)` nên admin demo không ảnh hưởng luồng ERP.
