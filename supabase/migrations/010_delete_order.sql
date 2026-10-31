-- 010_delete_order.sql — the system administrator or a supervisor (who creates orders) can delete an order.
--
-- Orders are protected by orders_no_delete (history refers to them), so "delete" removes the order from
-- every list, report and screen and records who deleted it. It is allowed only while NOTHING has been cut:
-- once pieces exist they are in the ledger, and the order is closed instead (unchanged behaviour).

ALTER TABLE factory.orders ADD COLUMN deleted_at timestamptz;
ALTER TABLE factory.orders ADD COLUMN deleted_by uuid REFERENCES factory.employees (id);

-- every order list, the order page, the dashboard and reports read through order_rows()
CREATE OR REPLACE FUNCTION factory.order_rows() RETURNS TABLE (
  id uuid, order_code text, customer_name text, product_name text, model_code text, due_date date, status text,
  planned_qty int, cut_qty int, in_production_qty int, in_warehouse_qty int, delivered_qty int, scrapped_qty int,
  remaining_qty int, overdue boolean, days_late int)
LANGUAGE sql STABLE SET search_path = '' AS $$
  WITH lt AS (SELECT order_id, sum(planned_qty)::int AS planned FROM factory.order_lines GROUP BY order_id),
  ev AS (
    SELECT ol.order_id,
           coalesce(sum(e.qty) FILTER (WHERE e.kind = 'CUT'), 0)::int AS cut,
           coalesce(sum(e.qty) FILTER (WHERE e.kind = 'SHIPMENT'), 0)::int AS delivered,
           coalesce(sum(e.qty) FILTER (WHERE e.kind = 'SCRAP'), 0)::int AS scrapped
      FROM factory.stock_events e JOIN factory.cut_lots l ON l.id = e.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
     GROUP BY ol.order_id),
  oh AS (
    SELECT ol.order_id, coalesce(sum(b.qty), 0)::int AS total,
           coalesce(sum(b.qty) FILTER (WHERE d.stage = 'WAREHOUSE' AND b.condition = 'GOOD'), 0)::int AS wh
      FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
      LEFT JOIN factory.departments d ON d.id = c.department_id
      JOIN factory.cut_lots l ON l.id = b.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
     GROUP BY ol.order_id)
  SELECT o.id, o.order_code, cu.display_name, o.product_name, o.model_code, o.due_date, o.status::text,
         coalesce(lt.planned, 0), coalesce(ev.cut, 0), coalesce(oh.total, 0) - coalesce(oh.wh, 0), coalesce(oh.wh, 0),
         coalesce(ev.delivered, 0), coalesce(ev.scrapped, 0),
         greatest(coalesce(lt.planned, 0) - coalesce(ev.delivered, 0), 0),
         (o.status IN ('DRAFT', 'RELEASED') AND o.due_date < factory.today() AND coalesce(ev.delivered, 0) < coalesce(lt.planned, 0)),
         greatest(factory.today() - o.due_date, 0)
    FROM factory.orders o JOIN factory.customers cu ON cu.id = o.customer_id
    LEFT JOIN lt ON lt.order_id = o.id LEFT JOIN ev ON ev.order_id = o.id LEFT JOIN oh ON oh.order_id = o.id
   WHERE o.deleted_at IS NULL
$$;

CREATE FUNCTION public.app_delete_order(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(true); o record;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN') OR factory.has_role(a, 'SUPERVISOR'), 'حذف الطلبيات من صلاحية مدير النظام أو المشرف');
  SELECT id, order_code, status, deleted_at INTO o FROM factory.orders WHERE id = p_id FOR UPDATE;
  IF o.id IS NULL OR o.deleted_at IS NOT NULL THEN PERFORM factory.err('NOT_FOUND', 'الطلب غير موجود'); END IF;
  IF EXISTS (SELECT 1 FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id WHERE ol.order_id = p_id) THEN
    PERFORM factory.err('BUSINESS_RULE', 'لا يمكن حذف طلبية بدأ قصّها، لأن قطعها مسجلة في الإنتاج. أغلقها بعد انتهاء العمل عليها.');
  END IF;
  IF EXISTS (SELECT 1 FROM factory.work_assignments w JOIN factory.order_lines ol ON ol.id = w.order_line_id
              WHERE ol.order_id = p_id AND w.status IN ('ASSIGNED', 'IN_PROGRESS')) THEN
    PERFORM factory.err('BUSINESS_RULE', 'على هذه الطلبية تكليفات مفتوحة؛ ألغِها أولاً ثم احذف الطلبية.');
  END IF;
  UPDATE factory.orders SET status = 'CANCELLED', closed_at = coalesce(closed_at, now()), deleted_at = now(), deleted_by = a.employee_id
   WHERE id = p_id;
  PERFORM factory.audit(a.employee_id, 'order.delete', 'order', p_id::text, NULL,
    jsonb_build_object('order_code', o.order_code, 'from', o.status));
  RETURN jsonb_build_object('ok', true, 'order_code', o.order_code);
END $$;

CREATE OR REPLACE FUNCTION public.app_get_order(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v jsonb;
BEGIN
  PERFORM factory.assert(factory.can_view_orders(a));
  SELECT to_jsonb(r) INTO v FROM factory.order_rows() r WHERE r.id = p_id;
  IF v IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الطلب غير موجود'); END IF;
  RETURN v || (SELECT jsonb_build_object('notes', o.notes, 'created_at', o.created_at, 'released_at', o.released_at,
                       'created_by_name', e.display_name)
                 FROM factory.orders o JOIN factory.employees e ON e.id = o.created_by WHERE o.id = p_id)
    || jsonb_build_object(
      'can_manage', factory.has_role(a, 'SUPERVISOR'),
      'can_delete', (factory.has_role(a, 'ADMIN') OR factory.has_role(a, 'SUPERVISOR'))
                    AND NOT EXISTS (SELECT 1 FROM factory.cut_lots x JOIN factory.order_lines ol ON ol.id = x.order_line_id WHERE ol.order_id = p_id),
      'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object(
          'id', ol.id, 'color', ol.color, 'size', ol.size, 'planned_qty', ol.planned_qty,
          'cut_qty', coalesce((SELECT sum(created_qty) FROM factory.cut_lots x WHERE x.order_line_id = ol.id AND NOT x.is_replacement), 0),
          'replacement_cut_qty', coalesce((SELECT sum(created_qty) FROM factory.cut_lots x WHERE x.order_line_id = ol.id AND x.is_replacement), 0),
          'delivered_qty', coalesce((SELECT sum(e.qty) FROM factory.stock_events e JOIN factory.cut_lots x ON x.id = e.lot_id
                                     WHERE x.order_line_id = ol.id AND e.kind = 'SHIPMENT'), 0),
          'scrapped_qty', coalesce((SELECT sum(e.qty) FROM factory.stock_events e JOIN factory.cut_lots x ON x.id = e.lot_id
                                    WHERE x.order_line_id = ol.id AND e.kind = 'SCRAP'), 0),
          'on_hand_qty', coalesce((SELECT sum(b.qty) FROM factory.stock_balances b JOIN factory.cut_lots x ON x.id = b.lot_id
                                   WHERE x.order_line_id = ol.id), 0),
          'in_transit_qty', coalesce((SELECT sum(b.qty) FROM factory.stock_balances b JOIN factory.cut_lots x ON x.id = b.lot_id
                                      JOIN factory.custodies c ON c.id = b.custody_id
                                      WHERE x.order_line_id = ol.id AND c.kind IN ('TRANSIT', 'DISPUTE')), 0),
          'defective_qty', coalesce((SELECT sum(b.qty) FROM factory.stock_balances b JOIN factory.cut_lots x ON x.id = b.lot_id
                                     WHERE x.order_line_id = ol.id AND b.condition = 'DEFECTIVE'), 0))
          ORDER BY ol.position, ol.color, ol.size), '[]'::jsonb) FROM factory.order_lines ol WHERE ol.order_id = p_id),
      'where', (SELECT coalesce(jsonb_agg(jsonb_build_object('label', label, 'qty', qty, 'rank', rank) ORDER BY rank, label), '[]'::jsonb) FROM (
          SELECT CASE WHEN c.kind = 'TRANSIT' THEN 'قيد النقل' WHEN c.kind = 'DISPUTE' THEN 'عليه خلاف' ELSE d.name_ar END AS label,
                 coalesce(min(factory.stage_rank(d.stage)), 99) AS rank, sum(b.qty) AS qty
            FROM factory.stock_balances b JOIN factory.cut_lots x ON x.id = b.lot_id JOIN factory.order_lines ol ON ol.id = x.order_line_id
            JOIN factory.custodies c ON c.id = b.custody_id LEFT JOIN factory.departments d ON d.id = c.department_id
           WHERE ol.order_id = p_id AND b.qty > 0 GROUP BY 1) w),
      'lots', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'lot_code', l.lot_code, 'created_qty', l.created_qty,
                 'is_replacement', l.is_replacement, 'color', ol.color, 'size', ol.size, 'created_by_name', e.display_name)
                 ORDER BY l.created_at), '[]'::jsonb)
                 FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id
                 JOIN factory.employees e ON e.id = l.created_by WHERE ol.order_id = p_id),
      'shipments', (SELECT coalesce(jsonb_agg(jsonb_build_object('shipment_code', s.shipment_code, 'delivered_on', s.delivered_on,
                      'quantity', (SELECT sum(quantity) FROM factory.shipment_lines sl WHERE sl.shipment_id = s.id),
                      'created_by_name', e.display_name) ORDER BY s.created_at), '[]'::jsonb)
                      FROM factory.shipments s JOIN factory.employees e ON e.id = s.created_by WHERE s.order_id = p_id));
END $$;

-- permissions (same model as 005)
DO $$
DECLARE f record; has_roles boolean := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated');
BEGIN
  IF has_roles THEN
    EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM anon, authenticated';
  END IF;
  REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM PUBLIC;
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND (p.proname LIKE 'app\_%' OR p.proname LIKE 'svc\_%')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF has_roles THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon, authenticated', f.sig);
      IF f.proname LIKE 'app\_%' THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
      ELSE
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
      END IF;
    END IF;
  END LOOP;
END $$;
