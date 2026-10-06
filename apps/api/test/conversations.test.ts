import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, test } from "vitest";

test("history search and archive scope stay tenant isolated", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`
      CREATE TABLE messages(tenant_id, direction, from_number, to_number, body, status, occurred_at);
      CREATE TABLE calls(tenant_id, direction, from_number, to_number, status, started_at);
      CREATE TABLE voicemails(tenant_id, from_number, status, occurred_at);
      CREATE TABLE contacts(tenant_id, phone_number, display_name);
      CREATE TABLE phone_numbers(tenant_id, e164);
      CREATE TABLE conversation_archives(tenant_id, peer, archived_at);
      CREATE TABLE conversation_mutes(tenant_id, peer, muted_at);
      INSERT INTO messages VALUES
        ('one','inbound','+15551234567','+15557654321','older needle','received','2026-01-01'),
        ('one','outbound','+15557654321','+15551234567','latest text','sent','2026-01-02'),
        ('two','inbound','+15559999999','+15557654321','needle private','received','2026-01-03');
    `);
    const source = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
    const sql = source.slice(source.indexOf('app.get("/v1/conversations"')).match(/prepare\(`([\s\S]*?)`\)/)![1];
    const search = (q = "", archived = 0) => db.prepare(sql).all("one", "one", "one", "one", "one", q, q, q, q, "one", archived, "one");
    expect(search("needle")).toHaveLength(1);
    expect(search("nonexistent")).toHaveLength(0);
    db.exec("INSERT INTO conversation_archives VALUES ('one','+15551234567','2026-01-04')");
    expect(search()).toHaveLength(0);
    expect(search("needle", 1)).toHaveLength(1);
    db.exec("INSERT INTO messages VALUES ('one','inbound','+15551234567','+15557654321','new activity','received','2026-01-05')");
    expect(search()).toHaveLength(1);
    expect(search("", 1)).toHaveLength(0);
  } finally { db.close(); }
});
