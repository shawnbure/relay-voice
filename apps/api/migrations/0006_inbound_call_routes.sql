CREATE TABLE inbound_call_routes (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  inbound_call_control_id TEXT NOT NULL UNIQUE,
  client_call_control_id TEXT UNIQUE,
  caller_number TEXT NOT NULL,
  relay_number TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX inbound_call_routes_tenant_idx ON inbound_call_routes(tenant_id, created_at DESC);
