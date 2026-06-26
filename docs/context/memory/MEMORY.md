# Memory Index

- [Schema scope decisions](schema-scope-decisions.md) — vide-db-postgres: sửa in-place (không ALTER migration) + hardening đã làm + deploy/backup (DEPLOY.md/BACKUP.md)
- [ERP module](erp-module.md) — initdb/004_test.sql: ERP mỹ phẩm đợt 1-4 XONG (item master+WMS+QC+tồn lô, BOM/MRP, thực thi SX+genealogy, auto-MO+giá vốn lô, ĐA ĐƠN VỊ fn_to_base+cột *_base); + nhận hàng KHÔNG-PO (receipt_source/coa_status) + ĐỢT 5a CHO MƯỢN→nhận lại (material_loan, loan_out/loan_return, v_material_loan_status) + ĐỢT 5b BÁN HÀNG/AR (customer, sales_order/shipment+sales_issue+COGS, sales_invoice VAT, customer_payment, v_sales_margin/v_invoice_totals/v_ar_aging, loan→sale không-ledger); seed 006/007 + ERP.md
