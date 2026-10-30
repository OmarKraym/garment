-- 005_service_and_grants.sql — functions callable ONLY by the Edge Functions (service_role),
-- then the final permission model for every API function.
-- Service functions re-check the caller (taken from a verified JWT by the Edge Function),
-- so a bug in an Edge Function cannot skip the administrator check.

CREATE FUNCTION factory.require_admin(p_caller uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  SELECT e.id INTO v FROM factory.employees e
   WHERE e.auth_user_id = p_caller AND e.active AND NOT e.must_change_password
     AND EXISTS (SELECT 1 FROM factory.employee_roles r WHERE r.employee_id = e.id AND r.role = 'ADMIN' AND r.active);
  IF v IS NULL THEN PERFORM factory.err('FORBIDDEN', 'هذه العملية لمدير النظام فقط'); END IF;
  RETURN v;
END $$;

CREATE FUNCTION public.svc_assert_admin(p_caller uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM factory.require_admin(p_caller);
  RETURN true;
END $$;

CREATE FUNCTION public.svc_username_taken(p_username text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM factory.employees WHERE username = lower(p_username))
$$;

/**
 * Links a newly created auth user to a new employee with roles.
 * p_caller NULL = bootstrap: allowed only while no active administrator exists, and only
 * to create that first administrator.
 */
CREATE FUNCTION public.svc_provision_employee(p_caller uuid, p_auth_user uuid, p_username text, p_display text, p_roles jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_admin uuid; v_id uuid; v_user text := lower(btrim(p_username)); v_name text := btrim(p_display);
BEGIN
  IF p_caller IS NULL THEN
    IF EXISTS (SELECT 1 FROM factory.employee_roles r JOIN factory.employees e ON e.id = r.employee_id
                WHERE r.role = 'ADMIN' AND r.active AND e.active) THEN
      PERFORM factory.err('FORBIDDEN', 'يوجد مدير نظام بالفعل');
    END IF;
    IF p_roles IS DISTINCT FROM '[{"role": "ADMIN"}]'::jsonb THEN
      PERFORM factory.err('INVALID', 'التهيئة الأولى تنشئ مدير النظام فقط');
    END IF;
  ELSE
    v_admin := factory.require_admin(p_caller);
  END IF;
  IF v_user !~ '^[a-z0-9_.]{3,32}$' THEN PERFORM factory.err('INVALID', 'اسم المستخدم: 3–32 حرفاً لاتينياً صغيراً أو أرقام أو _ .'); END IF;
  IF v_name IS NULL OR length(v_name) NOT BETWEEN 1 AND 100 THEN PERFORM factory.err('INVALID', 'الاسم الظاهر مطلوب'); END IF;
  IF jsonb_typeof(p_roles) <> 'array' OR jsonb_array_length(p_roles) = 0 THEN PERFORM factory.err('INVALID', 'اختر دوراً واحداً على الأقل'); END IF;
  IF EXISTS (SELECT 1 FROM factory.employees WHERE username = v_user) THEN PERFORM factory.err('CONFLICT', 'اسم المستخدم مستخدم مسبقاً'); END IF;
  -- An administrator chose this password, so the employee must replace it (bootstrap admin chose their own).
  INSERT INTO factory.employees (auth_user_id, username, display_name, must_change_password)
  VALUES (p_auth_user, v_user, v_name, p_caller IS NOT NULL) RETURNING id INTO v_id;
  PERFORM factory.apply_roles(v_id, p_roles);
  PERFORM factory.audit(v_admin, CASE WHEN p_caller IS NULL THEN 'employee.bootstrap_admin' ELSE 'employee.create' END,
    'employee', v_id::text, NULL, jsonb_build_object('username', v_user, 'displayName', v_name, 'roles', p_roles));
  RETURN jsonb_build_object('id', v_id);
END $$;

CREATE FUNCTION public.svc_employee_auth(p_caller uuid, p_employee uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_admin uuid := factory.require_admin(p_caller); e record;
BEGIN
  SELECT id, auth_user_id, username, active INTO e FROM factory.employees WHERE id = p_employee;
  IF e.id IS NULL OR e.auth_user_id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الموظف غير موجود'); END IF;
  RETURN jsonb_build_object('auth_user_id', e.auth_user_id, 'username', e.username, 'active', e.active, 'is_self', e.id = v_admin);
END $$;

CREATE FUNCTION public.svc_set_employee_active(p_caller uuid, p_employee uuid, p_active boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_admin uuid := factory.require_admin(p_caller); e record; v_held int;
BEGIN
  IF p_employee = v_admin THEN PERFORM factory.err('BUSINESS_RULE', 'لا يمكنك إيقاف حسابك'); END IF;
  SELECT id, auth_user_id INTO e FROM factory.employees WHERE id = p_employee FOR UPDATE;
  IF e.id IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الموظف غير موجود'); END IF;
  IF NOT p_active THEN
    SELECT coalesce(sum(b.qty), 0) INTO v_held FROM factory.stock_balances b JOIN factory.custodies c ON c.id = b.custody_id
     WHERE c.kind = 'EMPLOYEE' AND c.employee_id = p_employee;
    IF v_held > 0 THEN PERFORM factory.err('BUSINESS_RULE', 'لدى الموظف قطع في عهدته؛ انقلها قبل إيقاف الحساب'); END IF;
  END IF;
  UPDATE factory.employees SET active = p_active, updated_at = now() WHERE id = p_employee;
  PERFORM factory.audit(v_admin, CASE WHEN p_active THEN 'employee.activate' ELSE 'employee.deactivate' END, 'employee', p_employee::text, NULL, NULL);
  RETURN jsonb_build_object('auth_user_id', e.auth_user_id);
END $$;

CREATE FUNCTION public.svc_after_password_reset(p_caller uuid, p_employee uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_admin uuid := factory.require_admin(p_caller);
BEGIN
  UPDATE factory.employees SET must_change_password = (id <> v_admin), updated_at = now() WHERE id = p_employee;
  IF NOT FOUND THEN PERFORM factory.err('NOT_FOUND', 'الموظف غير موجود'); END IF;
  PERFORM factory.audit(v_admin, 'employee.password_reset', 'employee', p_employee::text, NULL, NULL);
  RETURN jsonb_build_object('ok', true);
END $$;

/** Called by the account Edge Function only after it verified the current password and set the new one. */
CREATE FUNCTION public.svc_password_changed(p_auth_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v uuid;
BEGIN
  UPDATE factory.employees SET must_change_password = false, updated_at = now()
   WHERE auth_user_id = p_auth_user AND active RETURNING id INTO v;
  IF v IS NULL THEN PERFORM factory.err('NOT_FOUND', 'الحساب غير مرتبط بموظف فعّال'); END IF;
  PERFORM factory.audit(v, 'employee.password_changed', 'employee', v::text, NULL, NULL);
  RETURN jsonb_build_object('ok', true);
END $$;

/** Login helper for the account function: is this auth user an active employee? */
CREATE FUNCTION public.svc_auth_user_active(p_auth_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM factory.employees WHERE auth_user_id = p_auth_user AND active)
$$;

-- ================================================================ permission model
-- Internal engine: nobody but the owner.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA factory FROM PUBLIC;

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
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);   -- signed-in staff only
      ELSE
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);    -- Edge Functions only
      END IF;
    END IF;
  END LOOP;
END $$;

-- GraphQL is not used by this app: remove that API surface where permitted.
DO $$
BEGIN
  DROP EXTENSION IF EXISTS pg_graphql;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'pg_graphql not dropped (%): disable it in Dashboard → Database → Extensions', SQLERRM;
END $$;
