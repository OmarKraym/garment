-- 001_schema.sql — tables, constraints and database-level integrity rules.
-- Identity: Supabase Auth (auth.users). Business data: schema `factory` (NOT exposed).
-- Quantity rules enforced here hold even if application code is wrong.

CREATE SCHEMA IF NOT EXISTS factory;

-- Production route in fixed order (blueprint §1). Non-production departments have NULL stage.
CREATE TYPE factory.stage AS ENUM ('CUTTING', 'SEWING', 'FINISHING_1', 'IRONING', 'FINISHING_2', 'WAREHOUSE');
CREATE TYPE factory.custody_mode AS ENUM ('SHARED', 'INDIVIDUAL');
-- Global roles (ADMIN, SUPERVISOR, REVIEWER) have no department; WORKER is department-scoped.
CREATE TYPE factory.app_role AS ENUM ('ADMIN', 'SUPERVISOR', 'REVIEWER', 'WORKER');
CREATE TYPE factory.order_status AS ENUM ('DRAFT', 'RELEASED', 'CLOSED', 'CANCELLED');

CREATE TABLE factory.departments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_]{2,32}$'),
  name_ar       text NOT NULL CHECK (length(btrim(name_ar)) BETWEEN 1 AND 100),
  stage         factory.stage,
  custody_mode  factory.custody_mode NOT NULL DEFAULT 'SHARED',
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE factory.employees (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id  uuid UNIQUE REFERENCES auth.users (id),
  username      text NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9_.]{3,32}$'),
  display_name  text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 100),
  active        boolean NOT NULL DEFAULT true,
  -- set when an administrator chose the password; cleared after the employee changes it
  must_change_password boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE factory.employee_roles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   uuid NOT NULL REFERENCES factory.employees (id),
  role          factory.app_role NOT NULL,
  department_id uuid REFERENCES factory.departments (id),
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_roles_scope CHECK ((role = 'WORKER') = (department_id IS NOT NULL)),
  CONSTRAINT employee_roles_unique UNIQUE NULLS NOT DISTINCT (employee_id, role, department_id)
);
CREATE INDEX employee_roles_department_idx ON factory.employee_roles (department_id) WHERE active;

CREATE TABLE factory.customers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  text NOT NULL UNIQUE CHECK (length(btrim(display_name)) BETWEEN 1 AND 150),
  contact       text CHECK (contact IS NULL OR length(contact) <= 200),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE factory.orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_code    text NOT NULL UNIQUE CHECK (order_code ~ '^[A-Za-z0-9_-]{2,40}$'),
  customer_id   uuid NOT NULL REFERENCES factory.customers (id),
  product_name  text NOT NULL CHECK (length(btrim(product_name)) BETWEEN 1 AND 150),
  model_code    text CHECK (model_code IS NULL OR length(model_code) <= 60),
  due_date      date NOT NULL,
  status        factory.order_status NOT NULL DEFAULT 'DRAFT',
  notes         text CHECK (notes IS NULL OR length(notes) <= 2000),
  created_by    uuid NOT NULL REFERENCES factory.employees (id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  released_by   uuid REFERENCES factory.employees (id),
  released_at   timestamptz,
  closed_at     timestamptz,
  CONSTRAINT orders_release_consistency CHECK ((status = 'DRAFT') OR (status = 'CANCELLED') OR released_at IS NOT NULL)
);
CREATE INDEX orders_due_status_idx ON factory.orders (due_date, status);

CREATE TABLE factory.order_lines (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      uuid NOT NULL REFERENCES factory.orders (id),
  color         text NOT NULL CHECK (length(btrim(color)) BETWEEN 1 AND 50),
  size          text NOT NULL CHECK (length(btrim(size)) BETWEEN 1 AND 20),
  planned_qty   integer NOT NULL CHECK (planned_qty > 0 AND planned_qty <= 1000000),
  CONSTRAINT order_lines_variant_unique UNIQUE (order_id, color, size)
);
CREATE INDEX order_lines_order_idx ON factory.order_lines (order_id);


CREATE TYPE factory.custody_kind AS ENUM ('DEPARTMENT', 'EMPLOYEE', 'TRANSIT', 'DISPUTE');
CREATE TYPE factory.stock_condition AS ENUM ('GOOD', 'DEFECTIVE');
CREATE TYPE factory.stock_event_kind AS ENUM (
  'CUT', 'DISPATCH', 'ACCEPT', 'DISPUTE', 'REJECT_RETURN',
  'DISPUTE_ACCEPT', 'DISPUTE_RETURN', 'DEFECT_MARK', 'REPAIR', 'SCRAP', 'SHIPMENT',
  'ADJUSTMENT'
);
CREATE TYPE factory.transfer_direction AS ENUM ('FORWARD', 'INTERNAL', 'RETURN');
CREATE TYPE factory.transfer_state AS ENUM (
  'DISPATCHED', 'PARTIALLY_ACCEPTED', 'DISPUTED', 'ACCEPTED', 'RETURNED', 'CLOSED'
);
CREATE TYPE factory.assignment_status AS ENUM ('ASSIGNED', 'IN_PROGRESS', 'DONE', 'CANCELLED');

CREATE TABLE factory.custodies (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          factory.custody_kind NOT NULL,
  department_id uuid REFERENCES factory.departments (id),
  employee_id   uuid REFERENCES factory.employees (id),
  transfer_id   uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT custodies_shape CHECK (
    (kind = 'DEPARTMENT' AND department_id IS NOT NULL AND employee_id IS NULL AND transfer_id IS NULL) OR
    (kind = 'EMPLOYEE'   AND department_id IS NOT NULL AND employee_id IS NOT NULL AND transfer_id IS NULL) OR
    (kind IN ('TRANSIT', 'DISPUTE') AND transfer_id IS NOT NULL AND department_id IS NULL AND employee_id IS NULL)
  )
);
CREATE UNIQUE INDEX custodies_department_uq ON factory.custodies (department_id) WHERE kind = 'DEPARTMENT';
CREATE UNIQUE INDEX custodies_employee_uq ON factory.custodies (department_id, employee_id) WHERE kind = 'EMPLOYEE';
CREATE UNIQUE INDEX custodies_transfer_uq ON factory.custodies (transfer_id, kind) WHERE transfer_id IS NOT NULL;

CREATE TABLE factory.cut_lots (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_code        text NOT NULL UNIQUE,
  order_line_id   uuid NOT NULL REFERENCES factory.order_lines (id),
  created_qty     integer NOT NULL CHECK (created_qty > 0),
  is_replacement  boolean NOT NULL DEFAULT false,
  replacement_disposition_id uuid, -- FK added in 003
  initial_custody_id uuid NOT NULL REFERENCES factory.custodies (id),
  created_by      uuid NOT NULL REFERENCES factory.employees (id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  notes           text CHECK (notes IS NULL OR length(notes) <= 500),
  CONSTRAINT cut_lots_replacement_link CHECK (is_replacement = (replacement_disposition_id IS NOT NULL))
);
CREATE INDEX cut_lots_order_line_idx ON factory.cut_lots (order_line_id);

CREATE TABLE factory.transfers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_code      text NOT NULL UNIQUE,
  lot_id             uuid NOT NULL REFERENCES factory.cut_lots (id),
  condition          factory.stock_condition NOT NULL,
  from_custody_id    uuid NOT NULL REFERENCES factory.custodies (id),
  to_custody_id      uuid NOT NULL REFERENCES factory.custodies (id),
  from_department_id uuid NOT NULL REFERENCES factory.departments (id),
  to_department_id   uuid NOT NULL REFERENCES factory.departments (id),
  direction          factory.transfer_direction NOT NULL,
  dispatched_qty     integer NOT NULL CHECK (dispatched_qty > 0),
  accepted_qty       integer NOT NULL DEFAULT 0 CHECK (accepted_qty >= 0),
  returned_qty       integer NOT NULL DEFAULT 0 CHECK (returned_qty >= 0),
  pending_qty        integer NOT NULL CHECK (pending_qty >= 0),
  disputed_qty       integer NOT NULL DEFAULT 0 CHECK (disputed_qty >= 0),
  written_off_qty    integer NOT NULL DEFAULT 0 CHECK (written_off_qty >= 0),
  state              factory.transfer_state NOT NULL DEFAULT 'DISPATCHED',
  reason             text CHECK (reason IS NULL OR length(reason) <= 500),
  created_by         uuid NOT NULL REFERENCES factory.employees (id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  closed_at          timestamptz,
  CONSTRAINT transfers_not_self CHECK (from_custody_id <> to_custody_id),
  -- Every dispatched unit is accounted for at all times (blueprint FR-008).
  CONSTRAINT transfers_conservation CHECK (
    accepted_qty + returned_qty + pending_qty + disputed_qty + written_off_qty = dispatched_qty
  ),
  CONSTRAINT transfers_return_reason CHECK (direction <> 'RETURN' OR reason IS NOT NULL)
);
CREATE INDEX transfers_to_state_idx ON factory.transfers (to_custody_id, state);
CREATE INDEX transfers_from_state_idx ON factory.transfers (from_custody_id, state);
CREATE INDEX transfers_open_idx ON factory.transfers (created_at) WHERE pending_qty + disputed_qty > 0;

ALTER TABLE factory.custodies
  ADD CONSTRAINT custodies_transfer_fk FOREIGN KEY (transfer_id) REFERENCES factory.transfers (id);

CREATE TABLE factory.stock_balances (
  lot_id      uuid NOT NULL REFERENCES factory.cut_lots (id),
  custody_id  uuid NOT NULL REFERENCES factory.custodies (id),
  condition   factory.stock_condition NOT NULL,
  qty         integer NOT NULL CHECK (qty >= 0),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lot_id, custody_id, condition)
);
CREATE INDEX stock_balances_custody_idx ON factory.stock_balances (custody_id, lot_id, condition) WHERE qty > 0;

CREATE TABLE factory.stock_events (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                 factory.stock_event_kind NOT NULL,
  lot_id               uuid NOT NULL REFERENCES factory.cut_lots (id),
  qty                  integer NOT NULL CHECK (qty > 0),
  actor_employee_id    uuid NOT NULL REFERENCES factory.employees (id),
  acting_department_id uuid REFERENCES factory.departments (id),
  transfer_id          uuid REFERENCES factory.transfers (id),
  defect_id            uuid,  -- FK added in 003
  shipment_id          uuid,  -- FK added in 003
  adjustment_id        uuid,  -- FK added in 003
  reason               text CHECK (reason IS NULL OR length(reason) <= 1000),
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX stock_events_lot_idx ON factory.stock_events (lot_id, created_at);
CREATE INDEX stock_events_actor_idx ON factory.stock_events (actor_employee_id, created_at);
CREATE INDEX stock_events_created_idx ON factory.stock_events (created_at);

CREATE TABLE factory.stock_journal (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id    uuid NOT NULL REFERENCES factory.stock_events (id),
  lot_id      uuid NOT NULL REFERENCES factory.cut_lots (id),
  custody_id  uuid NOT NULL REFERENCES factory.custodies (id),
  condition   factory.stock_condition NOT NULL,
  delta       integer NOT NULL CHECK (delta <> 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX stock_journal_lot_idx ON factory.stock_journal (lot_id, created_at);
CREATE INDEX stock_journal_event_idx ON factory.stock_journal (event_id);

CREATE TABLE factory.transfer_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id       uuid NOT NULL REFERENCES factory.transfers (id),
  kind              factory.stock_event_kind NOT NULL,
  qty               integer NOT NULL CHECK (qty > 0),
  actor_employee_id uuid NOT NULL REFERENCES factory.employees (id),
  stock_event_id    uuid REFERENCES factory.stock_events (id),
  reason            text CHECK (reason IS NULL OR length(reason) <= 1000),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX transfer_events_transfer_idx ON factory.transfer_events (transfer_id, created_at);

-- Idempotency: a retried request with the same key returns the stored outcome.
CREATE TABLE factory.idempotency_keys (
  actor_employee_id uuid NOT NULL REFERENCES factory.employees (id),
  scope             text NOT NULL,
  request_key       uuid NOT NULL,
  request_hash      text NOT NULL,
  response          jsonb NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_employee_id, scope, request_key)
);

-- Work allocation is an annotation; it never creates or moves physical stock.
CREATE TABLE factory.work_assignments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_line_id  uuid NOT NULL REFERENCES factory.order_lines (id),
  lot_id         uuid REFERENCES factory.cut_lots (id),
  department_id  uuid NOT NULL REFERENCES factory.departments (id),
  employee_id    uuid NOT NULL REFERENCES factory.employees (id),
  assigned_qty   integer NOT NULL CHECK (assigned_qty > 0),
  completed_qty  integer NOT NULL DEFAULT 0 CHECK (completed_qty >= 0),
  status         factory.assignment_status NOT NULL DEFAULT 'ASSIGNED',
  notes          text CHECK (notes IS NULL OR length(notes) <= 500),
  assigned_by    uuid NOT NULL REFERENCES factory.employees (id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT work_assignments_completed_le CHECK (completed_qty <= assigned_qty)
);
CREATE INDEX work_assignments_employee_idx ON factory.work_assignments (employee_id, status);
CREATE INDEX work_assignments_line_idx ON factory.work_assignments (order_line_id);


CREATE TYPE factory.defect_status AS ENUM ('OPEN', 'CLOSED');
CREATE TYPE factory.disposition_decision AS ENUM ('REWORK', 'SCRAP', 'REPLACE');

CREATE TABLE factory.defects (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  defect_code            text NOT NULL UNIQUE,
  lot_id                 uuid NOT NULL REFERENCES factory.cut_lots (id),
  quantity               integer NOT NULL CHECK (quantity > 0),
  repaired_qty           integer NOT NULL DEFAULT 0 CHECK (repaired_qty >= 0),
  scrapped_qty           integer NOT NULL DEFAULT 0 CHECK (scrapped_qty >= 0),
  reason_code            text NOT NULL CHECK (reason_code ~ '^[A-Z_]{2,32}$'),
  description            text CHECK (description IS NULL OR length(description) <= 1000),
  detected_department_id uuid NOT NULL REFERENCES factory.departments (id),
  detected_custody_id    uuid NOT NULL REFERENCES factory.custodies (id),
  responsible_department_id uuid REFERENCES factory.departments (id),
  status                 factory.defect_status NOT NULL DEFAULT 'OPEN',
  reported_by            uuid NOT NULL REFERENCES factory.employees (id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  closed_at              timestamptz,
  CONSTRAINT defects_resolution_le CHECK (repaired_qty + scrapped_qty <= quantity),
  CONSTRAINT defects_closed_consistency CHECK ((status = 'CLOSED') = (repaired_qty + scrapped_qty = quantity))
);
CREATE INDEX defects_lot_idx ON factory.defects (lot_id);
CREATE INDEX defects_open_idx ON factory.defects (created_at) WHERE status = 'OPEN';

CREATE TABLE factory.dispositions (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  defect_id              uuid NOT NULL REFERENCES factory.defects (id),
  decision               factory.disposition_decision NOT NULL,
  quantity               integer NOT NULL CHECK (quantity > 0),
  scrap_custody_id       uuid REFERENCES factory.custodies (id),
  replacement_qty        integer NOT NULL DEFAULT 0 CHECK (replacement_qty >= 0),
  reason                 text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 1000),
  approved_by            uuid NOT NULL REFERENCES factory.employees (id),
  approved_at            timestamptz NOT NULL DEFAULT now(),
  stock_event_id         uuid REFERENCES factory.stock_events (id),
  CONSTRAINT dispositions_shape CHECK (
    (decision = 'REWORK' AND scrap_custody_id IS NULL AND replacement_qty = 0) OR
    (decision = 'SCRAP' AND scrap_custody_id IS NOT NULL AND replacement_qty = 0) OR
    (decision = 'REPLACE' AND scrap_custody_id IS NOT NULL AND replacement_qty = quantity)
  )
);
CREATE INDEX dispositions_defect_idx ON factory.dispositions (defect_id);

ALTER TABLE factory.cut_lots
  ADD CONSTRAINT cut_lots_replacement_fk FOREIGN KEY (replacement_disposition_id) REFERENCES factory.dispositions (id);
-- At most one replacement cut per REPLACE disposition (prevents double replacement).
CREATE UNIQUE INDEX cut_lots_replacement_uq ON factory.cut_lots (replacement_disposition_id) WHERE replacement_disposition_id IS NOT NULL;

CREATE TABLE factory.shipments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_code     text NOT NULL UNIQUE,
  order_id          uuid NOT NULL REFERENCES factory.orders (id),
  customer_id       uuid NOT NULL REFERENCES factory.customers (id),
  delivered_on      date NOT NULL,
  notes             text CHECK (notes IS NULL OR length(notes) <= 500),
  created_by        uuid NOT NULL REFERENCES factory.employees (id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX shipments_order_idx ON factory.shipments (order_id);

CREATE TABLE factory.shipment_lines (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id       uuid NOT NULL REFERENCES factory.shipments (id),
  lot_id            uuid NOT NULL REFERENCES factory.cut_lots (id),
  custody_id        uuid NOT NULL REFERENCES factory.custodies (id),
  quantity          integer NOT NULL CHECK (quantity > 0),
  stock_event_id    uuid NOT NULL REFERENCES factory.stock_events (id),
  CONSTRAINT shipment_lines_lot_unique UNIQUE (shipment_id, lot_id, custody_id)
);

CREATE TABLE factory.stock_adjustments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_id            uuid NOT NULL REFERENCES factory.cut_lots (id),
  custody_id        uuid NOT NULL REFERENCES factory.custodies (id),
  condition         factory.stock_condition NOT NULL,
  signed_qty        integer NOT NULL CHECK (signed_qty <> 0),
  reason            text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 1000),
  reference         text CHECK (reference IS NULL OR length(reference) <= 200),
  transfer_id       uuid REFERENCES factory.transfers (id),
  approved_by       uuid NOT NULL REFERENCES factory.employees (id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX stock_adjustments_lot_idx ON factory.stock_adjustments (lot_id);

ALTER TABLE factory.stock_events
  ADD CONSTRAINT stock_events_defect_fk FOREIGN KEY (defect_id) REFERENCES factory.defects (id),
  ADD CONSTRAINT stock_events_shipment_fk FOREIGN KEY (shipment_id) REFERENCES factory.shipments (id),
  ADD CONSTRAINT stock_events_adjustment_fk FOREIGN KEY (adjustment_id) REFERENCES factory.stock_adjustments (id);

CREATE TABLE factory.audit_events (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_employee_id uuid REFERENCES factory.employees (id),
  action            text NOT NULL,
  target_type       text NOT NULL,
  target_id         text,
  request_id        text,
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_events_target_idx ON factory.audit_events (target_type, target_id, occurred_at);
CREATE INDEX audit_events_occurred_idx ON factory.audit_events (occurred_at);


-- History tables can never be updated or deleted (corrections are new events).
CREATE FUNCTION factory.forbid_history_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'History table %.% is append-only (% blocked)', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'stock_events', 'stock_journal', 'transfer_events', 'audit_events',
    'stock_adjustments', 'dispositions', 'shipment_lines', 'shipments', 'cut_lots'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON factory.%I FOR EACH ROW EXECUTE FUNCTION factory.forbid_history_change()',
      t || '_append_only', t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE TRUNCATE ON factory.%I FOR EACH STATEMENT EXECUTE FUNCTION factory.forbid_history_change()',
      t || '_no_truncate', t);
  END LOOP;
END $$;

-- Records referenced by history may change status but are never deleted.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['orders', 'order_lines', 'transfers', 'defects', 'custodies', 'employees', 'departments', 'customers'] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE DELETE ON factory.%I FOR EACH ROW EXECUTE FUNCTION factory.forbid_history_change()',
      t || '_no_delete', t);
  END LOOP;
END $$;

-- Planned quantities are frozen once an order is released.
CREATE FUNCTION factory.freeze_released_lines() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE s factory.order_status;
BEGIN
  SELECT status INTO s FROM factory.orders WHERE id = COALESCE(NEW.order_id, OLD.order_id);
  IF s <> 'DRAFT' THEN
    RAISE EXCEPTION 'Order lines are frozen after release' USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
CREATE TRIGGER order_lines_frozen BEFORE INSERT OR UPDATE OR DELETE ON factory.order_lines
  FOR EACH ROW EXECUTE FUNCTION factory.freeze_released_lines();

-- Browser API roles get NOTHING on the factory schema: all access is through the
-- RPC functions in 003/004, which check the caller themselves.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA factory FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA factory FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA factory FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA factory REVOKE ALL ON TABLES FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA factory REVOKE ALL ON FUNCTIONS FROM %I', r);
      -- new functions in public are NOT callable by default; each API function opts in
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM %I', r);
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON SCHEMA factory FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- RLS on, no policies: deny-all for any role that is not the table owner.
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'factory' LOOP
    EXECUTE format('ALTER TABLE factory.%I ENABLE ROW LEVEL SECURITY', t.tablename);
  END LOOP;
END $$;
