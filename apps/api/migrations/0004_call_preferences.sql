CREATE TABLE call_preferences (
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  receive_web INTEGER NOT NULL DEFAULT 1 CHECK (receive_web IN (0, 1)),
  receive_mobile INTEGER NOT NULL DEFAULT 1 CHECK (receive_mobile IN (0, 1)),
  voicemail_enabled INTEGER NOT NULL DEFAULT 1 CHECK (voicemail_enabled IN (0, 1)),
  voicemail_greeting BLOB,
  voicemail_greeting_type TEXT,
  voicemail_updated_at TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (tenant_id, user_id)
);
