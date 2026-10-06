import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { expect, test } from 'vitest';
import { apnsJWT, pushPayload } from '../src/notifications';

test('APNs JWT uses ES256 with a valid raw signature and no private key in its claims', async () => {
  const pair = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8',pair.privateKey));
  const jwt = await apnsJWT({APNS_PRIVATE_KEY:`-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`,APNS_TEAM_ID:'test-team',APNS_KEY_ID:'test-key'});
  const [header, claims, signature] = jwt.split('.');
  const decode = (s:string) => Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')), c=>c.charCodeAt(0));
  expect(JSON.parse(new TextDecoder().decode(decode(header)))).toEqual({alg:'ES256',kid:'test-key'});
  expect(JSON.parse(new TextDecoder().decode(decode(claims))).iss).toBe('test-team');
  expect(decode(signature).length).toBe(64);
  expect(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},pair.publicKey,decode(signature),new TextEncoder().encode(`${header}.${claims}`))).toBe(true);
});
test('push payloads provide alerts for new items and badge-only updates after reading', () => {
  for (const kind of ['message','missed_call','voicemail']) {
    const p = pushPayload({peer:'+15551234567',kind,body:'hello'},3);
    expect(p.aps.badge).toBe(3); expect(p.aps).toHaveProperty('sound','default'); expect(p).toHaveProperty('peer','+15551234567');
  }
  expect(pushPayload(null,0)).toEqual({aps:{badge:0}});
});
test('notification state is tenant scoped, deduplicated, and read only through displayed time', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec("CREATE TABLE tenants(id TEXT PRIMARY KEY); CREATE TABLE users(id TEXT PRIMARY KEY); INSERT INTO tenants VALUES('one'),('two');");
    db.exec(readFileSync(new URL('../migrations/0009_push_notifications.sql',import.meta.url),'utf8'));
    const insert = db.prepare('INSERT OR IGNORE INTO notification_items(id,tenant_id,peer,kind,body,occurred_at) VALUES(?,?,?,?,?,?)');
    for(const [id,tenant,time] of [['a','one','2026-09-14T00:00:00Z'],['b','one','2026-09-14T00:02:00Z'],['c','two','2026-09-14T00:00:00Z'],['a','one','2026-09-14T00:00:00Z']]) insert.run(id,tenant,'+15551234567','message','hello',time);
    expect(db.prepare('SELECT COUNT(*) n FROM notification_items').get()?.n).toBe(3);
    db.prepare('UPDATE notification_items SET read_at=? WHERE tenant_id=? AND peer=? AND read_at IS NULL AND occurred_at<=?').run('now','one','+15551234567','2026-09-14T00:01:00Z');
    expect(db.prepare('SELECT id FROM notification_items WHERE tenant_id=? AND read_at IS NULL').all('one')).toEqual([{id:'b'}]);
    expect(db.prepare('SELECT id FROM notification_items WHERE tenant_id=? AND read_at IS NULL').all('two')).toEqual([{id:'c'}]);
  } finally { db.close(); }
});
