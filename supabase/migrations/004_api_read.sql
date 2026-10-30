-- 004_api_read.sql — read API: one function per screen, scoped to what the caller may see.
-- All numbers are derived from the ledger (events, journal, balances); none are stored totals.

-- ---------------------------------------------------------------- order summaries
CREATE FUNCTION factory.order_rows() RETURNS TABLE (
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
$$;

CREATE FUNCTION factory.can_view_orders(a factory.actor_t) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT factory.view_all(a) OR cardinality(a.dept_ids) > 0 $$;

/** Custodies the actor operates: their shared department pools and their own individual custodies. */
CREATE FUNCTION factory.my_custodies(a factory.actor_t) RETURNS uuid[]
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(array_agg(c.id), '{}') FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id
   WHERE d.active AND c.department_id = ANY (a.dept_ids)
     AND ((c.kind = 'DEPARTMENT' AND d.custody_mode = 'SHARED') OR (c.kind = 'EMPLOYEE' AND c.employee_id = a.employee_id))
$$;

CREATE FUNCTION factory.stock_lines(p_custodies uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'custody_id', b.custody_id, 'custody_label', factory.custody_label(b.custody_id), 'department_id', c.department_id,
           'stage', d.stage, 'lot_id', l.id, 'lot_code', l.lot_code, 'order_id', o.id, 'order_code', o.order_code,
           'product_name', o.product_name, 'color', ol.color, 'size', ol.size, 'condition', b.condition, 'qty', b.qty,
           'due_date', o.due_date) ORDER BY o.due_date, o.order_code, ol.color, ol.size, b.condition), '[]'::jsonb)
    FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
    JOIN factory.departments d ON d.id = c.department_id
    JOIN factory.cut_lots l ON l.id = b.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
    JOIN factory.orders o ON o.id = ol.order_id
   WHERE b.custody_id = ANY (p_custodies) AND b.qty > 0
$$;

CREATE FUNCTION factory.transfer_json(p_where text, p_args uuid[], p_limit int) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE v jsonb;
BEGIN
  EXECUTE format($q$
    SELECT coalesce(jsonb_agg(x ORDER BY x->>'open' DESC, x->>'created_at' DESC), '[]'::jsonb) FROM (
      SELECT jsonb_build_object(
        'id', t.id, 'transfer_code', t.transfer_code, 'lot_code', l.lot_code, 'order_code', o.order_code,
        'color', ol.color, 'size', ol.size, 'condition', t.condition, 'direction', t.direction, 'state', t.state,
        'dispatched_qty', t.dispatched_qty, 'accepted_qty', t.accepted_qty, 'returned_qty', t.returned_qty,
        'pending_qty', t.pending_qty, 'disputed_qty', t.disputed_qty, 'written_off_qty', t.written_off_qty,
        'from_label', factory.custody_label(t.from_custody_id), 'to_label', factory.custody_label(t.to_custody_id),
        'from_custody_id', t.from_custody_id, 'to_custody_id', t.to_custody_id, 'reason', t.reason,
        'created_by_name', ce.display_name, 'created_at', t.created_at,
        'age_hours', floor(extract(epoch FROM now() - t.created_at) / 3600)::int,
        'open', (t.pending_qty + t.disputed_qty > 0)) AS x
        FROM factory.transfers t
        JOIN factory.cut_lots l ON l.id = t.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
        JOIN factory.orders o ON o.id = ol.order_id JOIN factory.employees ce ON ce.id = t.created_by
       WHERE %s
       ORDER BY (t.pending_qty + t.disputed_qty > 0) DESC, t.created_at DESC
       LIMIT %s) s $q$, p_where, p_limit)
  INTO v USING p_args;
  RETURN v;
END $$;

-- ================================================================ identity & dashboard
CREATE FUNCTION public.app_whoami() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  RETURN jsonb_build_object(
    'employee_id', a.employee_id, 'username', a.username, 'display_name', a.display_name,
    'must_change_password', a.must_change, 'roles', to_jsonb(a.roles),
    'departments', coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name_ar', d.name_ar,
                       'stage', d.stage, 'custody_mode', d.custody_mode) ORDER BY factory.stage_rank(d.stage), d.code)
                     FROM factory.departments d WHERE d.id = ANY (a.dept_ids)), '[]'::jsonb),
    'incoming', (SELECT count(*) FROM factory.transfers WHERE to_custody_id = ANY (factory.my_custodies(a)) AND pending_qty > 0));
END $$;

CREATE FUNCTION public.app_dashboard() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v_mine uuid[] := factory.my_custodies(a);
  v_factory jsonb;
BEGIN
  IF factory.view_all(a) THEN
    v_factory := jsonb_build_object(
      'active_orders', (SELECT count(*) FROM factory.orders WHERE status IN ('DRAFT', 'RELEASED')),
      'pending_transfers', (SELECT count(*) FROM factory.transfers WHERE pending_qty > 0),
      'disputed_units', (SELECT coalesce(sum(disputed_qty), 0) FROM factory.transfers),
      'open_defects', (SELECT count(*) FROM factory.defects WHERE status = 'OPEN'),
      'units_on_hand', (SELECT coalesce(sum(qty), 0) FROM factory.stock_balances),
      'delivered_today', (SELECT coalesce(sum(qty), 0) FROM factory.stock_events
                           WHERE kind = 'SHIPMENT' AND (created_at AT TIME ZONE 'Africa/Tripoli')::date = factory.today()),
      'stale_transfers', (SELECT count(*) FROM factory.transfers WHERE pending_qty + disputed_qty > 0 AND created_at < now() - interval '24 hours'),
      'stages', (SELECT coalesce(jsonb_agg(s ORDER BY s->>'rank'), '[]'::jsonb) FROM (
                   SELECT jsonb_build_object('label', CASE WHEN c.kind = 'TRANSIT' THEN 'قيد النقل' WHEN c.kind = 'DISPUTE' THEN 'عليه خلاف' ELSE d.name_ar END,
                     'rank', lpad(coalesce(factory.stage_rank(min(d.stage))::text, '9'), 2, '0'),
                     'good', coalesce(sum(b.qty) FILTER (WHERE b.condition = 'GOOD'), 0),
                     'defective', coalesce(sum(b.qty) FILTER (WHERE b.condition = 'DEFECTIVE'), 0)) AS s
                     FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
                     LEFT JOIN factory.departments d ON d.id = c.department_id
                    WHERE b.qty > 0
                    GROUP BY CASE WHEN c.kind = 'TRANSIT' THEN 'قيد النقل' WHEN c.kind = 'DISPUTE' THEN 'عليه خلاف' ELSE d.name_ar END) q),
      'overdue', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.due_date), '[]'::jsonb) FROM factory.order_rows() r WHERE r.overdue));
  END IF;
  RETURN jsonb_build_object(
    'mine', jsonb_build_object(
      'has_custody', cardinality(v_mine) > 0,
      'incoming', (SELECT count(*) FROM factory.transfers WHERE to_custody_id = ANY (v_mine) AND pending_qty > 0),
      'good', (SELECT coalesce(sum(qty), 0) FROM factory.stock_balances WHERE custody_id = ANY (v_mine) AND condition = 'GOOD'),
      'defective', (SELECT coalesce(sum(qty), 0) FROM factory.stock_balances WHERE custody_id = ANY (v_mine) AND condition = 'DEFECTIVE'),
      'open_work', (SELECT count(*) FROM factory.work_assignments WHERE employee_id = a.employee_id AND status IN ('ASSIGNED', 'IN_PROGRESS'))),
    'factory', v_factory);
END $$;

-- ================================================================ orders
CREATE FUNCTION public.app_list_orders(p_filter text, p_search text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v_q text := nullif(left(btrim(coalesce(p_search, '')), 60), '');
BEGIN
  PERFORM factory.assert(factory.can_view_orders(a));
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.overdue DESC, r.due_date, r.order_code), '[]'::jsonb) FROM (
    SELECT * FROM factory.order_rows() o
     WHERE CASE coalesce(p_filter, 'active')
             WHEN 'active' THEN o.status IN ('DRAFT', 'RELEASED')
             WHEN 'overdue' THEN o.overdue
             WHEN 'closed' THEN o.status = 'CLOSED'
             ELSE true END
       AND (v_q IS NULL OR strpos(lower(o.order_code || ' ' || o.customer_name || ' ' || o.product_name), lower(v_q)) > 0)
     ORDER BY o.overdue DESC, o.due_date LIMIT 500) r);
END $$;

CREATE FUNCTION public.app_get_order(p_id uuid) RETURNS jsonb
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
          ORDER BY ol.color, ol.size), '[]'::jsonb) FROM factory.order_lines ol WHERE ol.order_id = p_id),
      'where', (SELECT coalesce(jsonb_agg(jsonb_build_object('label', label, 'qty', qty) ORDER BY rank, label), '[]'::jsonb) FROM (
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

-- ================================================================ cutting
CREATE FUNCTION public.app_cutting_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  PERFORM factory.assert(factory.in_stage(a, 'CUTTING'), 'شاشة القص لأعضاء قسم القص');
  RETURN jsonb_build_object(
    'depts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name_ar)), '[]'::jsonb)
                FROM factory.departments d WHERE d.id = ANY (a.dept_ids) AND d.stage = 'CUTTING'),
    'lines', (SELECT coalesce(jsonb_agg(x ORDER BY x->>'due_date', x->>'order_code'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', ol.id, 'order_code', o.order_code, 'product_name', o.product_name, 'due_date', o.due_date,
                 'color', ol.color, 'size', ol.size, 'planned_qty', ol.planned_qty,
                 'cut_qty', coalesce(sum(l.created_qty) FILTER (WHERE NOT l.is_replacement), 0)) AS x
          FROM factory.order_lines ol JOIN factory.orders o ON o.id = ol.order_id
          LEFT JOIN factory.cut_lots l ON l.order_line_id = ol.id
         WHERE o.status = 'RELEASED'
         GROUP BY ol.id, o.id
        HAVING ol.planned_qty > coalesce(sum(l.created_qty) FILTER (WHERE NOT l.is_replacement), 0)) q),
    'replacements', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', dp.id, 'replacement_qty', dp.replacement_qty,
          'reason', dp.reason, 'defect_code', df.defect_code, 'order_line_id', ol.id, 'order_code', o.order_code,
          'color', ol.color, 'size', ol.size) ORDER BY dp.approved_at), '[]'::jsonb)
        FROM factory.dispositions dp JOIN factory.defects df ON df.id = dp.defect_id
        JOIN factory.cut_lots l ON l.id = df.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
        JOIN factory.orders o ON o.id = ol.order_id
       WHERE dp.decision = 'REPLACE' AND o.status = 'RELEASED'
         AND NOT EXISTS (SELECT 1 FROM factory.cut_lots x WHERE x.replacement_disposition_id = dp.id)));
END $$;

-- ================================================================ my custody
CREATE FUNCTION public.app_my_stock() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v_mine uuid[] := factory.my_custodies(a);
BEGIN
  RETURN jsonb_build_object(
    'self_id', a.employee_id,
    'custodies', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'label', factory.custody_label(c.id),
                     'stage', d.stage, 'department_id', d.id) ORDER BY factory.stage_rank(d.stage)), '[]'::jsonb)
                    FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id WHERE c.id = ANY (v_mine)),
    'lines', factory.stock_lines(v_mine),
    'targets', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name_ar, 'stage', d.stage,
                   'rank', factory.stage_rank(d.stage), 'mode', d.custody_mode,
                   'members', CASE WHEN d.custody_mode = 'INDIVIDUAL' THEN
                       (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.display_name) ORDER BY e.display_name), '[]'::jsonb)
                          FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
                         WHERE r.department_id = d.id AND r.role = 'WORKER' AND r.active AND e.active)
                     ELSE '[]'::jsonb END) ORDER BY factory.stage_rank(d.stage), d.code), '[]'::jsonb)
                  FROM factory.departments d WHERE d.active AND d.stage IS NOT NULL),
    'open_defects', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', df.id, 'code', df.defect_code, 'lot_id', df.lot_id,
                       'reason', df.reason_code, 'open', df.quantity - df.repaired_qty - df.scrapped_qty)), '[]'::jsonb)
                       FROM factory.defects df WHERE df.status = 'OPEN'
                        AND df.lot_id IN (SELECT lot_id FROM factory.stock_balances WHERE custody_id = ANY (v_mine) AND condition = 'DEFECTIVE' AND qty > 0)));
END $$;

-- ================================================================ transfers
CREATE FUNCTION public.app_list_transfers(p_tab text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v_mine uuid[] := factory.my_custodies(a);
  v_rows jsonb;
BEGIN
  CASE coalesce(p_tab, 'incoming')
    WHEN 'incoming' THEN v_rows := factory.transfer_json('t.to_custody_id = ANY ($1) AND t.pending_qty > 0', v_mine, 200);
    WHEN 'outgoing' THEN v_rows := factory.transfer_json('t.from_custody_id = ANY ($1)', v_mine, 100);
    WHEN 'disputes' THEN
      IF factory.view_all(a) THEN v_rows := factory.transfer_json('t.disputed_qty > 0 AND $1 IS NOT NULL', v_mine, 300);
      ELSE v_rows := factory.transfer_json('t.disputed_qty > 0 AND (t.to_custody_id = ANY ($1) OR t.from_custody_id = ANY ($1))', v_mine, 300);
      END IF;
    WHEN 'all' THEN
      PERFORM factory.assert(factory.view_all(a));
      v_rows := factory.transfer_json('t.pending_qty + t.disputed_qty > 0 AND $1 IS NOT NULL', v_mine, 300);
    ELSE PERFORM factory.err('INVALID', 'تبويب غير معروف');
  END CASE;
  RETURN jsonb_build_object('mine', to_jsonb(v_mine), 'is_supervisor', factory.has_role(a, 'SUPERVISOR'),
                            'view_all', factory.view_all(a), 'rows', v_rows);
END $$;

-- ================================================================ work
CREATE FUNCTION public.app_work_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v_assigner boolean := factory.has_role(a, 'SUPERVISOR') OR factory.in_stage(a, 'CUTTING');
BEGIN
  RETURN jsonb_build_object(
    'assigner', v_assigner, 'is_supervisor', factory.has_role(a, 'SUPERVISOR'),
    'mine', (SELECT coalesce(jsonb_agg(x ORDER BY x->>'status', x->>'created_at' DESC), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', w.id, 'order_code', o.order_code, 'color', ol.color, 'size', ol.size, 'lot_code', l.lot_code,
          'department_name', d.name_ar, 'assigned_qty', w.assigned_qty, 'completed_qty', w.completed_qty, 'status', w.status,
          'notes', w.notes, 'created_at', w.created_at,
          'co_workers', (SELECT count(*) - 1 FROM factory.work_assignments z WHERE z.order_line_id = w.order_line_id
                          AND z.lot_id IS NOT DISTINCT FROM w.lot_id AND z.department_id = w.department_id AND z.status <> 'CANCELLED')) AS x
          FROM factory.work_assignments w JOIN factory.order_lines ol ON ol.id = w.order_line_id JOIN factory.orders o ON o.id = ol.order_id
          LEFT JOIN factory.cut_lots l ON l.id = w.lot_id JOIN factory.departments d ON d.id = w.department_id
         WHERE w.employee_id = a.employee_id ORDER BY w.created_at DESC LIMIT 100) q),
    'open', CASE WHEN v_assigner THEN (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', w.id, 'employee_name', e.display_name, 'department_name', d.name_ar, 'order_code', o.order_code,
          'color', ol.color, 'size', ol.size, 'assigned_qty', w.assigned_qty, 'completed_qty', w.completed_qty, 'status', w.status) AS x
          FROM factory.work_assignments w JOIN factory.employees e ON e.id = w.employee_id JOIN factory.departments d ON d.id = w.department_id
          JOIN factory.order_lines ol ON ol.id = w.order_line_id JOIN factory.orders o ON o.id = ol.order_id
         WHERE w.status IN ('ASSIGNED', 'IN_PROGRESS') ORDER BY w.created_at DESC LIMIT 200) q) END,
    'lines', CASE WHEN v_assigner THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', ol.id,
          'label', o.order_code || ' — ' || ol.color || ' / ' || ol.size || ' (' || ol.planned_qty || ')',
          'lots', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'code', l.lot_code) ORDER BY l.created_at), '[]'::jsonb)
                     FROM factory.cut_lots l WHERE l.order_line_id = ol.id)) ORDER BY o.due_date, o.order_code), '[]'::jsonb)
        FROM factory.order_lines ol JOIN factory.orders o ON o.id = ol.order_id WHERE o.status = 'RELEASED') END,
    'depts', CASE WHEN v_assigner THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name_ar,
          'members', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.display_name) ORDER BY e.display_name), '[]'::jsonb)
                        FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
                       WHERE r.department_id = d.id AND r.role = 'WORKER' AND r.active AND e.active))
          ORDER BY factory.stage_rank(d.stage)), '[]'::jsonb)
        FROM factory.departments d WHERE d.active AND d.stage IS NOT NULL) END);
END $$;

-- ================================================================ quality
CREATE FUNCTION public.app_list_defects(p_all boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  PERFORM factory.assert(factory.view_all(a) OR cardinality(a.dept_ids) > 0);
  RETURN jsonb_build_object('can_decide', factory.has_role(a, 'SUPERVISOR'), 'rows', (
    SELECT coalesce(jsonb_agg(x ORDER BY x->>'status' DESC, x->>'created_at' DESC), '[]'::jsonb) FROM (
      SELECT jsonb_build_object('id', df.id, 'defect_code', df.defect_code, 'lot_code', l.lot_code, 'order_code', o.order_code,
        'color', ol.color, 'size', ol.size, 'quantity', df.quantity, 'repaired_qty', df.repaired_qty, 'scrapped_qty', df.scrapped_qty,
        'open_qty', df.quantity - df.repaired_qty - df.scrapped_qty, 'reason_code', df.reason_code, 'description', df.description,
        'detected_department', dd.name_ar, 'responsible_department', rd.name_ar, 'status', df.status,
        'reported_by_name', e.display_name, 'created_at', df.created_at,
        'holders', (SELECT coalesce(jsonb_agg(jsonb_build_object('custody_id', c.id, 'label', factory.custody_label(c.id), 'qty', b.qty)), '[]'::jsonb)
                      FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
                     WHERE b.lot_id = df.lot_id AND b.condition = 'DEFECTIVE' AND b.qty > 0 AND c.kind IN ('DEPARTMENT', 'EMPLOYEE')),
        'decisions', (SELECT coalesce(jsonb_agg(jsonb_build_object('decision', p.decision, 'quantity', p.quantity, 'reason', p.reason,
                        'approved_by', pe.display_name, 'approved_at', p.approved_at) ORDER BY p.approved_at), '[]'::jsonb)
                        FROM factory.dispositions p JOIN factory.employees pe ON pe.id = p.approved_by WHERE p.defect_id = df.id)) AS x
        FROM factory.defects df JOIN factory.cut_lots l ON l.id = df.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
        JOIN factory.orders o ON o.id = ol.order_id JOIN factory.departments dd ON dd.id = df.detected_department_id
        LEFT JOIN factory.departments rd ON rd.id = df.responsible_department_id JOIN factory.employees e ON e.id = df.reported_by
       WHERE coalesce(p_all, false) OR df.status = 'OPEN'
       ORDER BY df.created_at DESC LIMIT 300) q));
END $$;

-- ================================================================ warehouse
CREATE FUNCTION public.app_warehouse_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  v_ship boolean := factory.in_stage(a, 'WAREHOUSE');
  v_custodies uuid[];
BEGIN
  PERFORM factory.assert(v_ship OR factory.view_all(a));
  IF v_ship THEN
    SELECT coalesce(array_agg(x), '{}') INTO v_custodies FROM unnest(factory.my_custodies(a)) x
     WHERE EXISTS (SELECT 1 FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id WHERE c.id = x AND d.stage = 'WAREHOUSE');
  ELSE
    SELECT coalesce(array_agg(c.id), '{}') INTO v_custodies FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id
     WHERE d.stage = 'WAREHOUSE';
  END IF;
  RETURN jsonb_build_object(
    'can_ship', v_ship, 'today', factory.today(),
    'lines', factory.stock_lines(v_custodies),
    'orders', (SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM factory.order_rows() r WHERE r.status IN ('DRAFT', 'RELEASED')),
    'shipments', (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('shipment_code', s.shipment_code, 'order_code', o.order_code, 'customer_name', cu.display_name,
          'delivered_on', s.delivered_on, 'quantity', (SELECT sum(quantity) FROM factory.shipment_lines sl WHERE sl.shipment_id = s.id),
          'created_by_name', e.display_name) AS x
          FROM factory.shipments s JOIN factory.orders o ON o.id = s.order_id JOIN factory.customers cu ON cu.id = s.customer_id
          JOIN factory.employees e ON e.id = s.created_by ORDER BY s.created_at DESC LIMIT 30) q));
END $$;

-- ================================================================ reports (management & reviewer)
CREATE FUNCTION factory.reconciliation() RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  WITH ev AS (SELECT lot_id,
               coalesce(sum(qty) FILTER (WHERE kind = 'CUT'), 0)::int AS cut,
               coalesce(sum(qty) FILTER (WHERE kind = 'SHIPMENT'), 0)::int AS delivered,
               coalesce(sum(qty) FILTER (WHERE kind = 'SCRAP'), 0)::int AS scrapped
              FROM factory.stock_events GROUP BY lot_id),
  adj AS (SELECT lot_id, coalesce(sum(signed_qty) FILTER (WHERE signed_qty > 0), 0)::int AS adj_in,
                 coalesce(-sum(signed_qty) FILTER (WHERE signed_qty < 0), 0)::int AS adj_out
            FROM factory.stock_adjustments GROUP BY lot_id),
  bal AS (SELECT b.lot_id, sum(b.qty)::int AS on_hand,
                 coalesce(sum(b.qty) FILTER (WHERE c.kind IN ('TRANSIT', 'DISPUTE')), 0)::int AS in_transit
            FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id GROUP BY b.lot_id),
  jr AS (SELECT lot_id, sum(delta)::int AS net FROM factory.stock_journal GROUP BY lot_id),
  lots AS (
    SELECT l.id AS lot_id, l.lot_code, o.order_code, ol.color, ol.size,
           coalesce(ev.cut, 0) AS cut_qty, coalesce(adj.adj_in, 0) AS adjust_in, coalesce(adj.adj_out, 0) AS adjust_out,
           coalesce(ev.delivered, 0) AS delivered, coalesce(ev.scrapped, 0) AS scrapped,
           coalesce(bal.on_hand, 0) AS on_hand, coalesce(bal.in_transit, 0) AS in_transit, coalesce(jr.net, 0) AS journal_net,
           coalesce(ev.cut, 0) + coalesce(adj.adj_in, 0) - coalesce(ev.delivered, 0) - coalesce(ev.scrapped, 0) - coalesce(adj.adj_out, 0) AS expected
      FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id JOIN factory.orders o ON o.id = ol.order_id
      LEFT JOIN ev ON ev.lot_id = l.id LEFT JOIN adj ON adj.lot_id = l.id LEFT JOIN bal ON bal.lot_id = l.id LEFT JOIN jr ON jr.lot_id = l.id),
  proj AS (SELECT count(*)::int AS n FROM factory.stock_balances b
             LEFT JOIN (SELECT lot_id, custody_id, condition, sum(delta) AS net FROM factory.stock_journal GROUP BY 1, 2, 3) j
               ON j.lot_id = b.lot_id AND j.custody_id = b.custody_id AND j.condition = b.condition
            WHERE b.qty <> coalesce(j.net, 0)),
  trf AS (SELECT count(*)::int AS n FROM factory.transfers t
           WHERE t.pending_qty <> coalesce((SELECT sum(b.qty) FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
                                             WHERE c.transfer_id = t.id AND c.kind = 'TRANSIT'), 0)
              OR t.disputed_qty <> coalesce((SELECT sum(b.qty) FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
                                             WHERE c.transfer_id = t.id AND c.kind = 'DISPUTE'), 0))
  SELECT jsonb_build_object(
    'lots', coalesce((SELECT jsonb_agg(to_jsonb(lots) || jsonb_build_object('balanced', lots.expected = lots.on_hand AND lots.journal_net = lots.on_hand)
                       ORDER BY lots.order_code, lots.lot_code) FROM lots), '[]'::jsonb),
    'all_balanced', NOT EXISTS (SELECT 1 FROM lots WHERE expected <> on_hand OR journal_net <> on_hand)
                    AND (SELECT n FROM proj) = 0 AND (SELECT n FROM trf) = 0,
    'projection_mismatches', (SELECT n FROM proj), 'transfer_mismatches', (SELECT n FROM trf),
    'negative_balances', (SELECT count(*) FROM factory.stock_balances WHERE qty < 0),
    'totals', (SELECT jsonb_build_object('cut', coalesce(sum(cut_qty), 0), 'adjust_in', coalesce(sum(adjust_in), 0),
                 'adjust_out', coalesce(sum(adjust_out), 0), 'delivered', coalesce(sum(delivered), 0),
                 'scrapped', coalesce(sum(scrapped), 0), 'on_hand', coalesce(sum(on_hand), 0),
                 'in_transit', coalesce(sum(in_transit), 0)) FROM lots))
$$;

CREATE FUNCTION public.app_report(p_type text, p_params jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(false);
  p jsonb := coalesce(p_params, '{}'::jsonb);
  v_page int := greatest(1, least(coalesce((p ->> 'page')::int, 1), 10000));
  v_from date; v_to date; v_order uuid; v_kind text;
BEGIN
  PERFORM factory.assert(factory.view_all(a), 'التقارير الشاملة متاحة للإدارة والمشرفين والمراجعين');
  IF (p ->> 'export')::boolean IS TRUE THEN
    PERFORM factory.audit(a.employee_id, 'report.export', 'report', p_type, NULL, p);
  END IF;
  CASE p_type
    WHEN 'stages' THEN
      RETURN (SELECT coalesce(jsonb_agg(x ORDER BY x->>'rank', x->>'label'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('label', CASE WHEN c.kind = 'TRANSIT' THEN 'قيد النقل' WHEN c.kind = 'DISPUTE' THEN 'عليه خلاف' ELSE d.name_ar END,
          'rank', lpad(coalesce(factory.stage_rank(min(d.stage))::text, '99'), 2, '0'),
          'good', coalesce(sum(b.qty) FILTER (WHERE b.condition = 'GOOD'), 0),
          'defective', coalesce(sum(b.qty) FILTER (WHERE b.condition = 'DEFECTIVE'), 0)) AS x
          FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
          LEFT JOIN factory.departments d ON d.id = c.department_id WHERE b.qty > 0
         GROUP BY CASE WHEN c.kind = 'TRANSIT' THEN 'قيد النقل' WHEN c.kind = 'DISPUTE' THEN 'عليه خلاف' ELSE d.name_ar END) q);
    WHEN 'employees' THEN
      RETURN (SELECT coalesce(jsonb_agg(x ORDER BY x->>'department', x->>'display_name'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('display_name', e.display_name, 'department', d.name_ar,
          'good', coalesce(sum(b.qty) FILTER (WHERE b.condition = 'GOOD'), 0),
          'defective', coalesce(sum(b.qty) FILTER (WHERE b.condition = 'DEFECTIVE'), 0)) AS x
          FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id AND c.kind = 'EMPLOYEE'
          JOIN factory.employees e ON e.id = c.employee_id JOIN factory.departments d ON d.id = c.department_id
         WHERE b.qty > 0 GROUP BY e.id, e.display_name, d.name_ar) q);
    WHEN 'orders' THEN
      RETURN (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.overdue DESC, r.due_date), '[]'::jsonb) FROM factory.order_rows() r
               WHERE CASE coalesce(p ->> 'filter', 'active') WHEN 'overdue' THEN r.overdue WHEN 'all' THEN true
                          ELSE r.status IN ('DRAFT', 'RELEASED') END);
    WHEN 'reconciliation' THEN
      RETURN factory.reconciliation();
    WHEN 'defects' THEN
      RETURN (SELECT coalesce(jsonb_agg(x ORDER BY (x->>'quantity')::int DESC), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('reason_code', df.reason_code, 'department', d.name_ar,
          'quantity', sum(df.quantity), 'repaired', sum(df.repaired_qty), 'scrapped', sum(df.scrapped_qty),
          'open', sum(df.quantity - df.repaired_qty - df.scrapped_qty)) AS x
          FROM factory.defects df JOIN factory.departments d ON d.id = df.detected_department_id
         GROUP BY df.reason_code, d.name_ar) q);
    WHEN 'contributions' THEN
      RETURN (SELECT coalesce(jsonb_agg(x ORDER BY x->>'department', x->>'display_name'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('display_name', e.display_name, 'department', d.name_ar,
          'assignments', count(*) FILTER (WHERE w.status <> 'CANCELLED'),
          'completed_work', coalesce(sum(w.completed_qty) FILTER (WHERE w.status <> 'CANCELLED'), 0),
          'shared_assignments', count(*) FILTER (WHERE w.status <> 'CANCELLED' AND EXISTS (
              SELECT 1 FROM factory.work_assignments z WHERE z.order_line_id = w.order_line_id AND z.lot_id IS NOT DISTINCT FROM w.lot_id
                 AND z.department_id = w.department_id AND z.employee_id <> w.employee_id AND z.status <> 'CANCELLED')),
          'ledger_actions', (SELECT count(*) FROM factory.stock_events se WHERE se.actor_employee_id = e.id)) AS x
          FROM factory.work_assignments w JOIN factory.employees e ON e.id = w.employee_id JOIN factory.departments d ON d.id = w.department_id
         GROUP BY e.id, e.display_name, d.name_ar) q);
    WHEN 'movements' THEN
      v_from := CASE WHEN p ->> 'from' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p ->> 'from')::date END;
      v_to := CASE WHEN p ->> 'to' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p ->> 'to')::date END;
      v_order := factory.j_uuid(p, 'orderId', false, 'الطلب');
      v_kind := CASE WHEN p ->> 'kind' IN ('CUT','DISPATCH','ACCEPT','DISPUTE','REJECT_RETURN','DISPUTE_ACCEPT','DISPUTE_RETURN',
                                           'DEFECT_MARK','REPAIR','SCRAP','SHIPMENT','ADJUSTMENT') THEN p ->> 'kind' END;
      RETURN (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', e.id, 'kind', e.kind, 'qty', e.qty, 'created_at', e.created_at, 'actor_name', emp.display_name,
          'department', d.name_ar, 'lot_code', l.lot_code, 'order_code', o.order_code, 'color', ol.color, 'size', ol.size,
          'reason', e.reason, 'reference', coalesce(t.transfer_code, s.shipment_code, df.defect_code)) AS x
          FROM factory.stock_events e JOIN factory.employees emp ON emp.id = e.actor_employee_id
          LEFT JOIN factory.departments d ON d.id = e.acting_department_id
          JOIN factory.cut_lots l ON l.id = e.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id JOIN factory.orders o ON o.id = ol.order_id
          LEFT JOIN factory.transfers t ON t.id = e.transfer_id LEFT JOIN factory.shipments s ON s.id = e.shipment_id
          LEFT JOIN factory.defects df ON df.id = e.defect_id
         WHERE (v_order IS NULL OR ol.order_id = v_order) AND (v_kind IS NULL OR e.kind::text = v_kind)
           AND (v_from IS NULL OR e.created_at >= v_from) AND (v_to IS NULL OR e.created_at < v_to + 1)
         ORDER BY e.created_at DESC, e.id LIMIT 100 OFFSET (v_page - 1) * 100) q);
    WHEN 'audit' THEN
      RETURN (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', ae.id, 'action', ae.action, 'target_type', ae.target_type, 'target_id', ae.target_id,
          'metadata', ae.metadata, 'occurred_at', ae.occurred_at, 'actor_name', e.display_name) AS x
          FROM factory.audit_events ae LEFT JOIN factory.employees e ON e.id = ae.actor_employee_id
         ORDER BY ae.occurred_at DESC, ae.id DESC LIMIT 100 OFFSET (v_page - 1) * 100) q);
    ELSE
      PERFORM factory.err('INVALID', 'نوع تقرير غير معروف');
  END CASE;
END $$;

-- ================================================================ administration
CREATE FUNCTION public.app_admin_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  RETURN jsonb_build_object(
    'self_id', a.employee_id,
    'employees', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'username', e.username, 'display_name', e.display_name,
        'active', e.active, 'must_change_password', e.must_change_password,
        'roles', (SELECT coalesce(jsonb_agg(jsonb_build_object('role', r.role, 'department_id', r.department_id, 'department_name', d.name_ar)
                    ORDER BY r.role, d.code), '[]'::jsonb)
                    FROM factory.employee_roles r LEFT JOIN factory.departments d ON d.id = r.department_id
                   WHERE r.employee_id = e.id AND r.active)) ORDER BY e.active DESC, e.display_name), '[]'::jsonb)
      FROM factory.employees e),
    'departments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name_ar', d.name_ar, 'stage', d.stage,
        'custody_mode', d.custody_mode, 'active', d.active,
        'member_count', (SELECT count(*) FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
                          WHERE r.department_id = d.id AND r.active AND e.active)) ORDER BY factory.stage_rank(d.stage) NULLS LAST, d.code), '[]'::jsonb)
      FROM factory.departments d));
END $$;

CREATE FUNCTION public.app_adjustments_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  RETURN jsonb_build_object(
    'holdings', (SELECT coalesce(jsonb_agg(jsonb_build_object('lot_id', b.lot_id, 'custody_id', b.custody_id, 'condition', b.condition,
        'qty', b.qty, 'lot_code', l.lot_code, 'order_code', o.order_code, 'color', ol.color, 'size', ol.size,
        'custody_label', factory.custody_label(b.custody_id)) ORDER BY o.order_code, l.lot_code), '[]'::jsonb)
      FROM factory.stock_balances b JOIN factory.cut_lots l ON l.id = b.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
      JOIN factory.orders o ON o.id = ol.order_id WHERE b.qty > 0),
    'custodies', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'label', factory.custody_label(c.id))
        ORDER BY factory.stage_rank(d.stage), d.code), '[]'::jsonb)
      FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id WHERE c.kind IN ('DEPARTMENT', 'EMPLOYEE') AND d.active),
    'lots', (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', l.id, 'label', o.order_code || ' ' || ol.color || '/' || ol.size || ' (' || l.lot_code || ')') AS x
          FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id JOIN factory.orders o ON o.id = ol.order_id
         ORDER BY l.created_at DESC LIMIT 500) q),
    'history', (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', s.id, 'signed_qty', s.signed_qty, 'condition', s.condition, 'reason', s.reason,
          'reference', s.reference, 'created_at', s.created_at, 'lot_code', l.lot_code, 'order_code', o.order_code,
          'approved_by_name', e.display_name, 'custody_label', factory.custody_label(s.custody_id)) AS x
          FROM factory.stock_adjustments s JOIN factory.cut_lots l ON l.id = s.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
          JOIN factory.orders o ON o.id = ol.order_id JOIN factory.employees e ON e.id = s.approved_by
         ORDER BY s.created_at DESC LIMIT 100) q));
END $$;
