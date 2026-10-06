CREATE TABLE IF NOT EXISTS conversation_mutes (
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  peer TEXT NOT NULL,
  muted_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, peer)
);

