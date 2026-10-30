// Test helper: a fresh database with the Supabase shim + all migrations, and helpers that
// call API functions EXACTLY like PostgREST does (SET ROLE + JWT claims, one transaction).
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import pg from "pg";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const ADMIN_URL = process.env.TEST_DATABASE_ADMIN_URL ?? "postgres://postgres@127.0.0.1:5432/postgres";

export async function applyMigrations(client) {
  const dir = path.join(ROOT, "supabase", "migrations");
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".sql")).sort()) {
    try {
      await client.query(fs.readFileSync(path.join(dir, f), "utf8"));
    } catch (e) {
      throw new Error(`${f}: ${e.message}`);
    }
  }
}

export async function createTestDb() {
  const name = `garment_web_test_${crypto.randomBytes(4).toString("hex")}`;
  const admin = new pg.Client({ connectionString: ADMIN_URL });
  await admin.connect();
  await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  const url = ADMIN_URL.replace(/\/[^/]*$/, `/${name}`);
  const setup = new pg.Client({ connectionString: url });
  await setup.connect();
  await setup.query(fs.readFileSync(path.join(ROOT, "tests", "supabase-shim.sql"), "utf8"));
  await applyMigrations(setup);
  await setup.query(fs.readFileSync(path.join(ROOT, "supabase", "seed.sql"), "utf8"));
  await setup.end();
  const pool = new pg.Pool({ connectionString: url, max: 20 });
  pool.on("error", () => undefined);

  /** Call public.<fn> as an API role, like PostgREST: role + claims are transaction-local. */
  async function callAs(role, sub, fn, args = {}) {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(`SET LOCAL ROLE ${role}`);
      await client.query("SELECT set_config('request.jwt.claims', $1, true)", [
        JSON.stringify(sub ? { sub, role } : { role }),
      ]);
      const names = Object.keys(args);
      const sql = `SELECT public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(", ")}) AS r`;
      const { rows } = await client.query(sql, names.map((n) => (args[n] !== null && typeof args[n] === "object" ? JSON.stringify(args[n]) : args[n])));
      await client.query("COMMIT");
      return rows[0].r;
    } catch (e) {
      await client.query("ROLLBACK").catch(() => undefined);
      const err = new Error(e.message);
      err.code = e.hint ?? e.code; // business code (HINT) or SQLSTATE
      err.sqlstate = e.code;
      throw err;
    } finally {
      client.release();
    }
  }

  /** Creates an auth user + employee (through the real service function) and returns a caller. */
  async function makeUser(username, roles, { caller = null } = {}) {
    const { rows } = await pool.query("INSERT INTO auth.users (email) VALUES ($1) RETURNING id", [`${username}@staff.factory.invalid`]);
    const authId = rows[0].id;
    const res = await callAs("service_role", null, "svc_provision_employee", {
      p_caller: caller, p_auth_user: authId, p_username: username, p_display: username, p_roles: roles,
    });
    // test users start ready to work (tests of the forced change set it explicitly)
    await pool.query("UPDATE factory.employees SET must_change_password = false WHERE id = $1", [res.id]);
    const user = {
      authId, employeeId: res.id, username,
      call: (fn, args) => callAs("authenticated", authId, fn, args),
    };
    return user;
  }

  const depts = Object.fromEntries((await pool.query("SELECT code, id FROM factory.departments")).rows.map((r) => [r.code, r.id]));

  return {
    name, url, pool, callAs, makeUser, depts,
    async close() {
      await pool.end();
      const c = new pg.Client({ connectionString: ADMIN_URL });
      await c.connect();
      await c.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
      await c.end();
    },
  };
}

export const key = () => crypto.randomUUID();
