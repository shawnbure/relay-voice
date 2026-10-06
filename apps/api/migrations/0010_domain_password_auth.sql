CREATE TABLE IF NOT EXISTS tenant_domains (
  hostname TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS tenant_domains_tenant_idx ON tenant_domains(tenant_id);

CREATE TABLE IF NOT EXISTS password_attempts (
  id TEXT PRIMARY KEY,
  hostname TEXT NOT NULL,
  client_hash TEXT NOT NULL,
  succeeded INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS password_attempts_window_idx ON password_attempts(hostname, client_hash, created_at);
