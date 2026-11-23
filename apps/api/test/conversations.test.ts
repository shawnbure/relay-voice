import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, test } from "vitest";

test("history search and archive scope stay tenant isolated", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`
      CREATE TABLE messages(tenant_id, direction, from_number, to_number, body, status, occurred_at);
      CREATE TABLE calls(tenant_id, direction, from_number, to_number, status, started_at);
      CREATE TABLE voicemails(tenant_id, from_number, to_number, status, occurred_at);
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
    const search = (q = "", archived = 0, line = "") => db.prepare(sql).all("one", "one", "one", line, line, "one", "one", q, q, q, q, "one", archived, "one");
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

test("each line shows only its own conversations", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`
      CREATE TABLE messages(tenant_id, direction, from_number, to_number, body, status, occurred_at);
      CREATE TABLE calls(tenant_id, direction, from_number, to_number, status, started_at);
      CREATE TABLE voicemails(tenant_id, from_number, to_number, status, occurred_at);
      CREATE TABLE contacts(tenant_id, phone_number, display_name);
      CREATE TABLE phone_numbers(tenant_id, e164);
      CREATE TABLE conversation_archives(tenant_id, peer, archived_at);
      CREATE TABLE conversation_mutes(tenant_id, peer, muted_at);
      INSERT INTO phone_numbers VALUES ('one','+15550000001'),('one','+15550000002');
      INSERT INTO messages VALUES
        ('one','inbound','+15551111111','+15550000001','to line one','received','2026-01-01'),
        ('one','outbound','+15550000002','+15552222222','from line two','sent','2026-01-02');
      INSERT INTO calls VALUES ('one','inbound','+15553333333','+15550000002','hangup','2026-01-03');
      INSERT INTO voicemails VALUES ('one','+15554444444','+15550000001','ready','2026-01-04');
    `);
    const source = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
    const sql = source.slice(source.indexOf('app.get("/v1/conversations"')).match(/prepare\(`([\s\S]*?)`\)/)![1];
    const list = (line: string) => (db.prepare(sql).all("one", "one", "one", line, line, "one", "one", "", "", "", "", "one", 0, "one") as Array<{ peer: string; line: string }>);
    expect(list("").map((r) => r.peer)).toEqual(["+15554444444", "+15553333333", "+15552222222", "+15551111111"]);
    expect(list("+15550000001").map((r) => r.peer)).toEqual(["+15554444444", "+15551111111"]);
    expect(list("+15550000002").map((r) => [r.peer, r.line])).toEqual([["+15553333333", "+15550000002"], ["+15552222222", "+15550000002"]]);
  } finally { db.close(); }
});
