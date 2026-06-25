# docs/context — Snapshot bộ nhớ Claude Code

Thư mục này là **bản chụp bộ nhớ (memory) của Claude Code** từ các phiên làm việc trước — ghi chú kỹ thuật
về quyết định schema và tiến độ Module ERP. Mục đích: chuyển "context" sang máy khác khi clone repo.

## Có gì ở đây
- `memory/MEMORY.md` — chỉ mục bộ nhớ (mỗi dòng 1 ghi chú).
- `memory/erp-module.md` — toàn bộ Module ERP (đợt 1–4 + đa đơn vị + `v_item_valid_uom`) & quy ước module.
- `memory/schema-scope-decisions.md` — quy ước sửa schema Core, phần đã hardening, phần còn optional.

> Đây chỉ là ghi chú kỹ thuật, **không chứa bí mật**. Tài khoản trong `data/users.csv` đã được sanitize.

## Cách dùng ở máy mới
1. **Không cần làm gì để có ngữ cảnh cơ bản**: file [`CLAUDE.md`](../../CLAUDE.md) ở gốc repo **tự nạp** khi
   mở dự án bằng Claude Code — đã tóm tắt đầy đủ kiến trúc, quy ước, trạng thái.
2. **(Tuỳ chọn) Khôi phục bộ nhớ chi tiết** vào Claude Code để các phiên sau tự nhớ:
   - Mở dự án bằng Claude Code một lần (nó tạo sẵn thư mục bộ nhớ), rồi tìm:
     `~/.claude/projects/<ENCODED_ABS_PATH>/memory/`
     trong đó `<ENCODED_ABS_PATH>` = đường dẫn tuyệt đối của repo, thay mọi `/` bằng `-` (bỏ dấu `/` đầu).
     Ví dụ repo ở `/Users/ban/code/erp_db` → `-Users-ban-code-erp_db`.
   - Chép các file trong `memory/` ở đây vào thư mục đó. Vì hash đường dẫn **khác theo máy/vị trí clone**, đừng
     dùng lại tên thư mục cũ — hãy lấy đúng thư mục mà Claude Code tạo trên máy mới.
3. Xong. Các phiên sau sẽ thấy lại các ghi chú này khi liên quan.
