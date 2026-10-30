-- 008_receive_and_route.sql — faster daily work on phones:
--  * app_receive_batch: receive several incoming transfers (a whole order) in ONE all-or-nothing step.
--  * app_get_order: "where are the pieces" now carries the stage rank, so the screen can draw the route.

/** Accept everything pending on the given transfers (each must be addressed to the caller). */
CREATE FUNCTION public.app_receive_batch(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_prev jsonb; v_id uuid; v_pending int; v_n int := 0; v_total int := 0;
BEGIN
  IF jsonb_typeof(p -> 'transferIds') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'transferIds') NOT BETWEEN 1 AND 500 THEN
    PERFORM factory.err('INVALID', 'لا توجد تحويلات للاستلام');
  END IF;
  v_prev := factory.idem_begin(a.employee_id, 'transfer.receive_batch', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  -- deterministic order = no deadlocks between two people receiving overlapping sets
  FOR v_id IN
    SELECT DISTINCT factory.j_uuid(jsonb_build_object('v', x), 'v', true, 'التحويل') AS id
      FROM jsonb_array_elements_text(p -> 'transferIds') x ORDER BY 1
  LOOP
    SELECT pending_qty INTO v_pending FROM factory.transfers WHERE id = v_id FOR UPDATE;
    IF v_pending IS NULL THEN PERFORM factory.err('NOT_FOUND', 'التحويل غير موجود'); END IF;
    CONTINUE WHEN v_pending = 0;
    -- same checks as a single receipt (addressee, quantities, ledger, audit)
    PERFORM public.app_receive(v_id, jsonb_build_object('requestKey', gen_random_uuid(), 'acceptQty', v_pending, 'disputeQty', 0, 'rejectQty', 0));
    v_n := v_n + 1;
    v_total := v_total + v_pending;
  END LOOP;
  IF v_n = 0 THEN PERFORM factory.err('BUSINESS_RULE', 'لا توجد قطع بانتظار الاستلام'); END IF;
  RETURN factory.idem_finish(a.employee_id, 'transfer.receive_batch', v_key, jsonb_build_object('transfers', v_n, 'quantity', v_total));
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
