-- 007_owner_workflow.sql — the factory owner's workflow, exactly:
--   supervisor creates the order (automatic number) and sends it to cutting
--   → the cutter may adjust QUANTITIES only (colours/sizes are fixed) and cuts
--   → the cutter distributes the pieces to one or more tailors
--   → tailor → finishing 1 → ironing → finishing 2 → warehouse.
-- Pieces move only to the NEXT stage, or back to the PREVIOUS stage with a reason.
-- The administrator can switch returns off per department.

-- ---------------------------------------------------------------- automatic order numbers
CREATE TABLE factory.code_counters (
  scope      text NOT NULL,
  period     int  NOT NULL,
  last_value int  NOT NULL CHECK (last_value > 0),
  PRIMARY KEY (scope, period)
);
ALTER TABLE factory.code_counters ENABLE ROW LEVEL SECURITY;

/** Next order number, e.g. PO-2026-0007. The counter row is locked, so concurrent orders never share a number. */
CREATE FUNCTION factory.next_order_code() RETURNS text
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_year int := extract(year FROM factory.today())::int; v_n int; v_code text;
BEGIN
  LOOP
    INSERT INTO factory.code_counters (scope, period, last_value) VALUES ('order', v_year, 1)
    ON CONFLICT (scope, period) DO UPDATE SET last_value = factory.code_counters.last_value + 1
    RETURNING last_value INTO v_n;
    v_code := format('PO-%s-%s', v_year, lpad(v_n::text, 4, '0'));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM factory.orders WHERE lower(order_code) = lower(v_code)); -- skip older manual codes
  END LOOP;
  RETURN v_code;
END $$;

-- ---------------------------------------------------------------- lines keep the order the supervisor typed (S, M, L, XL — not alphabetical)
ALTER TABLE factory.order_lines ADD COLUMN position int NOT NULL DEFAULT 0;

-- ---------------------------------------------------------------- return permission per department
ALTER TABLE factory.departments ADD COLUMN allow_return boolean NOT NULL DEFAULT true;

-- ---------------------------------------------------------------- order lines: after release only quantities may change
CREATE OR REPLACE FUNCTION factory.freeze_released_lines() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE s factory.order_status;
BEGIN
  SELECT status INTO s FROM factory.orders WHERE id = COALESCE(NEW.order_id, OLD.order_id);
  IF s = 'DRAFT' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF TG_OP = 'UPDATE' AND s = 'RELEASED'
     AND NEW.order_id = OLD.order_id AND NEW.color = OLD.color AND NEW.size = OLD.size THEN
    RETURN NEW;  -- quantity adjustment by the cutter/supervisor (checked in app_set_line_quantities)
  END IF;
  RAISE EXCEPTION 'Order lines are frozen after release' USING ERRCODE = 'check_violation';
END;
$$;

-- ---------------------------------------------------------------- supervisor: create (and send) an order
CREATE OR REPLACE FUNCTION public.app_create_order(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_code text; v_customer text; v_contact text; v_product text; v_model text; v_due date; v_notes text;
  v_send boolean := coalesce((p ->> 'send')::boolean, false);
  v_cust uuid; v_order uuid; l jsonb; v_seen text[] := '{}'; v_key text;
  v_color text; v_size text; v_qty int; v_pos int := 0;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR'), 'إنشاء الطلبيات من صلاحية المشرف');
  v_customer := factory.j_text(p, 'customerName', 1, 150, true, 'الزبون');
  v_contact := factory.j_text(p, 'customerContact', 1, 200, false, 'تواصل الزبون');
  v_product := factory.j_text(p, 'productName', 1, 150, true, 'المنتج');
  v_model := factory.j_text(p, 'modelCode', 1, 60, false, 'رمز الموديل');
  v_due := factory.j_date(p, 'dueDate', 'تاريخ التسليم');
  v_notes := factory.j_text(p, 'notes', 1, 2000, false, 'الملاحظات');
  IF jsonb_typeof(p -> 'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'lines') NOT BETWEEN 1 AND 200 THEN
    PERFORM factory.err('INVALID', 'أضف لوناً ومقاساً واحداً على الأقل (200 كحد أقصى)');
  END IF;

  INSERT INTO factory.customers (display_name, contact) VALUES (v_customer, v_contact)
  ON CONFLICT (display_name) DO UPDATE SET contact = coalesce(EXCLUDED.contact, factory.customers.contact);
  SELECT id INTO v_cust FROM factory.customers WHERE display_name = v_customer;
  v_code := factory.next_order_code();
  INSERT INTO factory.orders (order_code, customer_id, product_name, model_code, due_date, notes, created_by)
  VALUES (v_code, v_cust, v_product, v_model, v_due, v_notes, a.employee_id) RETURNING id INTO v_order;

  FOR l IN SELECT * FROM jsonb_array_elements(p -> 'lines') LOOP
    v_color := factory.j_text(l, 'color', 1, 50, true, 'اللون');
    v_size := factory.j_text(l, 'size', 1, 20, true, 'المقاس');
    v_qty := factory.j_int(l, 'plannedQty', 1, 1000000, 'الكمية');
    v_key := lower(v_color) || '|' || lower(v_size);
    IF v_key = ANY (v_seen) THEN PERFORM factory.err('INVALID', format('اللون «%s» بالمقاس «%s» مكرر', v_color, v_size)); END IF;
    v_seen := v_seen || v_key;
    v_pos := v_pos + 1;
    INSERT INTO factory.order_lines (order_id, color, size, planned_qty, position) VALUES (v_order, v_color, v_size, v_qty, v_pos);
  END LOOP;

  PERFORM factory.audit(a.employee_id, 'order.create', 'order', v_order::text, NULL,
    jsonb_build_object('orderCode', v_code, 'dueDate', v_due, 'lines', p -> 'lines'));
  IF v_send THEN PERFORM factory.set_order_status(a, v_order, ARRAY['DRAFT'], 'RELEASED'); END IF;
  RETURN jsonb_build_object('id', v_order, 'orderCode', v_code, 'sent', v_send);
END $$;

-- ---------------------------------------------------------------- cutter (or supervisor): adjust quantities only
CREATE FUNCTION public.app_set_line_quantities(p_order uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_status text; l jsonb; v_line uuid; v_qty int; r record; v_cut int; v_changes jsonb := '[]'::jsonb;
BEGIN
  PERFORM factory.assert(factory.in_stage(a, 'CUTTING') OR factory.has_role(a, 'SUPERVISOR'),
    'تعديل الكميات من صلاحية القصاص أو المشرف');
  IF jsonb_typeof(p -> 'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'lines') NOT BETWEEN 1 AND 200 THEN
    PERFORM factory.err('INVALID', 'لا توجد كميات للتعديل');
  END IF;
  SELECT status::text INTO v_status FROM factory.orders WHERE id = p_order FOR UPDATE;
  IF v_status IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الطلبية غير موجودة'); END IF;
  IF v_status NOT IN ('DRAFT', 'RELEASED') THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن تعديل طلبية مغلقة أو ملغاة'); END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p -> 'lines') LOOP
    v_line := factory.j_uuid(l, 'lineId', true, 'السطر');
    v_qty := factory.j_int(l, 'plannedQty', 1, 1000000, 'الكمية');
    SELECT id, color, size, planned_qty INTO r FROM factory.order_lines WHERE id = v_line AND order_id = p_order FOR UPDATE;
    IF r.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'السطر لا يخص هذه الطلبية'); END IF;
    CONTINUE WHEN r.planned_qty = v_qty;
    SELECT coalesce(sum(created_qty), 0) INTO v_cut FROM factory.cut_lots WHERE order_line_id = v_line AND NOT is_replacement;
    IF v_qty < v_cut THEN
      PERFORM factory.err('BUSINESS_RULE', format('%s / %s: لا يمكن أن تقل الكمية عن المقصوص فعلاً (%s)', r.color, r.size, v_cut));
    END IF;
    UPDATE factory.order_lines SET planned_qty = v_qty WHERE id = v_line;
    v_changes := v_changes || jsonb_build_object('color', r.color, 'size', r.size, 'before', r.planned_qty, 'after', v_qty);
  END LOOP;
  IF jsonb_array_length(v_changes) > 0 THEN
    PERFORM factory.audit(a.employee_id, 'order.quantities', 'order', p_order::text, NULL, jsonb_build_object('changes', v_changes));
  END IF;
  RETURN jsonb_build_object('ok', true, 'changed', jsonb_array_length(v_changes));
END $$;

-- ---------------------------------------------------------------- moving pieces: next stage, or previous stage with a reason
CREATE FUNCTION factory.dispatch_core(a factory.actor_t, p_key uuid, p_lot uuid, p_from uuid, p_to_dept uuid, p_to_emp uuid,
                                      p_cond text, p_qty int, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  f record; td record; v_dir factory.transfer_direction; v_diff int; v_order_status text;
  v_to uuid; v_code text; v_tr uuid; v_transit uuid; v_event uuid;
BEGIN
  IF p_cond NOT IN ('GOOD', 'DEFECTIVE') THEN PERFORM factory.err('INVALID', 'حالة القطع غير صالحة'); END IF;
  PERFORM factory.assert(factory.can_operate(a, p_from), 'لا يمكنك الإرسال من هذه العهدة');
  SELECT c.id, c.department_id, d.stage, d.active, d.allow_return, d.name_ar INTO f
    FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id WHERE c.id = p_from;
  IF f.stage IS NULL OR NOT f.active THEN PERFORM factory.err('BUSINESS_RULE', 'عهدة المصدر ليست في مرحلة إنتاج فعّالة'); END IF;
  SELECT id, stage, active INTO td FROM factory.departments WHERE id = p_to_dept;
  IF td.id IS NULL OR NOT td.active OR td.stage IS NULL THEN PERFORM factory.err('NOT_FOUND', 'القسم المستلم غير موجود أو غير مفعّل'); END IF;

  v_diff := factory.stage_rank(td.stage) - factory.stage_rank(f.stage);
  IF v_diff = 1 THEN v_dir := 'FORWARD';
  ELSIF v_diff = -1 THEN v_dir := 'RETURN';
  ELSIF v_diff = 0 THEN PERFORM factory.err('BUSINESS_RULE', 'القطع تمرّ للمرحلة التالية أو تُرجع للسابقة، ولا تُحوّل داخل نفس المرحلة');
  ELSIF v_diff > 1 THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن تخطي مراحل الإنتاج؛ أرسل للمرحلة التالية مباشرة');
  ELSE PERFORM factory.err('BUSINESS_RULE', 'الإرجاع يكون للمرحلة السابقة مباشرة فقط');
  END IF;
  IF p_cond = 'DEFECTIVE' AND v_dir = 'FORWARD' THEN PERFORM factory.err('BUSINESS_RULE', 'القطع المعيبة لا تُرسل للمرحلة التالية قبل إصلاحها'); END IF;
  IF v_dir = 'RETURN' THEN
    IF NOT f.allow_return THEN PERFORM factory.err('BUSINESS_RULE', format('الإرجاع من «%s» موقوف بقرار مدير النظام', f.name_ar)); END IF;
    IF p_reason IS NULL THEN PERFORM factory.err('BUSINESS_RULE', 'اذكر سبب الإرجاع'); END IF;
  END IF;

  SELECT o.status::text INTO v_order_status FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id
    JOIN factory.orders o ON o.id = ol.order_id WHERE l.id = p_lot;
  IF v_order_status IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الدفعة غير موجودة'); END IF;
  IF v_order_status <> 'RELEASED' THEN PERFORM factory.err('BUSINESS_RULE', 'الطلبية ليست قيد الإنتاج'); END IF;

  v_to := factory.receiving_custody(p_to_dept, p_to_emp);
  IF v_to = p_from THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن الإرسال إلى نفس العهدة'); END IF;

  v_code := factory.make_code('TR');
  INSERT INTO factory.transfers (transfer_code, lot_id, condition, from_custody_id, to_custody_id, from_department_id,
    to_department_id, direction, dispatched_qty, pending_qty, reason, created_by)
  VALUES (v_code, p_lot, p_cond::factory.stock_condition, p_from, v_to, f.department_id, p_to_dept, v_dir, p_qty, p_qty, p_reason, a.employee_id)
  RETURNING id INTO v_tr;
  v_transit := factory.holding(v_tr, 'TRANSIT');
  v_event := factory.post_event('DISPATCH', p_lot, p_qty, a.employee_id, f.department_id, v_tr, NULL, NULL, NULL, p_reason,
    jsonb_build_array(jsonb_build_object('custody', p_from, 'condition', p_cond, 'delta', -p_qty),
                      jsonb_build_object('custody', v_transit, 'condition', p_cond, 'delta', p_qty)));
  INSERT INTO factory.transfer_events (transfer_id, kind, qty, actor_employee_id, stock_event_id, reason)
  VALUES (v_tr, 'DISPATCH', p_qty, a.employee_id, v_event, p_reason);
  PERFORM factory.audit(a.employee_id, 'transfer.dispatch', 'transfer', v_tr::text, p_key::text,
    jsonb_build_object('code', v_code, 'direction', v_dir, 'quantity', p_qty, 'condition', p_cond, 'toEmployee', p_to_emp));
  RETURN jsonb_build_object('transferId', v_tr, 'transferCode', v_code, 'direction', v_dir, 'quantity', p_qty);
END $$;

CREATE OR REPLACE FUNCTION public.app_dispatch(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_lot uuid := factory.j_uuid(p, 'lotId', true, 'الدفعة');
  v_from uuid := factory.j_uuid(p, 'fromCustodyId', true, 'عهدة المصدر');
  v_to_dept uuid := factory.j_uuid(p, 'toDepartmentId', true, 'القسم المستلم');
  v_to_emp uuid := factory.j_uuid(p, 'toEmployeeId', false, 'العامل المستلم');
  v_cond text := factory.j_text(p, 'condition', 1, 20, true, 'الحالة');
  v_qty int := factory.j_int(p, 'quantity', 1, 1000000, 'الكمية');
  v_reason text := factory.j_text(p, 'reason', 1, 500, false, 'السبب');
  v_prev jsonb; r jsonb;
BEGIN
  PERFORM factory.assert(factory.can_operate(a, v_from), 'لا يمكنك الإرسال من هذه العهدة');
  v_prev := factory.idem_begin(a.employee_id, 'transfer.dispatch', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  r := factory.dispatch_core(a, v_key, v_lot, v_from, v_to_dept, v_to_emp, v_cond, v_qty, v_reason);
  RETURN factory.idem_finish(a.employee_id, 'transfer.dispatch', v_key, r || jsonb_build_object('state', 'DISPATCHED'));
END $$;

/**
 * Several moves in ONE step, all or nothing: the cutter distributing a whole order to several
 * tailors, or a department passing a whole order to the next stage.
 * items: [{lotId, fromCustodyId, toDepartmentId, toEmployeeId?, condition?, quantity, reason?}]
 */
CREATE FUNCTION public.app_dispatch_batch(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_prev jsonb; i jsonb; v_lot uuid; v_from uuid; v_dept uuid; v_emp uuid; v_cond text; v_qty int; v_reason text;
  v_seen text[] := '{}'; v_sig text; v_out jsonb := '[]'::jsonb; v_total int := 0; v_workers uuid[] := '{}';
BEGIN
  IF jsonb_typeof(p -> 'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'items') NOT BETWEEN 1 AND 500 THEN
    PERFORM factory.err('INVALID', 'لا توجد كميات للإرسال');
  END IF;
  v_prev := factory.idem_begin(a.employee_id, 'transfer.batch', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  FOR i IN SELECT * FROM jsonb_array_elements(p -> 'items') LOOP
    v_lot := factory.j_uuid(i, 'lotId', true, 'الدفعة');
    v_from := factory.j_uuid(i, 'fromCustodyId', true, 'عهدة المصدر');
    v_dept := factory.j_uuid(i, 'toDepartmentId', true, 'القسم المستلم');
    v_emp := factory.j_uuid(i, 'toEmployeeId', false, 'العامل المستلم');
    v_cond := coalesce(factory.j_text(i, 'condition', 1, 20, false, 'الحالة'), 'GOOD');
    v_qty := factory.j_int(i, 'quantity', 1, 1000000, 'الكمية');
    v_reason := factory.j_text(i, 'reason', 1, 500, false, 'السبب');
    v_sig := concat_ws('|', v_lot, v_from, v_dept, v_emp, v_cond);
    IF v_sig = ANY (v_seen) THEN PERFORM factory.err('INVALID', 'سطر مكرر في الإرسال'); END IF;
    v_seen := v_seen || v_sig;
    v_out := v_out || factory.dispatch_core(a, v_key, v_lot, v_from, v_dept, v_emp, v_cond, v_qty, v_reason);
    v_total := v_total + v_qty;
    IF v_emp IS NOT NULL AND NOT v_emp = ANY (v_workers) THEN v_workers := v_workers || v_emp; END IF;
  END LOOP;
  RETURN factory.idem_finish(a.employee_id, 'transfer.batch', v_key,
    jsonb_build_object('transfers', jsonb_array_length(v_out), 'workers', cardinality(v_workers), 'quantity', v_total));
END $$;

-- ---------------------------------------------------------------- cutter's task list: orders sent to cutting
CREATE OR REPLACE FUNCTION public.app_cutting_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  PERFORM factory.assert(factory.in_stage(a, 'CUTTING'), 'مهام القص لأعضاء قسم القص');
  RETURN jsonb_build_object(
    'depts', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name_ar)), '[]'::jsonb)
                FROM factory.departments d WHERE d.id = ANY (a.dept_ids) AND d.stage = 'CUTTING'),
    'orders', (SELECT coalesce(jsonb_agg(x ORDER BY x->>'due_date', x->>'order_code'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('id', o.id, 'order_code', o.order_code, 'product_name', o.product_name, 'model_code', o.model_code,
          'customer_name', cu.display_name, 'due_date', o.due_date, 'notes', o.notes, 'released_at', o.released_at,
          'lines', (SELECT jsonb_agg(jsonb_build_object('id', ol.id, 'color', ol.color, 'size', ol.size, 'planned_qty', ol.planned_qty,
                      'cut_qty', coalesce((SELECT sum(created_qty) FROM factory.cut_lots l WHERE l.order_line_id = ol.id AND NOT l.is_replacement), 0))
                      ORDER BY ol.position, ol.color, ol.size)
                      FROM factory.order_lines ol WHERE ol.order_id = o.id)) AS x
          FROM factory.orders o JOIN factory.customers cu ON cu.id = o.customer_id
         WHERE o.status = 'RELEASED'
           AND EXISTS (SELECT 1 FROM factory.order_lines ol WHERE ol.order_id = o.id
                        AND ol.planned_qty > coalesce((SELECT sum(created_qty) FROM factory.cut_lots l WHERE l.order_line_id = ol.id AND NOT l.is_replacement), 0))) q),
    'replacements', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', dp.id, 'replacement_qty', dp.replacement_qty,
          'reason', dp.reason, 'defect_code', df.defect_code, 'order_line_id', ol.id, 'order_code', o.order_code,
          'color', ol.color, 'size', ol.size) ORDER BY dp.approved_at), '[]'::jsonb)
        FROM factory.dispositions dp JOIN factory.defects df ON df.id = dp.defect_id
        JOIN factory.cut_lots l ON l.id = df.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
        JOIN factory.orders o ON o.id = ol.order_id
       WHERE dp.decision = 'REPLACE' AND o.status = 'RELEASED'
         AND NOT EXISTS (SELECT 1 FROM factory.cut_lots x WHERE x.replacement_disposition_id = dp.id)));
END $$;

-- ---------------------------------------------------------------- my stock: targets carry the return permission
CREATE OR REPLACE FUNCTION public.app_my_stock() RETURNS jsonb
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
                   'rank', factory.stage_rank(d.stage), 'mode', d.custody_mode, 'allow_return', d.allow_return,
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

-- ---------------------------------------------------------------- views that list lines follow the typed order
CREATE OR REPLACE FUNCTION factory.stock_lines(p_custodies uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'custody_id', b.custody_id, 'custody_label', factory.custody_label(b.custody_id), 'department_id', c.department_id,
           'stage', d.stage, 'lot_id', l.id, 'lot_code', l.lot_code, 'order_id', o.id, 'order_code', o.order_code,
           'product_name', o.product_name, 'color', ol.color, 'size', ol.size, 'condition', b.condition, 'qty', b.qty,
           'due_date', o.due_date) ORDER BY o.due_date, o.order_code, ol.position, ol.color, ol.size, b.condition), '[]'::jsonb)
    FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
    JOIN factory.departments d ON d.id = c.department_id
    JOIN factory.cut_lots l ON l.id = b.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
    JOIN factory.orders o ON o.id = ol.order_id
   WHERE b.custody_id = ANY (p_custodies) AND b.qty > 0
$$;

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

-- ---------------------------------------------------------------- administration: departments carry allow_return
CREATE OR REPLACE FUNCTION public.app_create_department(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_code text := upper(factory.j_text(p, 'code', 2, 32, true, 'رمز القسم'));
  v_name text := factory.j_text(p, 'nameAr', 1, 100, true, 'اسم القسم');
  v_stage text := factory.j_text(p, 'stage', 1, 20, false, 'المرحلة');
  v_mode text := factory.j_text(p, 'custodyMode', 1, 20, true, 'نوع العهدة');
  v_return boolean := coalesce(CASE WHEN jsonb_typeof(p -> 'allowReturn') = 'boolean' THEN (p ->> 'allowReturn')::boolean END, true);
  v_id uuid;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  IF v_code !~ '^[A-Z0-9_]{2,32}$' THEN PERFORM factory.err('INVALID', 'رمز القسم: أحرف لاتينية كبيرة وأرقام'); END IF;
  IF v_stage IS NOT NULL AND v_stage NOT IN ('CUTTING','SEWING','FINISHING_1','IRONING','FINISHING_2','WAREHOUSE') THEN
    PERFORM factory.err('INVALID', 'مرحلة غير صالحة');
  END IF;
  IF v_mode NOT IN ('SHARED', 'INDIVIDUAL') THEN PERFORM factory.err('INVALID', 'نوع عهدة غير صالح'); END IF;
  IF EXISTS (SELECT 1 FROM factory.departments WHERE code = v_code) THEN PERFORM factory.err('CONFLICT', 'رمز القسم مستخدم مسبقاً'); END IF;
  INSERT INTO factory.departments (code, name_ar, stage, custody_mode, allow_return)
  VALUES (v_code, v_name, v_stage::factory.stage, v_mode::factory.custody_mode, v_return) RETURNING id INTO v_id;
  PERFORM factory.dept_custody(v_id);
  PERFORM factory.audit(a.employee_id, 'department.create', 'department', v_id::text, NULL, p);
  RETURN jsonb_build_object('id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.app_update_department(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_name text := factory.j_text(p, 'nameAr', 1, 100, false, 'اسم القسم');
  v_mode text := factory.j_text(p, 'custodyMode', 1, 20, false, 'نوع العهدة');
  v_active boolean := CASE WHEN jsonb_typeof(p -> 'active') = 'boolean' THEN (p ->> 'active')::boolean END;
  v_return boolean := CASE WHEN jsonb_typeof(p -> 'allowReturn') = 'boolean' THEN (p ->> 'allowReturn')::boolean END;
  d record; v_stock int;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  IF v_mode IS NOT NULL AND v_mode NOT IN ('SHARED', 'INDIVIDUAL') THEN PERFORM factory.err('INVALID', 'نوع عهدة غير صالح'); END IF;
  SELECT * INTO d FROM factory.departments WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'القسم غير موجود'); END IF;
  IF (v_mode IS NOT NULL AND v_mode <> d.custody_mode::text) OR (v_active IS FALSE AND d.active) THEN
    SELECT coalesce(sum(b.qty), 0) INTO v_stock FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id WHERE c.department_id = p_id;
    IF v_stock > 0 THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن تغيير نوع العهدة أو إيقاف القسم وفيه قطع؛ انقل القطع أولاً'); END IF;
    IF EXISTS (SELECT 1 FROM factory.transfers WHERE (from_department_id = p_id OR to_department_id = p_id) AND pending_qty + disputed_qty > 0) THEN
      PERFORM factory.err('BUSINESS_RULE', 'يوجد تحويلات مفتوحة لهذا القسم؛ أغلقها أولاً');
    END IF;
  END IF;
  UPDATE factory.departments SET name_ar = coalesce(v_name, name_ar), custody_mode = coalesce(v_mode::factory.custody_mode, custody_mode),
         active = coalesce(v_active, active), allow_return = coalesce(v_return, allow_return) WHERE id = p_id;
  PERFORM factory.audit(a.employee_id, 'department.update', 'department', p_id::text, NULL,
    jsonb_build_object('before', jsonb_build_object('name_ar', d.name_ar, 'custody_mode', d.custody_mode, 'active', d.active,
                                                    'allow_return', d.allow_return), 'after', p));
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.app_admin_view() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(false);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  RETURN jsonb_build_object(
    'self_id', a.employee_id,
    'employees', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'username', e.username, 'display_name', e.display_name,
        'active', e.active, 'must_change_password', e.must_change_password,
        'temp_expires_at', CASE WHEN e.must_change_password THEN e.temp_password_expires_at END,
        'temp_expired', e.must_change_password AND e.temp_password_expires_at < now(),
        'open_tasks', (SELECT count(*) FROM factory.work_assignments w WHERE w.employee_id = e.id AND w.status IN ('ASSIGNED', 'IN_PROGRESS')),
        'roles', (SELECT coalesce(jsonb_agg(jsonb_build_object('role', r.role, 'department_id', r.department_id, 'department_name', d.name_ar)
                    ORDER BY r.role, d.code), '[]'::jsonb)
                    FROM factory.employee_roles r LEFT JOIN factory.departments d ON d.id = r.department_id
                   WHERE r.employee_id = e.id AND r.active)) ORDER BY e.active DESC, e.display_name), '[]'::jsonb)
      FROM factory.employees e),
    'departments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name_ar', d.name_ar, 'stage', d.stage,
        'custody_mode', d.custody_mode, 'active', d.active, 'allow_return', d.allow_return,
        'member_count', (SELECT count(*) FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
                          WHERE r.department_id = d.id AND r.active AND e.active)) ORDER BY factory.stage_rank(d.stage) NULLS LAST, d.code), '[]'::jsonb)
      FROM factory.departments d));
END $$;

-- ---------------------------------------------------------------- permissions (same model as 005)
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM PUBLIC;
DO $$
DECLARE f record; has_roles boolean := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated');
BEGIN
  IF has_roles THEN
    REVOKE ALL ON factory.code_counters FROM anon, authenticated;
    EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM anon, authenticated';
  END IF;
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
