-- Each number can have an icon (an SF Symbol name) so a combined inbox shows which number a conversation is on.
ALTER TABLE phone_numbers ADD COLUMN icon TEXT;
