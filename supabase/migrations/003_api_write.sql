-- 003_api_write.sql — mutation API (schema public, called via supabase.rpc()).
-- Every function: SECURITY DEFINER with empty search_path, resolves the caller from the JWT,
-- checks permissions server-side, validates input, and runs in one transaction.
-- Grants are applied at the end: EXECUTE only for `authenticated`, never anon/PUBLIC.

-- ================================================================ orders
CREATE FUNCTION public.app_create_order(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_code text; v_customer text; v_contact text; v_product text; v_model text; v_due date; v_notes text;
  v_cust uuid; v_order uuid; l jsonb; v_seen text[] := '{}'; v_key text;
  v_color text; v_size text; v_qty int;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR'), 'إنشاء الطلبات من صلاحية المشرف');
  v_code := factory.j_text(p, 'orderCode', 2, 40, true, 'رقم الطلب');
  IF v_code !~ '^[A-Za-z0-9_-]{2,40}$' THEN PERFORM factory.err('INVALID', 'رقم الطلب: أحرف لاتينية وأرقام و - _ فقط'); END IF;
  v_customer := factory.j_text(p, 'customerName', 1, 150, true, 'الزبون');
  v_contact := factory.j_text(p, 'customerContact', 1, 200, false, 'تواصل الزبون');
  v_product := factory.j_text(p, 'productName', 1, 150, true, 'المنتج');
  v_model := factory.j_text(p, 'modelCode', 1, 60, false, 'رمز الموديل');
  v_due := factory.j_date(p, 'dueDate', 'تاريخ التسليم');
  v_notes := factory.j_text(p, 'notes', 1, 2000, false, 'الملاحظات');
  IF jsonb_typeof(p -> 'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'lines') NOT BETWEEN 1 AND 200 THEN
    PERFORM factory.err('INVALID', 'أضف سطراً واحداً على الأقل (200 كحد أقصى)');
  END IF;
  IF EXISTS (SELECT 1 FROM factory.orders WHERE lower(order_code) = lower(v_code)) THEN
    PERFORM factory.err('CONFLICT', 'رقم الطلب مستخدم مسبقاً');
  END IF;

  INSERT INTO factory.customers (display_name, contact) VALUES (v_customer, v_contact)
  ON CONFLICT (display_name) DO UPDATE SET contact = coalesce(EXCLUDED.contact, factory.customers.contact);
  SELECT id INTO v_cust FROM factory.customers WHERE display_name = v_customer;
  INSERT INTO factory.orders (order_code, customer_id, product_name, model_code, due_date, notes, created_by)
  VALUES (v_code, v_cust, v_product, v_model, v_due, v_notes, a.employee_id) RETURNING id INTO v_order;

  FOR l IN SELECT * FROM jsonb_array_elements(p -> 'lines') LOOP
    v_color := factory.j_text(l, 'color', 1, 50, true, 'اللون');
    v_size := factory.j_text(l, 'size', 1, 20, true, 'المقاس');
    v_qty := factory.j_int(l, 'plannedQty', 1, 1000000, 'الكمية');
    v_key := lower(v_color) || '|' || lower(v_size);
    IF v_key = ANY (v_seen) THEN PERFORM factory.err('INVALID', 'يوجد لون ومقاس مكرر في الطلب'); END IF;
    v_seen := v_seen || v_key;
    INSERT INTO factory.order_lines (order_id, color, size, planned_qty) VALUES (v_order, v_color, v_size, v_qty);
  END LOOP;

  PERFORM factory.audit(a.employee_id, 'order.create', 'order', v_order::text, NULL,
    jsonb_build_object('orderCode', v_code, 'dueDate', v_due, 'lines', p -> 'lines'));
  RETURN jsonb_build_object('id', v_order);
END $$;

CREATE FUNCTION factory.set_order_status(a factory.actor_t, p_id uuid, p_from text[], p_to factory.order_status) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_status text; v_left int;
BEGIN
  SELECT status::text INTO v_status FROM factory.orders WHERE id = p_id FOR UPDATE;
  IF v_status IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الطلب غير موجود'); END IF;
  IF NOT v_status = ANY (p_from) THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية'); END IF;
  IF p_to = 'CLOSED' THEN
    SELECT coalesce(sum(b.qty), 0) INTO v_left FROM factory.stock_balances b
      JOIN factory.cut_lots l ON l.id = b.lot_id JOIN factory.order_lines ol ON ol.id = l.order_line_id
     WHERE ol.order_id = p_id;
    IF v_left > 0 THEN PERFORM factory.err('BUSINESS_RULE', format('لا يمكن إغلاق الطلب: ما زالت %s قطعة في الإنتاج أو المخزن', v_left)); END IF;
  END IF;
  UPDATE factory.orders SET status = p_to,
         released_at = CASE WHEN p_to = 'RELEASED' THEN now() ELSE released_at END,
         released_by = CASE WHEN p_to = 'RELEASED' THEN a.employee_id ELSE released_by END,
         closed_at = CASE WHEN p_to IN ('CLOSED', 'CANCELLED') THEN now() ELSE closed_at END
   WHERE id = p_id;
  PERFORM factory.audit(a.employee_id, 'order.' || lower(p_to::text), 'order', p_id::text, NULL, jsonb_build_object('from', v_status));
END $$;

CREATE FUNCTION public.app_release_order(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(true);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR'), 'إطلاق الطلب للقص من صلاحية المشرف');
  PERFORM factory.set_order_status(a, p_id, ARRAY['DRAFT'], 'RELEASED');
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE FUNCTION public.app_cancel_order(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(true);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR'));
  PERFORM factory.set_order_status(a, p_id, ARRAY['DRAFT'], 'CANCELLED');
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE FUNCTION public.app_close_order(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(true);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR'));
  PERFORM factory.set_order_status(a, p_id, ARRAY['RELEASED'], 'CLOSED');
  RETURN jsonb_build_object('ok', true);
END $$;

-- ================================================================ cutting
CREATE FUNCTION public.app_create_cut_lot(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_prev jsonb;
  v_line_id uuid := factory.j_uuid(p, 'orderLineId', true, 'سطر الطلب');
  v_qty int := factory.j_int(p, 'quantity', 1, 1000000, 'الكمية');
  v_dept uuid := factory.j_uuid(p, 'cuttingDepartmentId', true, 'قسم القص');
  v_disp_id uuid := factory.j_uuid(p, 'replacementDispositionId', false, 'قرار الاستبدال');
  v_notes text := factory.j_text(p, 'notes', 1, 500, false, 'الملاحظة');
  d record; ln record; disp record; v_cut int; v_custody uuid; v_seq int; v_code text; v_lot uuid;
BEGIN
  PERFORM factory.assert(factory.in_stage(a, 'CUTTING'), 'تسجيل القص من صلاحية قسم القص');
  SELECT id, stage, custody_mode INTO d FROM factory.departments WHERE id = v_dept AND active;
  PERFORM factory.assert(d.id IS NOT NULL AND d.stage = 'CUTTING' AND v_dept = ANY (a.dept_ids), 'لست عضواً في قسم القص المحدد');
  v_prev := factory.idem_begin(a.employee_id, 'cut_lot', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;

  SELECT ol.id, ol.planned_qty, ol.order_id, o.status, o.order_code INTO ln
    FROM factory.order_lines ol JOIN factory.orders o ON o.id = ol.order_id WHERE ol.id = v_line_id;
  IF ln.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'سطر الطلب غير موجود'); END IF;
  PERFORM 1 FROM factory.orders WHERE id = ln.order_id FOR UPDATE;
  PERFORM 1 FROM factory.order_lines WHERE id = ln.id FOR UPDATE;
  IF ln.status <> 'RELEASED' THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن القص قبل إطلاق الطلب من المشرف'); END IF;

  IF v_disp_id IS NOT NULL THEN
    SELECT dp.id, dp.decision, dp.replacement_qty, l.order_line_id,
           EXISTS (SELECT 1 FROM factory.cut_lots x WHERE x.replacement_disposition_id = dp.id) AS used
      INTO disp
      FROM factory.dispositions dp JOIN factory.defects df ON df.id = dp.defect_id
      JOIN factory.cut_lots l ON l.id = df.lot_id
     WHERE dp.id = v_disp_id FOR UPDATE OF dp;
    IF disp.id IS NULL OR disp.decision <> 'REPLACE' THEN PERFORM factory.err('BUSINESS_RULE', 'لا يوجد قرار استبدال معتمد بهذا الرقم'); END IF;
    IF disp.used THEN PERFORM factory.err('BUSINESS_RULE', 'تم قص البديل لهذا القرار سابقاً'); END IF;
    IF disp.order_line_id <> ln.id THEN PERFORM factory.err('BUSINESS_RULE', 'قرار الاستبدال يخص سطر طلب آخر'); END IF;
    IF disp.replacement_qty <> v_qty THEN PERFORM factory.err('BUSINESS_RULE', format('كمية القص البديل يجب أن تساوي %s', disp.replacement_qty)); END IF;
  ELSE
    SELECT coalesce(sum(created_qty), 0) INTO v_cut FROM factory.cut_lots WHERE order_line_id = ln.id AND NOT is_replacement;
    IF v_qty > ln.planned_qty - v_cut THEN
      PERFORM factory.err('BUSINESS_RULE', format('الكمية تتجاوز المسموح بقصه لهذا السطر (المتبقي %s)', ln.planned_qty - v_cut));
    END IF;
  END IF;

  v_custody := CASE WHEN d.custody_mode = 'SHARED' THEN factory.dept_custody(v_dept) ELSE factory.emp_custody(v_dept, a.employee_id) END;
  SELECT count(*) + 1 INTO v_seq FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id WHERE ol.order_id = ln.order_id;
  v_code := ln.order_code || '-L' || lpad(v_seq::text, 3, '0');
  INSERT INTO factory.cut_lots (lot_code, order_line_id, created_qty, is_replacement, replacement_disposition_id, initial_custody_id, created_by, notes)
  VALUES (v_code, ln.id, v_qty, v_disp_id IS NOT NULL, v_disp_id, v_custody, a.employee_id, v_notes) RETURNING id INTO v_lot;
  PERFORM factory.post_event('CUT', v_lot, v_qty, a.employee_id, v_dept, NULL, NULL, NULL, NULL,
    CASE WHEN v_disp_id IS NOT NULL THEN 'قص بديل لقطع متلفة' END,
    jsonb_build_array(jsonb_build_object('custody', v_custody, 'condition', 'GOOD', 'delta', v_qty)));
  PERFORM factory.audit(a.employee_id, CASE WHEN v_disp_id IS NULL THEN 'cut.create' ELSE 'cut.replacement' END,
    'cut_lot', v_lot::text, v_key::text, jsonb_build_object('lotCode', v_code, 'quantity', v_qty, 'dispositionId', v_disp_id));
  RETURN factory.idem_finish(a.employee_id, 'cut_lot', v_key, jsonb_build_object('lotId', v_lot, 'lotCode', v_code, 'quantity', v_qty));
END $$;

-- ================================================================ work assignments (annotations only)
CREATE FUNCTION public.app_create_assignments(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_line uuid := factory.j_uuid(p, 'orderLineId', true, 'سطر الطلب');
  v_lot uuid := factory.j_uuid(p, 'lotId', false, 'الدفعة');
  v_dept uuid := factory.j_uuid(p, 'departmentId', true, 'القسم');
  v_qty int := factory.j_int(p, 'quantity', 1, 1000000, 'الكمية');
  v_notes text := factory.j_text(p, 'notes', 1, 500, false, 'الملاحظات');
  v_emps uuid[]; v_status text; v_ok int; v_ids uuid[] := '{}'; v_id uuid; e uuid;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR') OR factory.in_stage(a, 'CUTTING'), 'توزيع العمل من صلاحية المشرف أو قسم القص');
  IF jsonb_typeof(p -> 'employeeIds') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'employeeIds') NOT BETWEEN 1 AND 20 THEN
    PERFORM factory.err('INVALID', 'اختر عاملاً واحداً على الأقل');
  END IF;
  -- de-duplicate while keeping the order sent by the client (returned ids follow that order)
  SELECT array_agg(x ORDER BY ord) INTO v_emps FROM (
    SELECT DISTINCT ON (v.x) v.x, v.ord
      FROM (SELECT factory.j_uuid(jsonb_build_object('v', t.elem), 'v', true, 'الموظف') AS x, t.ord AS ord
              FROM jsonb_array_elements_text(p -> 'employeeIds') WITH ORDINALITY AS t(elem, ord)) v
     ORDER BY v.x, v.ord) s;
  SELECT o.status::text INTO v_status FROM factory.order_lines ol JOIN factory.orders o ON o.id = ol.order_id WHERE ol.id = v_line;
  IF v_status IS NULL THEN PERFORM factory.err('NOT_FOUND', 'سطر الطلب غير موجود'); END IF;
  IF v_status <> 'RELEASED' THEN PERFORM factory.err('BUSINESS_RULE', 'يمكن توزيع العمل على الطلبات المطلقة فقط'); END IF;
  IF v_lot IS NOT NULL AND NOT EXISTS (SELECT 1 FROM factory.cut_lots WHERE id = v_lot AND order_line_id = v_line) THEN
    PERFORM factory.err('BUSINESS_RULE', 'الدفعة لا تخص سطر الطلب المحدد');
  END IF;
  SELECT count(*) INTO v_ok FROM factory.employee_roles r JOIN factory.employees em ON em.id = r.employee_id
   WHERE r.department_id = v_dept AND r.role = 'WORKER' AND r.active AND em.active AND r.employee_id = ANY (v_emps);
  IF v_ok <> array_length(v_emps, 1) THEN PERFORM factory.err('BUSINESS_RULE', 'أحد الموظفين ليس عضواً فعّالاً في القسم المحدد'); END IF;
  FOREACH e IN ARRAY v_emps LOOP
    INSERT INTO factory.work_assignments (order_line_id, lot_id, department_id, employee_id, assigned_qty, notes, assigned_by)
    VALUES (v_line, v_lot, v_dept, e, v_qty, v_notes, a.employee_id) RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
  END LOOP;
  PERFORM factory.audit(a.employee_id, 'assignment.create', 'order_line', v_line::text, NULL,
    jsonb_build_object('employees', v_emps, 'quantity', v_qty, 'shared', array_length(v_emps, 1) > 1));
  RETURN jsonb_build_object('ids', to_jsonb(v_ids));
END $$;

CREATE FUNCTION public.app_update_assignment(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_done int := factory.j_int(p, 'completedQty', 0, 1000000, 'الكمية المنجزة');
  v_status text := factory.j_text(p, 'status', 1, 20, true, 'الحالة');
  w record;
BEGIN
  IF v_status NOT IN ('ASSIGNED', 'IN_PROGRESS', 'DONE', 'CANCELLED') THEN PERFORM factory.err('INVALID', 'حالة غير صالحة'); END IF;
  SELECT * INTO w FROM factory.work_assignments WHERE id = p_id FOR UPDATE;
  IF w.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'المهمة غير موجودة'); END IF;
  PERFORM factory.assert(w.employee_id = a.employee_id OR factory.has_role(a, 'SUPERVISOR') OR w.assigned_by = a.employee_id,
    'لا يمكنك تعديل مهمة موظف آخر');
  IF v_status = 'CANCELLED' AND w.employee_id = a.employee_id AND NOT factory.has_role(a, 'SUPERVISOR') THEN
    PERFORM factory.err('BUSINESS_RULE', 'إلغاء المهمة من صلاحية المشرف');
  END IF;
  IF v_done > w.assigned_qty THEN PERFORM factory.err('BUSINESS_RULE', 'الكمية المنجزة أكبر من الكمية المسندة'); END IF;
  UPDATE factory.work_assignments SET completed_qty = v_done, status = v_status::factory.assignment_status, updated_at = now() WHERE id = p_id;
  PERFORM factory.audit(a.employee_id, 'assignment.progress', 'work_assignment', p_id::text, NULL,
    jsonb_build_object('before', jsonb_build_object('completed', w.completed_qty, 'status', w.status), 'after', p));
  RETURN jsonb_build_object('ok', true);
END $$;

-- ================================================================ transfers
CREATE FUNCTION public.app_dispatch(p jsonb) RETURNS jsonb
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
  v_prev jsonb; f record; td record; v_dir factory.transfer_direction; v_diff int;
  v_order_status text; v_to uuid; v_code text; v_tr uuid; v_transit uuid; v_event uuid;
BEGIN
  IF v_cond NOT IN ('GOOD', 'DEFECTIVE') THEN PERFORM factory.err('INVALID', 'حالة القطع غير صالحة'); END IF;
  PERFORM factory.assert(factory.can_operate(a, v_from), 'لا يمكنك الإرسال من هذه العهدة');
  v_prev := factory.idem_begin(a.employee_id, 'transfer.dispatch', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;

  SELECT c.id, c.department_id, d.stage, d.active INTO f
    FROM factory.custodies c JOIN factory.departments d ON d.id = c.department_id WHERE c.id = v_from;
  IF f.stage IS NULL OR NOT f.active THEN PERFORM factory.err('BUSINESS_RULE', 'عهدة المصدر ليست في مرحلة إنتاج فعّالة'); END IF;
  SELECT id, stage, active INTO td FROM factory.departments WHERE id = v_to_dept;
  IF td.id IS NULL OR NOT td.active OR td.stage IS NULL THEN PERFORM factory.err('NOT_FOUND', 'القسم المستلم غير موجود أو غير مفعّل'); END IF;

  v_diff := factory.stage_rank(td.stage) - factory.stage_rank(f.stage);
  v_dir := CASE WHEN v_diff = 0 THEN 'INTERNAL' WHEN v_diff = 1 THEN 'FORWARD' WHEN v_diff < 0 THEN 'RETURN' END;
  IF v_dir IS NULL THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن تخطي مراحل الإنتاج؛ أرسل للمرحلة التالية مباشرة'); END IF;
  IF v_cond = 'DEFECTIVE' AND v_dir = 'FORWARD' THEN PERFORM factory.err('BUSINESS_RULE', 'القطع المعيبة لا تُرسل للمرحلة التالية قبل إصلاحها'); END IF;
  IF v_dir = 'RETURN' AND v_reason IS NULL THEN PERFORM factory.err('BUSINESS_RULE', 'اذكر سبب الإرجاع'); END IF;

  SELECT o.status::text INTO v_order_status FROM factory.cut_lots l JOIN factory.order_lines ol ON ol.id = l.order_line_id
    JOIN factory.orders o ON o.id = ol.order_id WHERE l.id = v_lot;
  IF v_order_status IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الدفعة غير موجودة'); END IF;
  IF v_order_status <> 'RELEASED' THEN PERFORM factory.err('BUSINESS_RULE', 'الطلب ليس قيد الإنتاج'); END IF;

  v_to := factory.receiving_custody(v_to_dept, v_to_emp);
  IF v_to = v_from THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن الإرسال إلى نفس العهدة'); END IF;

  v_code := factory.make_code('TR');
  INSERT INTO factory.transfers (transfer_code, lot_id, condition, from_custody_id, to_custody_id, from_department_id,
    to_department_id, direction, dispatched_qty, pending_qty, reason, created_by)
  VALUES (v_code, v_lot, v_cond::factory.stock_condition, v_from, v_to, f.department_id, v_to_dept, v_dir, v_qty, v_qty, v_reason, a.employee_id)
  RETURNING id INTO v_tr;
  v_transit := factory.holding(v_tr, 'TRANSIT');
  v_event := factory.post_event('DISPATCH', v_lot, v_qty, a.employee_id, f.department_id, v_tr, NULL, NULL, NULL, v_reason,
    jsonb_build_array(jsonb_build_object('custody', v_from, 'condition', v_cond, 'delta', -v_qty),
                      jsonb_build_object('custody', v_transit, 'condition', v_cond, 'delta', v_qty)));
  INSERT INTO factory.transfer_events (transfer_id, kind, qty, actor_employee_id, stock_event_id, reason)
  VALUES (v_tr, 'DISPATCH', v_qty, a.employee_id, v_event, v_reason);
  PERFORM factory.audit(a.employee_id, 'transfer.dispatch', 'transfer', v_tr::text, v_key::text,
    jsonb_build_object('code', v_code, 'direction', v_dir, 'quantity', v_qty, 'condition', v_cond));
  RETURN factory.idem_finish(a.employee_id, 'transfer.dispatch', v_key,
    jsonb_build_object('transferId', v_tr, 'transferCode', v_code, 'state', 'DISPATCHED', 'quantity', v_qty));
END $$;

CREATE FUNCTION public.app_receive(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_acc int := factory.j_int(p, 'acceptQty', 0, 1000000, 'المستلم');
  v_dis int := factory.j_int(p, 'disputeQty', 0, 1000000, 'المختلف عليه');
  v_rej int := factory.j_int(p, 'rejectQty', 0, 1000000, 'المرفوض');
  v_reason text := factory.j_text(p, 'reason', 1, 1000, false, 'السبب');
  v_prev jsonb; t record; v_to_dept uuid; v_transit uuid; v_dispute uuid; v_state factory.transfer_state;
BEGIN
  IF v_acc + v_dis + v_rej = 0 THEN PERFORM factory.err('INVALID', 'أدخل كمية واحدة على الأقل'); END IF;
  IF v_dis + v_rej > 0 AND v_reason IS NULL THEN PERFORM factory.err('INVALID', 'اذكر سبب الخلاف أو الرفض'); END IF;
  v_prev := factory.idem_begin(a.employee_id, 'transfer.receive', v_key, p || jsonb_build_object('transferId', p_id));
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;

  SELECT * INTO t FROM factory.transfers WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'التحويل غير موجود'); END IF;
  PERFORM factory.assert(factory.can_operate(a, t.to_custody_id), 'هذا التحويل ليس موجهاً إليك');
  IF v_acc + v_dis + v_rej > t.pending_qty THEN
    PERFORM factory.err('BUSINESS_RULE', format('الكمية المدخلة (%s) أكبر من الكمية بانتظار الاستلام (%s)', v_acc + v_dis + v_rej, t.pending_qty));
  END IF;
  SELECT department_id INTO v_to_dept FROM factory.custodies WHERE id = t.to_custody_id;
  v_transit := factory.holding(t.id, 'TRANSIT');
  PERFORM factory.move_holding(a.employee_id, t.id, t.lot_id, t.condition, 'ACCEPT', v_acc, v_transit, t.to_custody_id, v_to_dept, NULL);
  IF v_dis > 0 THEN
    v_dispute := factory.holding(t.id, 'DISPUTE');
    PERFORM factory.move_holding(a.employee_id, t.id, t.lot_id, t.condition, 'DISPUTE', v_dis, v_transit, v_dispute, v_to_dept, v_reason);
  END IF;
  PERFORM factory.move_holding(a.employee_id, t.id, t.lot_id, t.condition, 'REJECT_RETURN', v_rej, v_transit, t.from_custody_id, v_to_dept, v_reason);
  v_state := factory.save_transfer(t.id, t.accepted_qty + v_acc, t.returned_qty + v_rej, t.pending_qty - v_acc - v_dis - v_rej,
                                   t.disputed_qty + v_dis, t.written_off_qty);
  PERFORM factory.audit(a.employee_id, 'transfer.receive', 'transfer', t.id::text, v_key::text,
    jsonb_build_object('accept', v_acc, 'dispute', v_dis, 'reject', v_rej, 'reason', v_reason, 'state', v_state));
  RETURN factory.idem_finish(a.employee_id, 'transfer.receive', v_key,
    jsonb_build_object('transferId', t.id, 'transferCode', t.transfer_code, 'state', v_state, 'quantity', v_acc + v_dis + v_rej));
END $$;

CREATE FUNCTION public.app_resolve_dispute(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_acc int := factory.j_int(p, 'acceptQty', 0, 1000000, 'المستلم');
  v_ret int := factory.j_int(p, 'returnQty', 0, 1000000, 'المُرجع');
  v_reason text := factory.j_text(p, 'reason', 1, 1000, true, 'التوضيح');
  v_prev jsonb; t record; v_receiver boolean; v_sender boolean; v_dispute uuid; v_state factory.transfer_state;
  v_to_dept uuid; v_from_dept uuid;
BEGIN
  IF v_acc + v_ret = 0 THEN PERFORM factory.err('INVALID', 'أدخل كمية واحدة على الأقل'); END IF;
  v_prev := factory.idem_begin(a.employee_id, 'transfer.resolve', v_key, p || jsonb_build_object('transferId', p_id));
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  SELECT * INTO t FROM factory.transfers WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'التحويل غير موجود'); END IF;
  v_receiver := factory.can_operate(a, t.to_custody_id);
  v_sender := factory.can_operate(a, t.from_custody_id);
  PERFORM factory.assert(v_receiver OR factory.has_role(a, 'SUPERVISOR') OR (v_sender AND v_acc = 0), 'لا تملك صلاحية حل هذا الخلاف');
  IF v_acc + v_ret > t.disputed_qty THEN PERFORM factory.err('BUSINESS_RULE', format('الكمية أكبر من الكمية المختلف عليها (%s)', t.disputed_qty)); END IF;
  SELECT department_id INTO v_to_dept FROM factory.custodies WHERE id = t.to_custody_id;
  SELECT department_id INTO v_from_dept FROM factory.custodies WHERE id = t.from_custody_id;
  v_dispute := factory.holding(t.id, 'DISPUTE');
  PERFORM factory.move_holding(a.employee_id, t.id, t.lot_id, t.condition, 'DISPUTE_ACCEPT', v_acc, v_dispute, t.to_custody_id, v_to_dept, v_reason);
  PERFORM factory.move_holding(a.employee_id, t.id, t.lot_id, t.condition, 'DISPUTE_RETURN', v_ret, v_dispute, t.from_custody_id, v_from_dept, v_reason);
  v_state := factory.save_transfer(t.id, t.accepted_qty + v_acc, t.returned_qty + v_ret, t.pending_qty, t.disputed_qty - v_acc - v_ret, t.written_off_qty);
  PERFORM factory.audit(a.employee_id, 'transfer.resolve', 'transfer', t.id::text, v_key::text,
    jsonb_build_object('accept', v_acc, 'return', v_ret, 'reason', v_reason, 'state', v_state));
  RETURN factory.idem_finish(a.employee_id, 'transfer.resolve', v_key,
    jsonb_build_object('transferId', t.id, 'transferCode', t.transfer_code, 'state', v_state, 'quantity', v_acc + v_ret));
END $$;

-- ================================================================ quality
CREATE FUNCTION public.app_mark_defect(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_lot uuid := factory.j_uuid(p, 'lotId', true, 'الدفعة');
  v_custody uuid := factory.j_uuid(p, 'custodyId', true, 'العهدة');
  v_qty int := factory.j_int(p, 'quantity', 1, 1000000, 'الكمية');
  v_reason text := factory.j_text(p, 'reasonCode', 2, 32, true, 'سبب العيب');
  v_desc text := factory.j_text(p, 'description', 1, 1000, false, 'الوصف');
  v_resp uuid := factory.j_uuid(p, 'responsibleDepartmentId', false, 'القسم المسؤول');
  v_prev jsonb; v_dept uuid; v_code text; v_defect uuid;
BEGIN
  IF v_reason NOT IN ('CUTTING_ERROR','SEWING_ERROR','FABRIC_FLAW','STAIN','IRONING_DAMAGE','FINISHING_ERROR','MEASUREMENT','OTHER') THEN
    PERFORM factory.err('INVALID', 'سبب العيب غير معروف');
  END IF;
  PERFORM factory.assert(factory.can_operate(a, v_custody), 'لا يمكنك تسجيل عيب على قطع ليست في عهدتك');
  v_prev := factory.idem_begin(a.employee_id, 'defect.mark', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  SELECT department_id INTO v_dept FROM factory.custodies WHERE id = v_custody;
  v_code := factory.make_code('DF');
  INSERT INTO factory.defects (defect_code, lot_id, quantity, reason_code, description, detected_department_id,
                               detected_custody_id, responsible_department_id, reported_by)
  VALUES (v_code, v_lot, v_qty, v_reason, v_desc, v_dept, v_custody, v_resp, a.employee_id) RETURNING id INTO v_defect;
  PERFORM factory.post_event('DEFECT_MARK', v_lot, v_qty, a.employee_id, v_dept, NULL, v_defect, NULL, NULL, v_reason,
    jsonb_build_array(jsonb_build_object('custody', v_custody, 'condition', 'GOOD', 'delta', -v_qty),
                      jsonb_build_object('custody', v_custody, 'condition', 'DEFECTIVE', 'delta', v_qty)));
  PERFORM factory.audit(a.employee_id, 'defect.mark', 'defect', v_defect::text, v_key::text,
    jsonb_build_object('code', v_code, 'quantity', v_qty, 'reason', v_reason));
  RETURN factory.idem_finish(a.employee_id, 'defect.mark', v_key, jsonb_build_object('defectId', v_defect, 'defectCode', v_code));
END $$;

CREATE FUNCTION factory.save_defect(p_id uuid, p_rep int, p_scr int, p_total int) RETURNS void
LANGUAGE sql SET search_path = '' AS $$
  UPDATE factory.defects SET repaired_qty = p_rep, scrapped_qty = p_scr,
         status = CASE WHEN p_rep + p_scr = p_total THEN 'CLOSED'::factory.defect_status ELSE 'OPEN' END,
         closed_at = CASE WHEN p_rep + p_scr = p_total THEN now() ELSE NULL END
   WHERE id = p_id;
$$;

CREATE FUNCTION public.app_repair_defect(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_custody uuid := factory.j_uuid(p, 'custodyId', true, 'العهدة');
  v_qty int := factory.j_int(p, 'quantity', 1, 1000000, 'الكمية');
  v_note text := factory.j_text(p, 'note', 1, 500, false, 'الملاحظة');
  v_prev jsonb; d record; v_dept uuid;
BEGIN
  PERFORM factory.assert(factory.can_operate(a, v_custody), 'القطع المعيبة ليست في عهدتك');
  v_prev := factory.idem_begin(a.employee_id, 'defect.repair', v_key, p || jsonb_build_object('defectId', p_id));
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  SELECT * INTO d FROM factory.defects WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'سجل العيب غير موجود'); END IF;
  IF d.status <> 'OPEN' THEN PERFORM factory.err('BUSINESS_RULE', 'سجل العيب مغلق'); END IF;
  IF v_qty > d.quantity - d.repaired_qty - d.scrapped_qty THEN
    PERFORM factory.err('BUSINESS_RULE', format('الكمية أكبر من الكمية المعيبة المفتوحة (%s)', d.quantity - d.repaired_qty - d.scrapped_qty));
  END IF;
  SELECT department_id INTO v_dept FROM factory.custodies WHERE id = v_custody;
  PERFORM factory.post_event('REPAIR', d.lot_id, v_qty, a.employee_id, v_dept, NULL, d.id, NULL, NULL, v_note,
    jsonb_build_array(jsonb_build_object('custody', v_custody, 'condition', 'DEFECTIVE', 'delta', -v_qty),
                      jsonb_build_object('custody', v_custody, 'condition', 'GOOD', 'delta', v_qty)));
  PERFORM factory.save_defect(d.id, d.repaired_qty + v_qty, d.scrapped_qty, d.quantity);
  PERFORM factory.audit(a.employee_id, 'defect.repair', 'defect', d.id::text, v_key::text, jsonb_build_object('quantity', v_qty));
  RETURN factory.idem_finish(a.employee_id, 'defect.repair', v_key, jsonb_build_object('defectId', d.id, 'repaired', v_qty));
END $$;

CREATE FUNCTION public.app_decide_defect(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_decision text := factory.j_text(p, 'decision', 1, 10, true, 'القرار');
  v_qty int := factory.j_int(p, 'quantity', 1, 1000000, 'الكمية');
  v_custody uuid := factory.j_uuid(p, 'custodyId', false, 'العهدة');
  v_reason text := factory.j_text(p, 'reason', 1, 1000, true, 'سبب القرار');
  v_prev jsonb; d record; c record; v_held int; v_event uuid; v_disp uuid;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'SUPERVISOR'), 'قرار المعالجة النهائية من صلاحية المشرف');
  IF v_decision NOT IN ('REWORK', 'SCRAP', 'REPLACE') THEN PERFORM factory.err('INVALID', 'قرار غير صالح'); END IF;
  IF v_decision <> 'REWORK' AND v_custody IS NULL THEN PERFORM factory.err('INVALID', 'حدد مكان القطع المعيبة المراد إتلافها'); END IF;
  v_prev := factory.idem_begin(a.employee_id, 'defect.decide', v_key, p || jsonb_build_object('defectId', p_id));
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  SELECT * INTO d FROM factory.defects WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'سجل العيب غير موجود'); END IF;
  IF d.status <> 'OPEN' THEN PERFORM factory.err('BUSINESS_RULE', 'سجل العيب مغلق'); END IF;
  IF v_qty > d.quantity - d.repaired_qty - d.scrapped_qty THEN
    PERFORM factory.err('BUSINESS_RULE', format('الكمية أكبر من الكمية المعيبة المفتوحة (%s)', d.quantity - d.repaired_qty - d.scrapped_qty));
  END IF;
  IF v_decision <> 'REWORK' THEN
    SELECT id, kind, department_id INTO c FROM factory.custodies WHERE id = v_custody;
    IF c.id IS NULL OR c.kind NOT IN ('DEPARTMENT', 'EMPLOYEE') THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن الإتلاف من عهدة نقل أو خلاف'); END IF;
    v_held := factory.balance_of(d.lot_id, c.id, 'DEFECTIVE');
    IF v_held < v_qty THEN PERFORM factory.err('BUSINESS_RULE', format('العهدة المختارة تحوي %s قطعة معيبة فقط من هذه الدفعة', v_held)); END IF;
    v_event := factory.post_event('SCRAP', d.lot_id, v_qty, a.employee_id, c.department_id, NULL, d.id, NULL, NULL, v_reason,
      jsonb_build_array(jsonb_build_object('custody', c.id, 'condition', 'DEFECTIVE', 'delta', -v_qty)));
    PERFORM factory.save_defect(d.id, d.repaired_qty, d.scrapped_qty + v_qty, d.quantity);
  END IF;
  INSERT INTO factory.dispositions (defect_id, decision, quantity, scrap_custody_id, replacement_qty, reason, approved_by, stock_event_id)
  VALUES (d.id, v_decision::factory.disposition_decision, v_qty, CASE WHEN v_decision <> 'REWORK' THEN v_custody END,
          CASE WHEN v_decision = 'REPLACE' THEN v_qty ELSE 0 END, v_reason, a.employee_id, v_event)
  RETURNING id INTO v_disp;
  PERFORM factory.audit(a.employee_id, 'defect.decision.' || lower(v_decision), 'defect', d.id::text, v_key::text,
    jsonb_build_object('dispositionId', v_disp, 'quantity', v_qty, 'custodyId', v_custody, 'reason', v_reason));
  RETURN factory.idem_finish(a.employee_id, 'defect.decide', v_key, jsonb_build_object('dispositionId', v_disp, 'decision', v_decision));
END $$;

-- ================================================================ warehouse
CREATE FUNCTION public.app_create_shipment(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_order uuid := factory.j_uuid(p, 'orderId', true, 'الطلب');
  v_date date := factory.j_date(p, 'deliveredOn', 'تاريخ التسليم');
  v_notes text := factory.j_text(p, 'notes', 1, 500, false, 'الملاحظة');
  v_prev jsonb; o record; l jsonb; v_lot uuid; v_custody uuid; v_qty int; c record; v_line uuid;
  v_remaining int; v_code text; v_ship uuid; v_event uuid; v_total int := 0; v_seen text[] := '{}';
BEGIN
  PERFORM factory.assert(factory.in_stage(a, 'WAREHOUSE'), 'التسليم للزبون من صلاحية المخزن');
  IF jsonb_typeof(p -> 'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'lines') NOT BETWEEN 1 AND 200 THEN
    PERFORM factory.err('INVALID', 'أضف سطر تسليم واحداً على الأقل');
  END IF;
  v_prev := factory.idem_begin(a.employee_id, 'shipment.create', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  SELECT id, status, customer_id INTO o FROM factory.orders WHERE id = v_order FOR UPDATE;
  IF o.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الطلب غير موجود'); END IF;
  IF o.status <> 'RELEASED' THEN PERFORM factory.err('BUSINESS_RULE', 'يمكن التسليم للطلبات قيد الإنتاج فقط'); END IF;
  IF v_date > factory.today() THEN PERFORM factory.err('BUSINESS_RULE', 'تاريخ التسليم لا يمكن أن يكون في المستقبل'); END IF;

  v_code := factory.make_code('SH');
  INSERT INTO factory.shipments (shipment_code, order_id, customer_id, delivered_on, notes, created_by)
  VALUES (v_code, o.id, o.customer_id, v_date, v_notes, a.employee_id) RETURNING id INTO v_ship;

  FOR l IN SELECT * FROM jsonb_array_elements(p -> 'lines') LOOP
    v_lot := factory.j_uuid(l, 'lotId', true, 'الدفعة');
    v_custody := factory.j_uuid(l, 'custodyId', true, 'العهدة');
    v_qty := factory.j_int(l, 'quantity', 1, 1000000, 'الكمية');
    IF (v_lot::text || v_custody::text) = ANY (v_seen) THEN PERFORM factory.err('BUSINESS_RULE', 'سطر مكرر في التسليم'); END IF;
    v_seen := v_seen || (v_lot::text || v_custody::text);
    SELECT cu.id, cu.department_id, d.stage INTO c FROM factory.custodies cu JOIN factory.departments d ON d.id = cu.department_id WHERE cu.id = v_custody;
    PERFORM factory.assert(c.id IS NOT NULL AND c.stage = 'WAREHOUSE' AND factory.can_operate(a, v_custody), 'التسليم يتم من عهدة المخزن فقط');
    SELECT l2.order_line_id INTO v_line FROM factory.cut_lots l2 JOIN factory.order_lines ol ON ol.id = l2.order_line_id
     WHERE l2.id = v_lot AND ol.order_id = o.id;
    IF v_line IS NULL THEN PERFORM factory.err('BUSINESS_RULE', 'الدفعة لا تخص هذا الطلب'); END IF;
    SELECT ol.planned_qty - coalesce((SELECT sum(e.qty) FROM factory.stock_events e JOIN factory.cut_lots x ON x.id = e.lot_id
                                      WHERE x.order_line_id = ol.id AND e.kind = 'SHIPMENT'), 0)
      INTO v_remaining FROM factory.order_lines ol WHERE ol.id = v_line;
    IF v_qty > v_remaining THEN PERFORM factory.err('BUSINESS_RULE', format('الكمية تتجاوز المتبقي للتسليم في هذا السطر (%s)', v_remaining)); END IF;
    v_event := factory.post_event('SHIPMENT', v_lot, v_qty, a.employee_id, c.department_id, NULL, NULL, v_ship, NULL, NULL,
      jsonb_build_array(jsonb_build_object('custody', v_custody, 'condition', 'GOOD', 'delta', -v_qty)));
    INSERT INTO factory.shipment_lines (shipment_id, lot_id, custody_id, quantity, stock_event_id) VALUES (v_ship, v_lot, v_custody, v_qty, v_event);
    v_total := v_total + v_qty;
  END LOOP;
  PERFORM factory.audit(a.employee_id, 'shipment.create', 'shipment', v_ship::text, v_key::text,
    jsonb_build_object('code', v_code, 'orderId', o.id, 'total', v_total));
  RETURN factory.idem_finish(a.employee_id, 'shipment.create', v_key, jsonb_build_object('shipmentId', v_ship, 'shipmentCode', v_code, 'quantity', v_total));
END $$;

-- ================================================================ admin: stock correction
CREATE FUNCTION public.app_create_adjustment(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_key uuid := factory.j_uuid(p, 'requestKey', true, 'رقم الطلب');
  v_lot uuid := factory.j_uuid(p, 'lotId', true, 'الدفعة');
  v_custody uuid := factory.j_uuid(p, 'custodyId', true, 'العهدة');
  v_cond text := factory.j_text(p, 'condition', 1, 20, true, 'الحالة');
  v_signed int := factory.j_int(p, 'signedQty', -1000000, 1000000, 'الكمية');
  v_reason text := factory.j_text(p, 'reason', 3, 1000, true, 'السبب');
  v_ref text := factory.j_text(p, 'reference', 1, 200, false, 'المرجع');
  v_prev jsonb; c record; t record; v_n int; v_tr uuid; v_adj uuid;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'), 'تصحيح الكميات من صلاحية مدير النظام فقط');
  IF v_signed = 0 THEN PERFORM factory.err('INVALID', 'الكمية لا يمكن أن تكون صفراً'); END IF;
  IF v_cond NOT IN ('GOOD', 'DEFECTIVE') THEN PERFORM factory.err('INVALID', 'حالة غير صالحة'); END IF;
  v_prev := factory.idem_begin(a.employee_id, 'stock.adjust', v_key, p);
  IF v_prev IS NOT NULL THEN RETURN v_prev; END IF;
  SELECT * INTO c FROM factory.custodies WHERE id = v_custody;
  IF c.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'العهدة غير موجودة'); END IF;
  IF NOT EXISTS (SELECT 1 FROM factory.cut_lots WHERE id = v_lot) THEN PERFORM factory.err('NOT_FOUND', 'الدفعة غير موجودة'); END IF;
  IF c.kind IN ('TRANSIT', 'DISPUTE') THEN
    IF v_signed > 0 THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكن إضافة قطع إلى عهدة نقل أو خلاف'); END IF;
    SELECT * INTO t FROM factory.transfers WHERE id = c.transfer_id FOR UPDATE;
    IF t.condition::text <> v_cond OR t.lot_id <> v_lot THEN PERFORM factory.err('BUSINESS_RULE', 'الدفعة أو حالة القطع لا تطابق التحويل'); END IF;
    v_n := -v_signed;
    IF c.kind = 'DISPUTE' THEN
      IF v_n > t.disputed_qty THEN PERFORM factory.err('BUSINESS_RULE', format('الكمية أكبر من المختلف عليه (%s)', t.disputed_qty)); END IF;
      PERFORM factory.save_transfer(t.id, t.accepted_qty, t.returned_qty, t.pending_qty, t.disputed_qty - v_n, t.written_off_qty + v_n);
    ELSE
      IF v_n > t.pending_qty THEN PERFORM factory.err('BUSINESS_RULE', format('الكمية أكبر من المعلق (%s)', t.pending_qty)); END IF;
      PERFORM factory.save_transfer(t.id, t.accepted_qty, t.returned_qty, t.pending_qty - v_n, t.disputed_qty, t.written_off_qty + v_n);
    END IF;
    v_tr := t.id;
  END IF;
  INSERT INTO factory.stock_adjustments (lot_id, custody_id, condition, signed_qty, reason, reference, transfer_id, approved_by)
  VALUES (v_lot, v_custody, v_cond::factory.stock_condition, v_signed, v_reason, v_ref, v_tr, a.employee_id) RETURNING id INTO v_adj;
  PERFORM factory.post_event('ADJUSTMENT', v_lot, abs(v_signed), a.employee_id, NULL, v_tr, NULL, NULL, v_adj, v_reason,
    jsonb_build_array(jsonb_build_object('custody', v_custody, 'condition', v_cond, 'delta', v_signed)));
  PERFORM factory.audit(a.employee_id, 'stock.adjust', 'stock_adjustment', v_adj::text, v_key::text,
    jsonb_build_object('lotId', v_lot, 'custody', factory.custody_label(v_custody), 'condition', v_cond,
                       'signedQty', v_signed, 'reason', v_reason, 'reference', v_ref, 'transferId', v_tr));
  RETURN factory.idem_finish(a.employee_id, 'stock.adjust', v_key, jsonb_build_object('adjustmentId', v_adj));
END $$;

-- ================================================================ admin: departments & roles
CREATE FUNCTION public.app_create_department(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_code text := upper(factory.j_text(p, 'code', 2, 32, true, 'رمز القسم'));
  v_name text := factory.j_text(p, 'nameAr', 1, 100, true, 'اسم القسم');
  v_stage text := factory.j_text(p, 'stage', 1, 20, false, 'المرحلة');
  v_mode text := factory.j_text(p, 'custodyMode', 1, 20, true, 'نوع العهدة');
  v_id uuid;
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  IF v_code !~ '^[A-Z0-9_]{2,32}$' THEN PERFORM factory.err('INVALID', 'رمز القسم: أحرف لاتينية كبيرة وأرقام'); END IF;
  IF v_stage IS NOT NULL AND v_stage NOT IN ('CUTTING','SEWING','FINISHING_1','IRONING','FINISHING_2','WAREHOUSE') THEN
    PERFORM factory.err('INVALID', 'مرحلة غير صالحة');
  END IF;
  IF v_mode NOT IN ('SHARED', 'INDIVIDUAL') THEN PERFORM factory.err('INVALID', 'نوع عهدة غير صالح'); END IF;
  IF EXISTS (SELECT 1 FROM factory.departments WHERE code = v_code) THEN PERFORM factory.err('CONFLICT', 'رمز القسم مستخدم مسبقاً'); END IF;
  INSERT INTO factory.departments (code, name_ar, stage, custody_mode)
  VALUES (v_code, v_name, v_stage::factory.stage, v_mode::factory.custody_mode) RETURNING id INTO v_id;
  PERFORM factory.dept_custody(v_id);
  PERFORM factory.audit(a.employee_id, 'department.create', 'department', v_id::text, NULL, p);
  RETURN jsonb_build_object('id', v_id);
END $$;

CREATE FUNCTION public.app_update_department(p_id uuid, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a factory.actor_t := factory.require_actor(true);
  v_name text := factory.j_text(p, 'nameAr', 1, 100, false, 'اسم القسم');
  v_mode text := factory.j_text(p, 'custodyMode', 1, 20, false, 'نوع العهدة');
  v_active boolean := CASE WHEN jsonb_typeof(p -> 'active') = 'boolean' THEN (p ->> 'active')::boolean END;
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
         active = coalesce(v_active, active) WHERE id = p_id;
  PERFORM factory.audit(a.employee_id, 'department.update', 'department', p_id::text, NULL,
    jsonb_build_object('before', jsonb_build_object('name_ar', d.name_ar, 'custody_mode', d.custody_mode, 'active', d.active), 'after', p));
  RETURN jsonb_build_object('ok', true);
END $$;

/** Shared by app_set_employee_roles and the service-only provisioning function. */
CREATE FUNCTION factory.apply_roles(p_emp uuid, p_roles jsonb) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  r jsonb; v_role text; v_dept uuid; v_wanted text[] := '{}'; cur record; v_key text; v_held int; d record;
BEGIN
  IF jsonb_typeof(p_roles) IS DISTINCT FROM 'array' OR jsonb_array_length(p_roles) > 20 THEN
    PERFORM factory.err('INVALID', 'قائمة الأدوار غير صالحة');
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_roles) LOOP
    v_role := r ->> 'role';
    IF v_role NOT IN ('ADMIN', 'SUPERVISOR', 'REVIEWER', 'WORKER') THEN PERFORM factory.err('INVALID', 'دور غير صالح'); END IF;
    v_dept := CASE WHEN v_role = 'WORKER' THEN factory.j_uuid(r, 'departmentId', true, 'القسم') END;
    IF v_dept IS NOT NULL THEN
      SELECT id, custody_mode INTO d FROM factory.departments WHERE id = v_dept AND active;
      IF d.id IS NULL THEN PERFORM factory.err('BUSINESS_RULE', 'قسم غير موجود أو غير مفعّل'); END IF;
      IF d.custody_mode = 'INDIVIDUAL' THEN PERFORM factory.emp_custody(v_dept, p_emp); END IF;
    END IF;
    v_wanted := v_wanted || (v_role || '|' || coalesce(v_dept::text, ''));
  END LOOP;
  FOR cur IN SELECT id, role::text AS role, department_id, active FROM factory.employee_roles WHERE employee_id = p_emp LOOP
    v_key := cur.role || '|' || coalesce(cur.department_id::text, '');
    IF cur.active AND NOT v_key = ANY (v_wanted) THEN
      IF cur.role = 'WORKER' THEN
        SELECT coalesce(sum(b.qty), 0) INTO v_held FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
         WHERE c.kind = 'EMPLOYEE' AND c.employee_id = p_emp AND c.department_id = cur.department_id;
        IF v_held > 0 THEN PERFORM factory.err('BUSINESS_RULE', 'لدى الموظف قطع في عهدته بهذا القسم؛ انقلها قبل إزالة العضوية'); END IF;
      END IF;
      UPDATE factory.employee_roles SET active = false WHERE id = cur.id;
    ELSIF NOT cur.active AND v_key = ANY (v_wanted) THEN
      UPDATE factory.employee_roles SET active = true WHERE id = cur.id;
    END IF;
    v_wanted := array_remove(v_wanted, v_key);
  END LOOP;
  FOREACH v_key IN ARRAY v_wanted LOOP
    INSERT INTO factory.employee_roles (employee_id, role, department_id)
    VALUES (p_emp, split_part(v_key, '|', 1)::factory.app_role, nullif(split_part(v_key, '|', 2), '')::uuid);
  END LOOP;
END $$;

CREATE FUNCTION public.app_set_employee_roles(p_employee uuid, p_roles jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE a factory.actor_t := factory.require_actor(true);
BEGIN
  PERFORM factory.assert(factory.has_role(a, 'ADMIN'));
  IF p_employee = a.employee_id AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_roles) x WHERE x ->> 'role' = 'ADMIN') THEN
    PERFORM factory.err('BUSINESS_RULE', 'لا يمكنك إزالة صلاحية مدير النظام عن نفسك');
  END IF;
  PERFORM 1 FROM factory.employees WHERE id = p_employee FOR UPDATE;
  IF NOT FOUND THEN PERFORM factory.err('NOT_FOUND', 'الموظف غير موجود'); END IF;
  PERFORM factory.apply_roles(p_employee, p_roles);
  PERFORM factory.audit(a.employee_id, 'employee.roles', 'employee', p_employee::text, NULL, jsonb_build_object('roles', p_roles));
  RETURN jsonb_build_object('ok', true);
END $$;
