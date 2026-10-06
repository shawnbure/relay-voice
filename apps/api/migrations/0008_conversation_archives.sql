CREATE TABLE IF NOT EXISTS conversation_archives (
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  peer TEXT NOT NULL,
  archived_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, peer)
);
