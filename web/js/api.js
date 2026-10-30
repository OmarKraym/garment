// Supabase access. The browser can ONLY call app_* database functions and the two Edge Functions;
// it has no table access. Errors are mapped to Arabic messages coming from the server.
import { CONFIG } from "./config.js";

let client;
export function sb() {
  if (!client) {
    client = window.supabase.createClient(CONFIG.supabaseUrl, CONFIG.supabaseAnonKey, {
      auth: {
        storage: window.sessionStorage, // session ends when the tab closes (shared factory phones)
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false,
      },
    });
  }
  return client;
}

export class ApiError extends Error {
  constructor(code, message, transient = false) {
    super(message);
    this.code = code;
    this.transient = transient;
  }
}

const TRANSIENT_SQL = new Set(["40001", "40P01", "55P03"]);

function mapError(error) {
  if (!error) return null;
  const code = error.hint || error.code || "";
  if (TRANSIENT_SQL.has(code)) return new ApiError("BUSY", "النظام مشغول بعملية أخرى على نفس القطع؛ أعد المحاولة", true);
  if (code === "42501") return new ApiError("FORBIDDEN", "ليست لديك صلاحية لهذه العملية");
  if (code === "PGRST301" || code === "PGRST303" || /JWT/i.test(error.message ?? "")) {
    return new ApiError("UNAUTHENTICATED", "انتهت الجلسة. سجّل الدخول من جديد");
  }
  if (!code && /fetch|network|Failed/i.test(error.message ?? "")) {
    return new ApiError("NETWORK", "تعذر الاتصال بالخادم. لم يتأكد حفظ العملية — أعد المحاولة بنفس الزر ولن تُسجل مرتين.", true);
  }
  // Business errors carry an Arabic message written by the database function.
  if (/^[A-Z_]+$/.test(code)) return new ApiError(code, error.message);
  return new ApiError("INTERNAL_ERROR", "خطأ غير متوقع. إذا تكرر أبلغ مدير النظام.");
}

/** Calls public.<fn>. Retries transient lock conflicts (safe: writes are idempotent by requestKey). */
export async function rpc(fn, args = {}) {
  for (let attempt = 1; ; attempt++) {
    let res;
    try {
      res = await sb().rpc(fn, args);
    } catch (e) {
      res = { error: { message: String(e?.message ?? e) } };
    }
    const err = mapError(res.error);
    if (!err) return res.data;
    if (err.code === "UNAUTHENTICATED") window.dispatchEvent(new CustomEvent("auth-lost"));
    if (err.code === "BUSY" && attempt < 3) {
      await new Promise((r) => setTimeout(r, 150 * attempt));
      continue;
    }
    throw err;
  }
}

/** Calls an Edge Function with the user's session. */
export async function edge(name, body) {
  const { data, error } = await sb().functions.invoke(name, { body });
  if (!error) return data;
  let payload = null;
  try { payload = await error.context?.json?.(); } catch { /* ignore */ }
  if (payload?.error) throw new ApiError(payload.error.code, payload.error.message);
  throw new ApiError("NETWORK", "تعذر الاتصال بالخادم. أعد المحاولة.", true);
}

export function newKey() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const x = [...b].map((v) => v.toString(16).padStart(2, "0")).join("");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

/**
 * One logical operation per form. The requestKey stays the SAME across retries (network loss,
 * timeouts) so the server never records it twice; it changes only after a definite outcome.
 */
export function operation() {
  let key = newKey();
  return {
    get key() { return key; },
    async run(fn, args) {
      try {
        const data = await rpc(fn, args(key));
        key = newKey();
        return data;
      } catch (e) {
        if (!(e instanceof ApiError) || !e.transient) key = newKey();
        throw e;
      }
    },
  };
}

export async function signIn(username, password) {
  if (username.includes("@")) throw new ApiError("INVALID", "اكتب اسم المستخدم فقط، بدون @ وبدون بريد إلكتروني.");
  const email = `${username.trim().toLowerCase()}@${CONFIG.staffEmailDomain}`;
  const { error } = await sb().auth.signInWithPassword({ email, password });
  if (!error) return;
  if (error.status === 429) throw new ApiError("RATE_LIMIT", "محاولات كثيرة. انتظر قليلاً ثم أعد المحاولة.");
  if (!error.status) throw new ApiError("NETWORK", "تعذر الاتصال بالخادم. تحقق من الإنترنت ثم أعد المحاولة.");
  throw new ApiError("INVALID", "اسم المستخدم أو كلمة المرور غير صحيحة، أو الحساب موقوف.");
}

export async function signOut() {
  await sb().auth.signOut().catch(() => undefined);
  window.sessionStorage.clear();
}

export async function hasSession() {
  const { data } = await sb().auth.getSession();
  return !!data.session;
}
