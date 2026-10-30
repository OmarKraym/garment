-- 002_engine.sql — internal engine (schema factory, NOT exposed to the Data API).
-- Port of the tested TypeScript services: actor resolution, authorization helpers,
-- validation, idempotency and the atomic stock ledger. Only the API functions (003–005) call these.

-- ---------------------------------------------------------------- errors
-- Business errors carry a machine code in HINT and an Arabic, user-safe MESSAGE.
CREATE FUNCTION factory.err(p_code text, p_message text) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = p_message, HINT = p_code;
END $$;

-- ---------------------------------------------------------------- actor
CREATE TYPE factory.actor_t AS (
  employee_id   uuid,
  username      text,
  display_name  text,
  must_change   boolean,
  roles         text[],   -- ADMIN / SUPERVISOR / REVIEWER
  dept_ids      uuid[],   -- active WORKER memberships
  stages        text[]    -- stages of those departments
);

/** Resolves the caller from the verified JWT (auth.uid()). Never trusts client input. */
CREATE FUNCTION factory.require_actor(p_write boolean) RETURNS factory.actor_t
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE
  a factory.actor_t;
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN PERFORM factory.err('UNAUTHENTICATED', 'يجب تسجيل الدخول'); END IF;
  SELECT e.id, e.username, e.display_name, e.must_change_password
    INTO a.employee_id, a.username, a.display_name, a.must_change
    FROM factory.employees e WHERE e.auth_user_id = v_uid AND e.active;
  IF a.employee_id IS NULL THEN PERFORM factory.err('UNAUTHENTICATED', 'الحساب غير مرتبط بموظف فعّال'); END IF;
  IF p_write AND a.must_change THEN
    PERFORM factory.err('PASSWORD_CHANGE_REQUIRED', 'يجب تغيير كلمة المرور المؤقتة أولاً من صفحة «حسابي»');
  END IF;
  SELECT coalesce(array_agg(DISTINCT r.role::text) FILTER (WHERE r.role <> 'WORKER'), '{}'),
         coalesce(array_agg(DISTINCT d.id) FILTER (WHERE r.role = 'WORKER' AND d.active), '{}'),
         coalesce(array_agg(DISTINCT d.stage::text) FILTER (WHERE r.role = 'WORKER' AND d.active AND d.stage IS NOT NULL), '{}')
    INTO a.roles, a.dept_ids, a.stages
    FROM factory.employee_roles r LEFT JOIN factory.departments d ON d.id = r.department_id
   WHERE r.employee_id = a.employee_id AND r.active;
  RETURN a;
END $$;

CREATE FUNCTION factory.has_role(a factory.actor_t, p_role text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT p_role = ANY (a.roles) $$;

CREATE FUNCTION factory.in_stage(a factory.actor_t, p_stage text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$ SELECT p_stage = ANY (a.stages) $$;

CREATE FUNCTION factory.view_all(a factory.actor_t) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT factory.has_role(a, 'ADMIN') OR factory.has_role(a, 'SUPERVISOR') OR factory.has_role(a, 'REVIEWER') $$;

CREATE FUNCTION factory.assert(p_ok boolean, p_message text DEFAULT 'ليست لديك صلاحية لتنفيذ هذه العملية') RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF NOT coalesce(p_ok, false) THEN PERFORM factory.err('FORBIDDEN', p_message); END IF;
END $$;

/** Department pool → any member; employee custody → only its owner while a member. */
CREATE FUNCTION factory.can_operate(a factory.actor_t, p_custody uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM factory.custodies c
     WHERE c.id = p_custody
       AND c.department_id = ANY (a.dept_ids)
       AND (c.kind = 'DEPARTMENT' OR (c.kind = 'EMPLOYEE' AND c.employee_id = a.employee_id)))
$$;

-- ---------------------------------------------------------------- validation
CREATE FUNCTION factory.j_text(p jsonb, k text, p_min int, p_max int, p_required boolean, p_label text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := btrim(p ->> k);
BEGIN
  IF v IS NULL OR v = '' THEN
    IF p_required THEN PERFORM factory.err('INVALID', p_label || ' مطلوب'); END IF;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p -> k) <> 'string' THEN PERFORM factory.err('INVALID', p_label || ': قيمة غير صالحة'); END IF;
  IF length(v) < p_min OR length(v) > p_max THEN
    PERFORM factory.err('INVALID', format('%s: الطول بين %s و %s حرفاً', p_label, p_min, p_max));
  END IF;
  RETURN v;
END $$;

CREATE FUNCTION factory.j_int(p jsonb, k text, p_min int, p_max int, p_label text) RETURNS int
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v numeric;
BEGIN
  IF jsonb_typeof(p -> k) IS DISTINCT FROM 'number' THEN PERFORM factory.err('INVALID', p_label || ': رقم مطلوب'); END IF;
  v := (p ->> k)::numeric;
  IF v <> trunc(v) OR v < p_min OR v > p_max THEN
    PERFORM factory.err('INVALID', format('%s: عدد صحيح بين %s و %s', p_label, p_min, p_max));
  END IF;
  RETURN v::int;
END $$;

CREATE FUNCTION factory.j_uuid(p jsonb, k text, p_required boolean, p_label text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := p ->> k;
BEGIN
  IF v IS NULL OR v = '' THEN
    IF p_required THEN PERFORM factory.err('INVALID', p_label || ' مطلوب'); END IF;
    RETURN NULL;
  END IF;
  IF v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    PERFORM factory.err('INVALID', p_label || ': معرّف غير صالح');
  END IF;
  RETURN v::uuid;
END $$;

CREATE FUNCTION factory.j_date(p jsonb, k text, p_label text) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := p ->> k;
BEGIN
  IF v IS NULL OR v !~ '^\d{4}-\d{2}-\d{2}$' THEN PERFORM factory.err('INVALID', p_label || ': تاريخ غير صالح'); END IF;
  BEGIN
    RETURN v::date;
  EXCEPTION WHEN others THEN
    PERFORM factory.err('INVALID', p_label || ': تاريخ غير صالح');
  END;
END $$;

CREATE FUNCTION factory.today() RETURNS date
LANGUAGE sql STABLE SET search_path = '' AS $$ SELECT (now() AT TIME ZONE 'Africa/Tripoli')::date $$;

CREATE FUNCTION factory.make_code(p_prefix text) RETURNS text
LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
DECLARE
  alphabet text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  s text := '';
BEGIN
  FOR i IN 1..6 LOOP
    s := s || substr(alphabet, 1 + floor(random() * 32)::int, 1);
  END LOOP;
  RETURN p_prefix || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD') || '-' || s;
END $$;

-- ---------------------------------------------------------------- audit
CREATE FUNCTION factory.audit(p_actor uuid, p_action text, p_type text, p_target text, p_request text, p_meta jsonb)
RETURNS void LANGUAGE sql SET search_path = '' AS $$
  INSERT INTO factory.audit_events (actor_employee_id, action, target_type, target_id, request_id, metadata)
  VALUES (p_actor, p_action, p_type, p_target, p_request, coalesce(p_meta, '{}'::jsonb));
$$;

-- ---------------------------------------------------------------- idempotency
/** Returns the stored response if this key was already completed; NULL if the caller should proceed. */
CREATE FUNCTION factory.idem_begin(p_actor uuid, p_scope text, p_key uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_hash text := md5(p_payload::text);  -- jsonb text is canonical (sorted keys)
  r record;
BEGIN
  IF p_key IS NULL THEN PERFORM factory.err('INVALID', 'رقم الطلب (requestKey) مطلوب'); END IF;
  INSERT INTO factory.idempotency_keys (actor_employee_id, scope, request_key, request_hash, response)
  VALUES (p_actor, p_scope, p_key, v_hash, '{}'::jsonb)
  ON CONFLICT DO NOTHING;
  IF FOUND THEN RETURN NULL; END IF;
  SELECT request_hash, response INTO r FROM factory.idempotency_keys
   WHERE actor_employee_id = p_actor AND scope = p_scope AND request_key = p_key;
  IF r.request_hash <> v_hash THEN
    PERFORM factory.err('CONFLICT', 'رقم الطلب مستخدم سابقاً لعملية مختلفة. أعد المحاولة من النموذج.');
  END IF;
  RETURN r.response || jsonb_build_object('replayed', true);
END $$;

CREATE FUNCTION factory.idem_finish(p_actor uuid, p_scope text, p_key uuid, p_response jsonb) RETURNS jsonb
LANGUAGE sql SET search_path = '' AS $$
  UPDATE factory.idempotency_keys SET response = p_response
   WHERE actor_employee_id = p_actor AND scope = p_scope AND request_key = p_key;
  SELECT p_response || jsonb_build_object('replayed', false);
$$;

-- ---------------------------------------------------------------- custodies
CREATE FUNCTION factory.dept_custody(p_dept uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO factory.custodies (kind, department_id) VALUES ('DEPARTMENT', p_dept)
  ON CONFLICT (department_id) WHERE kind = 'DEPARTMENT' DO NOTHING;
  SELECT id INTO v FROM factory.custodies WHERE kind = 'DEPARTMENT' AND department_id = p_dept;
  RETURN v;
END $$;

CREATE FUNCTION factory.emp_custody(p_dept uuid, p_emp uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO factory.custodies (kind, department_id, employee_id) VALUES ('EMPLOYEE', p_dept, p_emp)
  ON CONFLICT (department_id, employee_id) WHERE kind = 'EMPLOYEE' DO NOTHING;
  SELECT id INTO v FROM factory.custodies WHERE kind = 'EMPLOYEE' AND department_id = p_dept AND employee_id = p_emp;
  RETURN v;
END $$;

/** SHARED departments receive into the pool; INDIVIDUAL departments need a named active member. */
CREATE FUNCTION factory.receiving_custody(p_dept uuid, p_emp uuid) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE d record;
BEGIN
  SELECT custody_mode, active INTO d FROM factory.departments WHERE id = p_dept;
  IF d IS NULL OR NOT d.active THEN PERFORM factory.err('NOT_FOUND', 'القسم غير موجود أو غير مفعّل'); END IF;
  IF d.custody_mode = 'SHARED' THEN RETURN factory.dept_custody(p_dept); END IF;
  IF p_emp IS NULL THEN PERFORM factory.err('BUSINESS_RULE', 'هذا القسم يعمل بالعهدة الفردية: اختر العامل المستلم'); END IF;
  IF NOT EXISTS (
    SELECT 1 FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
     WHERE r.employee_id = p_emp AND r.department_id = p_dept AND r.role = 'WORKER' AND r.active AND e.active) THEN
    PERFORM factory.err('BUSINESS_RULE', 'العامل المختار ليس عضواً فعّالاً في القسم المستلم');
  END IF;
  RETURN factory.emp_custody(p_dept, p_emp);
END $$;

CREATE FUNCTION factory.custody_label(p_custody uuid) RETURNS text
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT CASE c.kind
           WHEN 'DEPARTMENT' THEN d.name_ar
           WHEN 'EMPLOYEE' THEN d.name_ar || ' — ' || e.display_name
           WHEN 'TRANSIT' THEN 'قيد النقل ' || t.transfer_code
           ELSE 'خلاف ' || t.transfer_code END
    FROM factory.custodies c
    LEFT JOIN factory.departments d ON d.id = c.department_id
    LEFT JOIN factory.employees e ON e.id = c.employee_id
    LEFT JOIN factory.transfers t ON t.id = c.transfer_id
   WHERE c.id = p_custody
$$;

-- ---------------------------------------------------------------- ledger core
/**
 * The ONLY way stock changes. p_lines: [{"custody": uuid, "condition": "GOOD|DEFECTIVE", "delta": int}]
 * Lines are merged and applied in a deterministic order (deadlock avoidance); debits are
 * conditional (qty >= amount) so balances never go negative; per-kind net rules make it
 * impossible for moves/defects/repairs to create or destroy units.
 */
CREATE FUNCTION factory.post_event(
  p_kind factory.stock_event_kind, p_lot uuid, p_qty int, p_actor uuid, p_dept uuid,
  p_transfer uuid, p_defect uuid, p_shipment uuid, p_adjustment uuid, p_reason text, p_lines jsonb
) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_event uuid;
  v_net int;
  v_count int;
  l record;
  v_rows int;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN PERFORM factory.err('INVALID', 'الكمية يجب أن تكون عدداً صحيحاً موجباً'); END IF;

  WITH m AS (
    SELECT (x ->> 'custody')::uuid AS custody, (x ->> 'condition')::factory.stock_condition AS cond,
           sum((x ->> 'delta')::int) AS delta
      FROM jsonb_array_elements(p_lines) x GROUP BY 1, 2 HAVING sum((x ->> 'delta')::int) <> 0)
  SELECT coalesce(sum(delta), 0)::int, count(*)::int INTO v_net, v_count FROM m;
  IF v_count = 0 OR NOT (
       (p_kind IN ('DISPATCH','ACCEPT','DISPUTE','REJECT_RETURN','DISPUTE_ACCEPT','DISPUTE_RETURN','DEFECT_MARK','REPAIR') AND v_net = 0)
    OR (p_kind = 'CUT' AND v_net = p_qty)
    OR (p_kind IN ('SCRAP','SHIPMENT') AND v_net = -p_qty)
    OR (p_kind = 'ADJUSTMENT' AND abs(v_net) = p_qty)) THEN
    RAISE EXCEPTION 'Ledger invariant violated for %: net %, qty %', p_kind, v_net, p_qty;
  END IF;

  INSERT INTO factory.stock_events (kind, lot_id, qty, actor_employee_id, acting_department_id, transfer_id,
                                    defect_id, shipment_id, adjustment_id, reason)
  VALUES (p_kind, p_lot, p_qty, p_actor, p_dept, p_transfer, p_defect, p_shipment, p_adjustment, p_reason)
  RETURNING id INTO v_event;

  FOR l IN
    SELECT (x ->> 'custody')::uuid AS custody, (x ->> 'condition')::factory.stock_condition AS cond,
           sum((x ->> 'delta')::int)::int AS delta
      FROM jsonb_array_elements(p_lines) x GROUP BY 1, 2 HAVING sum((x ->> 'delta')::int) <> 0
     ORDER BY 1, 2
  LOOP
    IF l.delta < 0 THEN
      UPDATE factory.stock_balances SET qty = qty + l.delta, updated_at = now()
       WHERE lot_id = p_lot AND custody_id = l.custody AND condition = l.cond AND qty >= -l.delta;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows <> 1 THEN PERFORM factory.err('INSUFFICIENT_STOCK', 'الكمية المتاحة غير كافية'); END IF;
    ELSE
      INSERT INTO factory.stock_balances (lot_id, custody_id, condition, qty) VALUES (p_lot, l.custody, l.cond, l.delta)
      ON CONFLICT (lot_id, custody_id, condition)
      DO UPDATE SET qty = factory.stock_balances.qty + EXCLUDED.qty, updated_at = now();
    END IF;
    INSERT INTO factory.stock_journal (event_id, lot_id, custody_id, condition, delta)
    VALUES (v_event, p_lot, l.custody, l.cond, l.delta);
  END LOOP;
  RETURN v_event;
END $$;

CREATE FUNCTION factory.balance_of(p_lot uuid, p_custody uuid, p_cond factory.stock_condition) RETURNS int
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT coalesce((SELECT qty FROM factory.stock_balances WHERE lot_id = p_lot AND custody_id = p_custody AND condition = p_cond), 0)
$$;

-- ---------------------------------------------------------------- transfers helpers
CREATE FUNCTION factory.stage_rank(p_stage factory.stage) RETURNS int
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT array_position(enum_range(NULL::factory.stage), p_stage)
$$;

CREATE FUNCTION factory.save_transfer(p_id uuid, p_acc int, p_ret int, p_pend int, p_disp int, p_wo int) RETURNS factory.transfer_state
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_total int;
  v_state factory.transfer_state;
BEGIN
  SELECT dispatched_qty INTO v_total FROM factory.transfers WHERE id = p_id;
  v_state := CASE
    WHEN p_pend + p_disp > 0 AND p_disp > 0 THEN 'DISPUTED'
    WHEN p_pend + p_disp > 0 AND p_acc + p_ret > 0 THEN 'PARTIALLY_ACCEPTED'
    WHEN p_pend + p_disp > 0 THEN 'DISPATCHED'
    WHEN p_acc = v_total THEN 'ACCEPTED'
    WHEN p_ret = v_total THEN 'RETURNED'
    ELSE 'CLOSED' END;
  UPDATE factory.transfers
     SET accepted_qty = p_acc, returned_qty = p_ret, pending_qty = p_pend, disputed_qty = p_disp,
         written_off_qty = p_wo, state = v_state,
         closed_at = CASE WHEN p_pend + p_disp = 0 THEN coalesce(closed_at, now()) ELSE NULL END
   WHERE id = p_id;
  RETURN v_state;
END $$;

CREATE FUNCTION factory.holding(p_transfer uuid, p_kind factory.custody_kind) RETURNS uuid
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO factory.custodies (kind, transfer_id) VALUES (p_kind, p_transfer)
  ON CONFLICT (transfer_id, kind) WHERE transfer_id IS NOT NULL DO NOTHING;
  SELECT id INTO v FROM factory.custodies WHERE transfer_id = p_transfer AND kind = p_kind;
  RETURN v;
END $$;

CREATE FUNCTION factory.move_holding(
  p_actor uuid, p_transfer uuid, p_lot uuid, p_cond factory.stock_condition,
  p_kind factory.stock_event_kind, p_qty int, p_from uuid, p_to uuid, p_dept uuid, p_reason text
) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_event uuid;
BEGIN
  IF p_qty <= 0 THEN RETURN; END IF;
  v_event := factory.post_event(p_kind, p_lot, p_qty, p_actor, p_dept, p_transfer, NULL, NULL, NULL, p_reason,
    jsonb_build_array(
      jsonb_build_object('custody', p_from, 'condition', p_cond, 'delta', -p_qty),
      jsonb_build_object('custody', p_to, 'condition', p_cond, 'delta', p_qty)));
  INSERT INTO factory.transfer_events (transfer_id, kind, qty, actor_employee_id, stock_event_id, reason)
  VALUES (p_transfer, p_kind, p_qty, p_actor, v_event, p_reason);
END $$;

-- Lock every function in this schema away from API roles (defence in depth).
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM %I', r);
    END IF;
  END LOOP;
END $$;
