# عهدة — Garment WIP custody tracker

Arabic RTL, mobile-first garment custody tracking connected to the existing **garment-production-dev** Supabase project (`vtbenbngmpwzcqmixtzb`). The new frontend consists of `web/index.html` and `web/sw.js`: plain HTML/CSS/JavaScript, no build, frameworks, external fonts or CDN. The manifest and PNG icons are embedded in the HTML.

## Current delivery

The new `wip` database schema is deployed and starts **empty**. Existing `factory` production history, employee records, authentication accounts and Edge Functions remain intact. The new frontend is prepared on `feat/wip-custody-rebuild`; the public site changes only when that branch is merged into `main` and the existing Pages workflow succeeds.

Sign in with the existing factory username and password. `legacy.html#/admin` opens existing staff management; `legacy.html#/account` changes passwords, including temporary passwords. Those retained pages use the existing local assets and SDK. Staff management remains available instead of replacing real authentication with a four-digit browser PIN.

The attachment requested local-only storage, but the user's latest instruction selected Supabase. Therefore production data is shared through Supabase and **writes require connectivity**. `Store` owns local preferences and session storage only. Production snapshots are held in memory, never in localStorage or the service-worker cache. The shell can open offline, but an offline page reload cannot display production data until a connection returns.

## Workflow

1. Supervisor creates an order, chooses color/size chips and planned quantity.
2. Cutter records the **total cut for each color/size**, then sends quantities to named tailors. The order's actual cut total is derived from all lots. This resolves the original prompt's missing per-variant allocation rule.
3. Every destination except cutter receives pending stock. Only confirmed active stock can move onward. Confirm-all runs in one database transaction.
4. Tailor → finishing 1 → press → finishing 2 → warehouse. Return routes are checked in PostgreSQL, require a reason, and obey the shared returns switch. Finishing 1 selects a specific tailor for rework.
5. Warehouse confirmation closes an order only when all cut pieces are active in warehouse and no other positive custody remains.

Returned pieces already back at cutter count as cutter stock. Lowering a variant's cut total is blocked below the quantity **currently outside cutter**, rather than lifetime gross dispatches, which can count a reworked piece multiple times.

## Roles and accounts

Existing ADMIN can operate all stations and manage settings; SUPERVISOR can create orders; REVIEWER can use the audit dashboard. Workers can write only their assigned department, and tailors only their linked custody. Existing sewing employees were automatically linked to tailor records; the initial roster has 20 tailors. Administrators can add/rename/deactivate tailors and link new sewing accounts in Settings. A tailor with stock cannot be deactivated or reassigned to a different account.

All active factory accounts can read the production snapshot; station writes remain restricted. This is a single-factory operational visibility model, not a multi-company or confidential per-worker reporting model.

## Integrity and security

- Public RPC wrappers are `SECURITY INVOKER`. Checked implementations live in the unexposed `wip` schema with a fixed empty search path.
- Every request resolves the current active employee from `auth.uid()` and existing role tables; user-editable metadata is not trusted.
- All new tables have RLS and no direct client table grants. Anonymous users cannot execute WIP RPCs. Client code contains only the existing publishable key.
- One locked settings row serializes writes for this small factory. Stock mutations, confirmations and movement hashes commit atomically. Request IDs prevent duplicate mutation on retry.
- A SHA-256 chain hashes the previous hash plus the exact canonical payload text returned by PostgreSQL. This detects changed exported/client records; it is **not** proof against an administrator who can rewrite the whole database and recompute hashes.
- JSON restore is admin-only and atomic. It checks hashes, variant membership, quantity conservation and the complete movement ledger against restored balances. Invalid imports roll back. Reset/restore require typed confirmation and an additional confirmation dialog, and are logged in the original factory audit log.
- CSV is UTF-8 with BOM and neutralizes spreadsheet-formula prefixes. UI-generated user text is escaped; no inline event-handler strings are used.
- WhatsApp only opens after a user selects the summary action and follows the review link; it never sends a message automatically.

## Validation performed

`tests/wip/database.sql` passed against the real Supabase PostgreSQL database inside a rolled-back transaction: conservation; overspending; pending-stock block; route enforcement; cut lower bound; disabled returns; idempotent retry; request-key payload mismatch; named rework and confirmation; worker role and holder isolation; chain hashes; restore; tampered record rejection; table/function grants; automatic closure.

`tests/wip/dom.cjs` passed using JSDOM with a synthetic fixture: login, create-order form, color chips, all station renders, dashboard, SHA-256 verification and tamper rejection, account binding form and delete guard. This is **not** a visual or real-browser end-to-end test.

`tests/wip/browser.cjs` is supplied for 390px/1440px layouts and offline-shell behavior. It could not run here: Chromium failed with `socket() failed: Operation not permitted`; the separate browser could not reach the local preview. Real Supabase login, PWA installation and responsive appearance still need browser validation.

Strix repository discovery could not complete because authentication repeatedly requested reconnection. No Strix scan was launched and no scan results are claimed.

Supabase Advisor reported deny-by-default RLS/no-policy informational findings and security-definer warnings for the existing API functions and new checked private RPC implementations. It also reported that leaked-password protection is disabled. These are documented findings, not a claim that the project is fully security-audited.

## Running checks

```sh
python -m http.server 8080 --directory web
# In another terminal, with jsdom 26.1.0 available:
node tests/wip/dom.cjs
# With Playwright and a working Chromium installation:
CHROMIUM_PATH=/path/to/chromium node tests/wip/browser.cjs
```

The test fixture is synthetic. The SQL test is intended for an empty WIP database and rolls itself back. It deliberately refuses to seed over real orders. Do not remove that guard.

## What is intentionally not in v1

1. Offline inventory writes or delayed transfer synchronization.
2. Local-only production storage or offline production history after reload.
3. QR/barcode scanning and label printing.
4. Purchasing, payroll or costing.
5. Customer delivery/shipment tracking in the new tracker.
6. Multi-company tenancy within the new WIP schema.
7. A separate new staff-account administration interface; existing administration is retained.
8. WebSocket live updates; open screens refresh every 15 seconds when no form is open.
9. Tamper-proof evidence against a privileged database administrator.
10. Completed browser/installation validation or a completed Strix penetration test.

## Sources

- User attachment: `garment-wip-pwa-prompt.md` and latest instruction to use the existing Supabase project.
- [Supabase database function security](https://supabase.com/docs/guides/database/functions) — checked through Context7.
- [Supabase RLS advisor](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).
- [Supabase security-definer advisor](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).
- [Supabase leaked-password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

The prior application's setup and operating instructions are retained in [LEGACY.md](LEGACY.md).
