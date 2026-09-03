ALTER TABLE messages ADD COLUMN media_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE voicemails (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  telnyx_recording_id TEXT NOT NULL UNIQUE,
  telnyx_call_control_id TEXT,
  from_number TEXT NOT NULL,
  to_number TEXT NOT NULL,
  duration_seconds INTEGER,
  status TEXT NOT NULL,
  object_key TEXT,
  content_type TEXT,
  occurred_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX voicemails_tenant_occurred_idx ON voicemails(tenant_id, occurred_at DESC);
