-- 009_delete_account.sql — the system administrator can delete an employee's account.
--
-- Employee rows are referenced by the permanent ledger and audit log (and protected by the
-- employees_no_delete trigger), so "delete" means:
--   * the login (Supabase Auth user) is deleted by the Edge Function — it can never sign in again;
--   * the employee leaves every list, loses all roles, and the username becomes free for reuse;
--   * past records keep showing who did what (the name stays in history).
-- A deleted account is frozen: nothing can reactivate it or give it roles again.

ALTER TABLE factory.employees ADD COLUMN deleted_at timestamptz;

CREATE FUNCTION factory.freeze_deleted_employee() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_TABLE_NAME = 'employees' THEN
    IF OLD.deleted_at IS NOT NULL THEN PERFORM factory.err('NOT_FOUND', 'هذا الحساب محذوف'); END IF;
  ELSIF EXISTS (SELECT 1 FROM factory.employees WHERE id = NEW.employee_id AND deleted_at IS NOT NULL) THEN
    PERFORM factory.err('NOT_FOUND', 'هذا الحساب محذوف');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER employees_deleted_frozen BEFORE UPDATE ON factory.employees
  FOR EACH ROW EXECUTE FUNCTION factory.freeze_deleted_employee();
CREATE TRIGGER employee_roles_deleted_frozen BEFORE INSERT OR UPDATE ON factory.employee_roles
  FOR EACH ROW EXECUTE FUNCTION factory.freeze_deleted_employee();

/**
 * Called by the staff-admin Edge Function (service role) BEFORE it deletes the Auth user.
 * p_confirm must repeat the username: a deliberate, typed confirmation for an irreversible step.
 */
CREATE FUNCTION public.svc_delete_employee(p_caller uuid, p_employee uuid, p_confirm text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_admin uuid := factory.require_admin(p_caller); e record; v_held int; v_pending int; v_open int;
BEGIN
  IF p_employee = v_admin THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكنك حذف حسابك'); END IF;
  SELECT id, auth_user_id, username, display_name, deleted_at INTO e FROM factory.employees WHERE id = p_employee FOR UPDATE;
  IF e.id IS NULL OR e.deleted_at IS NOT NULL THEN PERFORM factory.err('NOT_FOUND', 'الموظف غير موجود'); END IF;
  IF p_confirm IS DISTINCT FROM e.username THEN PERFORM factory.err('INVALID', 'اكتب اسم المستخدم كما هو لتأكيد الحذف'); END IF;

  -- nothing may be left without an owner
  SELECT coalesce(sum(b.qty), 0) INTO v_held FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
   WHERE c.kind = 'EMPLOYEE' AND c.employee_id = p_employee;
  IF v_held > 0 THEN PERFORM factory.err('BUSINESS_RULE', format('لدى الموظف %s قطعة في عهدته؛ انقلها أولاً ثم احذف الحساب', v_held)); END IF;
  SELECT count(*) INTO v_pending FROM factory.transfers t JOIN factory.custodies c ON c.id = t.to_custody_id
   WHERE c.kind = 'EMPLOYEE' AND c.employee_id = p_employee AND t.pending_qty + t.disputed_qty > 0;
  IF v_pending > 0 THEN PERFORM factory.err('BUSINESS_RULE', 'توجد تحويلات مرسلة إلى هذا الموظف لم تُستلم أو عليها خلاف؛ عالجها أولاً'); END IF;
  SELECT count(*) INTO v_open FROM factory.work_assignments WHERE employee_id = p_employee AND status IN ('ASSIGNED', 'IN_PROGRESS');
  IF v_open > 0 THEN PERFORM factory.err('BUSINESS_RULE', format('لدى الموظف %s تكليف مفتوح؛ ألغِه أو أنهِه أولاً', v_open)); END IF;

  UPDATE factory.employee_roles SET active = false WHERE employee_id = p_employee AND active;
  UPDATE factory.employees
     SET active = false, auth_user_id = NULL, must_change_password = false, deleted_at = now(), updated_at = now(),
         username = 'deleted.' || left(replace(id::text, '-', ''), 24)        -- frees the name for a new account
   WHERE id = p_employee;
  PERFORM factory.audit(v_admin, 'employee.delete', 'employee', p_employee::text, NULL,
    jsonb_build_object('username', e.username, 'display_name', e.display_name));
  RETURN jsonb_build_object('auth_user_id', e.auth_user_id, 'username', e.username);
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
      FROM factory.employees e WHERE e.deleted_at IS NULL),
    'departments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'name_ar', d.name_ar, 'stage', d.stage,
        'custody_mode', d.custody_mode, 'active', d.active, 'allow_return', d.allow_return,
        'member_count', (SELECT count(*) FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
                          WHERE r.department_id = d.id AND r.active AND e.active)) ORDER BY factory.stage_rank(d.stage) NULLS LAST, d.code), '[]'::jsonb)
      FROM factory.departments d));
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
