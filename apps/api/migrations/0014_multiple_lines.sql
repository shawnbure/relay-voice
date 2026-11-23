-- A workspace can own several numbers ("lines"). Each gets an optional label,
-- and unread items remember which line they arrived on.
ALTER TABLE phone_numbers ADD COLUMN label TEXT;
ALTER TABLE notification_items ADD COLUMN line TEXT;

-- Existing workspaces have exactly one number, so older unread items belong to it.
UPDATE notification_items
SET line = (SELECT p.e164 FROM phone_numbers p WHERE p.tenant_id = notification_items.tenant_id ORDER BY p.created_at LIMIT 1)
WHERE line IS NULL;

CREATE INDEX IF NOT EXISTS notification_unread_line ON notification_items(tenant_id, line, read_at);
