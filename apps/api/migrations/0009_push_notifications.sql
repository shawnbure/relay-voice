CREATE TABLE IF NOT EXISTS push_devices (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(tenant_id, user_id, id)
);
CREATE TABLE IF NOT EXISTS notification_items (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  peer TEXT NOT NULL,
  kind TEXT NOT NULL,
  body TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  read_at TEXT
);
CREATE INDEX IF NOT EXISTS notification_unread ON notification_items(tenant_id, read_at, peer);
CREATE TABLE IF NOT EXISTS push_deliveries (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  environment TEXT NOT NULL,
  item_id TEXT REFERENCES notification_items(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt INTEGER NOT NULL DEFAULT 0,
  reason TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS push_pending ON push_deliveries(status, next_attempt);
CREATE TABLE IF NOT EXISTS answered_call_routes (
  inbound_call_control_id TEXT PRIMARY KEY,
  answered_at TEXT NOT NULL
);
