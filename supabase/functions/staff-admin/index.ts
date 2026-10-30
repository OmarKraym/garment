import { handleStaffAdmin } from "../_shared/handlers.js";
import { realDeps } from "../_shared/deps.ts";

// Built on first request so a missing secret returns a clear error instead of crashing the function.
let deps: ReturnType<typeof realDeps> | undefined;
Deno.serve((req) => {
  try {
    deps ??= realDeps();
  } catch (e) {
    console.error("configuration error", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ error: { code: "CONFIG", message: "الخادم غير مهيأ بعد. راجع إعدادات دوال Edge." } }),
      { status: 500, headers: { "Content-Type": "application/json; charset=utf-8" } });
  }
  return handleStaffAdmin(req, deps);
});
