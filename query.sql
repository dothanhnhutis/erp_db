SELECT item_type, string_agg(code, ', ' ORDER BY code) FROM item GROUP BY item_type;


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


SELECT i.code, SUM(av.qty_available) qty
FROM v_available_stock av JOIN item i ON i.id=av.item_id GROUP BY i.code ORDER BY i.code;


SELECT i.code, SUM(v.qty_on_hand) qty, MAX(v.unit_cost) gia_von, SUM(v.stock_value) gia_tri
FROM v_inventory_valuation v JOIN item i ON i.id=v.item_id
GROUP BY i.code ORDER BY gia_tri DESC NULLS LAST;


SELECT i.code, mr.gross_qty, mr.net_qty,
       (mr.production_order_id IS NOT NULL) "tạo_MO", (mr.pr_line_id IS NOT NULL) "tạo_PR"
FROM mrp_requirement mr JOIN item i ON i.id=mr.item_id
WHERE mr.mrp_run_id=1 ORDER BY mr.net_qty DESC;


SELECT pl.lot_no "lô_NVL", dl.lot_no "lô_hậu_duệ", f.lvl
FROM v_lot_genealogy_forward f
JOIN lot pl ON pl.id=f.root_lot_id JOIN lot dl ON dl.id=f.descendant_lot_id
WHERE pl.lot_no='L-RM-ARGAN' ORDER BY f.lvl;

-- nguồn lô (đệ quy)
SELECT al.lot_no "lô_nguồn", b.lvl FROM v_lot_genealogy_backward b
JOIN lot cl ON cl.id=b.root_lot_id JOIN lot al ON al.id=b.ancestor_lot_id
WHERE cl.lot_no='L-FG-CREAM50-01' ORDER BY b.lvl;
