-- The Mac app gets its own "ring on" switch, separate from the iPhone app.
ALTER TABLE call_preferences ADD COLUMN receive_desktop INTEGER NOT NULL DEFAULT 1;
