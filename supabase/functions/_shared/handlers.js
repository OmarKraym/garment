// Edge Function logic, runtime-independent (runs on Supabase/Deno and in Node tests).
// The service key lives only in the Edge runtime; the browser never sees it.
// Every privileged action is ALSO re-authorized inside the database (svc_* functions).

const USERNAME = /^[a-z0-9_.]{3,32}$/;
const STATUS = { INVALID: 400, UNAUTHENTICATED: 401, FORBIDDEN: 403, NOT_FOUND: 404, CONFLICT: 409, BUSINESS_RULE: 422 };

export class HttpError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}

function cors(req, deps) {
  const origin = req.headers.get("origin");
  const allowed = origin && deps.allowedOrigins.includes(origin);
  return {
    allowed,
    headers: allowed
      ? { "Access-Control-Allow-Origin": origin, "Vary": "Origin",
          "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
          "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Max-Age": "600" }
      : { "Vary": "Origin" },
  };
}

function json(status, body, headers) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...headers, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

/** Password policy for staff accounts (stricter than Supabase's default minimum). */
export function checkPassword(password, username) {
  if (typeof password !== "string" || password.length < 10 || password.length > 72) {
    throw new HttpError(400, "INVALID", "كلمة المرور بين 10 و 72 حرفاً");
  }
  if (!/[A-Za-z]/.test(password) || !/\d/.test(password)) {
    throw new HttpError(400, "INVALID", "كلمة المرور يجب أن تحتوي حروفاً وأرقاماً");
  }
  if (username && password.toLowerCase().includes(username.toLowerCase())) {
    throw new HttpError(400, "INVALID", "كلمة المرور لا يجوز أن تحتوي اسم المستخدم");
  }
}

// No look-alike characters (0/O, 1/l/I) so the password can be read aloud or copied from paper.
const TEMP_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
const TEMP_LIMIT = 256 - (256 % TEMP_ALPHABET.length); // bytes at or above this are discarded

/**
 * One-time password generated on the server with a cryptographic RNG (≈69 bits of entropy),
 * e.g. "Kp7m-X3qa-9Rtd". It satisfies checkPassword and is shown to the administrator once only.
 */
export function generateTempPassword(username = "") {
  for (;;) {
    const out = [];
    while (out.length < 12) {
      const b = crypto.getRandomValues(new Uint8Array(32));
      for (const x of b) if (x < TEMP_LIMIT && out.length < 12) out.push(TEMP_ALPHABET[x % TEMP_ALPHABET.length]); // no modulo bias
    }
    const pw = `${out.slice(0, 4).join("")}-${out.slice(4, 8).join("")}-${out.slice(8).join("")}`;
    try { checkPassword(pw, username); return pw; } catch { /* retry: missing digit/letter or contains username */ }
  }
}

async function readBody(req) {
  const type = req.headers.get("content-type") ?? "";
  if (!type.includes("application/json")) throw new HttpError(400, "INVALID", "يجب إرسال البيانات بصيغة JSON");
  const text = await req.text();
  if (text.length > 20_000) throw new HttpError(400, "INVALID", "حجم الطلب كبير جداً");
  try { return JSON.parse(text); } catch { throw new HttpError(400, "INVALID", "صيغة البيانات غير صالحة"); }
}

async function requireCaller(req, deps) {
  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  const caller = jwt ? await deps.getCaller(jwt) : null; // verified by Supabase Auth, not decoded locally
  if (!caller) throw new HttpError(401, "UNAUTHENTICATED", "يجب تسجيل الدخول");
  return caller;
}

async function rpc(deps, fn, args) {
  try {
    return await deps.rpc(fn, args);
  } catch (e) {
    const code = e?.code;
    if (STATUS[code]) throw new HttpError(STATUS[code], code, e.message);
    throw e;
  }
}

async function wrap(req, deps, handler) {
  const c = cors(req, deps);
  if (req.method === "OPTIONS") return new Response(null, { status: c.allowed ? 204 : 403, headers: c.headers });
  if (!c.allowed) return json(403, { error: { code: "FORBIDDEN", message: "مصدر غير مسموح" } }, c.headers);
  if (req.method !== "POST") return json(405, { error: { code: "INVALID", message: "Method not allowed" } }, c.headers);
  try {
    return json(200, await handler(), c.headers);
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: { code: e.code, message: e.message } }, c.headers);
    deps.log?.("edge function error", e);
    return json(500, { error: { code: "INTERNAL_ERROR", message: "خطأ غير متوقع في الخادم" } }, c.headers);
  }
}

/** Administrator account operations: create, reset password, activate/deactivate. */
export function handleStaffAdmin(req, deps) {
  return wrap(req, deps, async () => {
    const caller = await requireCaller(req, deps);
    const body = await readBody(req);
    switch (body.action) {
      case "create": {
        const username = String(body.username ?? "").trim().toLowerCase();
        const displayName = String(body.displayName ?? "").trim();
        if (!USERNAME.test(username)) throw new HttpError(400, "INVALID", "اسم المستخدم: 3–32 حرفاً لاتينياً صغيراً أو أرقام أو _ .");
        if (!displayName || displayName.length > 100) throw new HttpError(400, "INVALID", "الاسم الظاهر مطلوب");
        if (!Array.isArray(body.roles) || body.roles.length === 0) throw new HttpError(400, "INVALID", "اختر دوراً واحداً على الأقل");
        const password = generateTempPassword(username); // generated here, returned to the admin once, never stored
        // Check admin rights BEFORE touching Supabase Auth.
        await rpc(deps, "svc_assert_admin", { p_caller: caller.id });
        if (await rpc(deps, "svc_username_taken", { p_username: username })) throw new HttpError(409, "CONFLICT", "اسم المستخدم مستخدم مسبقاً");
        const authId = await deps.auth.createUser({
          email: `${username}@${deps.emailDomain}`, password,
          app_metadata: { provisioned_by: caller.id },
        });
        try {
          const res = await rpc(deps, "svc_provision_employee", {
            p_caller: caller.id, p_auth_user: authId, p_username: username, p_display: displayName, p_roles: body.roles,
          });
          return { id: res.id, username, temporaryPassword: password, expiresInHours: 72 };
        } catch (e) {
          await deps.auth.deleteUser(authId).catch(() => undefined); // no orphan logins
          throw e;
        }
      }
      case "reset_password": {
        const info = await rpc(deps, "svc_employee_auth", { p_caller: caller.id, p_employee: body.employeeId });
        if (info.is_self) throw new HttpError(422, "BUSINESS_RULE", "لتغيير كلمة مرورك استخدم صفحة «حسابي»");
        const password = generateTempPassword(info.username);
        await deps.auth.updatePassword(info.auth_user_id, password);
        await rpc(deps, "svc_after_password_reset", { p_caller: caller.id, p_employee: body.employeeId });
        return { username: info.username, temporaryPassword: password, expiresInHours: 72 };
      }
      case "set_active": {
        if (typeof body.active !== "boolean") throw new HttpError(400, "INVALID", "قيمة غير صالحة");
        const res = await rpc(deps, "svc_set_employee_active", { p_caller: caller.id, p_employee: body.employeeId, p_active: body.active });
        await deps.auth.setBanned(res.auth_user_id, !body.active); // DB check already blocks instantly; ban stops new sign-ins
        return { ok: true };
      }
      default:
        throw new HttpError(400, "INVALID", "عملية غير معروفة");
    }
  });
}

/** Self-service: change own password (verifies the current one first). */
export function handleAccount(req, deps) {
  return wrap(req, deps, async () => {
    const caller = await requireCaller(req, deps);
    const body = await readBody(req);
    if (body.action !== "change_password") throw new HttpError(400, "INVALID", "عملية غير معروفة");
    if (!(await rpc(deps, "svc_auth_user_active", { p_auth_user: caller.id }))) {
      throw new HttpError(401, "UNAUTHENTICATED", "الحساب غير مفعّل");
    }
    const username = String(caller.email ?? "").split("@")[0];
    checkPassword(body.newPassword, username);
    if (body.newPassword === body.currentPassword) throw new HttpError(400, "INVALID", "اختر كلمة مرور مختلفة عن الحالية");
    if (typeof body.currentPassword !== "string" || !(await deps.auth.verifyPassword(caller.email, body.currentPassword))) {
      throw new HttpError(400, "INVALID", "كلمة المرور الحالية غير صحيحة");
    }
    await deps.auth.updatePassword(caller.id, body.newPassword);
    await rpc(deps, "svc_password_changed", { p_auth_user: caller.id });
    return { ok: true };
  });
}
