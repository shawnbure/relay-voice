ALTER TABLE messages ADD COLUMN delivered_at TEXT;

-- For inbound messages, receipt by Relay is the delivery event.
UPDATE messages
SET delivered_at = occurred_at
WHERE direction = 'inbound' AND delivered_at IS NULL;
