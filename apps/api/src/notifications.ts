type PushDevice = { token: string; environment: 'sandbox' | 'production' };
type Delivery = PushDevice & { id: string; tenant_id: string; item_id: string | null; attempts: number; created_at: number };
export async function unreadState(env: Env, tenantId: string) {
  const rows = await env.DB.prepare('SELECT peer, COUNT(*) count FROM notification_items WHERE tenant_id=? AND read_at IS NULL GROUP BY peer').bind(tenantId).all<{ peer: string; count: number }>();
  return { count: rows.results.reduce((n, r) => n + r.count, 0), peers: Object.fromEntries(rows.results.map(r => [r.peer, r.count])) };
}
export async function enqueueNotification(env: Env, item: { id: string; tenantId: string; peer: string; kind: string; body: string; at: string }) {
  const inserted = await env.DB.prepare('INSERT OR IGNORE INTO notification_items(id,tenant_id,peer,kind,body,occurred_at) VALUES(?,?,?,?,?,?)').bind(item.id, item.tenantId, item.peer, item.kind, item.body.slice(0, 180), item.at).run();
  if (!inserted.meta.changes) return;
  await enqueueDeliveries(env, item.tenantId, item.id);
}
export async function enqueueDeliveries(env: Env, tenantId: string, itemId: string | null) {
  const devices = await env.DB.prepare('SELECT DISTINCT token,environment FROM push_devices WHERE tenant_id=?').bind(tenantId).all<PushDevice>();
  if (devices.results.length) await env.DB.batch(devices.results.map(d => env.DB.prepare('INSERT INTO push_deliveries(id,tenant_id,token,environment,item_id,created_at) VALUES(?,?,?,?,?,?)').bind(crypto.randomUUID(), tenantId, d.token, d.environment, itemId, Date.now())));
}
function base64url(bytes: Uint8Array) { return btoa(String.fromCharCode(...bytes)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_'); }
export async function apnsJWT(env: Pick<Env, 'APNS_PRIVATE_KEY' | 'APNS_TEAM_ID' | 'APNS_KEY_ID'>) {
  if (!env.APNS_PRIVATE_KEY || !env.APNS_TEAM_ID || !env.APNS_KEY_ID) throw new Error('APNs credentials are not configured');
  const pem = env.APNS_PRIVATE_KEY.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const enc = new TextEncoder();
  const input = `${base64url(enc.encode(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID })))}.${base64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now()/1000) })))}`;
  return `${input}.${base64url(new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(input))))}`;
}
export function pushPayload(item: { peer: string; kind: string; body: string } | null, badge: number, muted = false) {
  const title = item?.kind === 'voicemail' ? 'New voicemail' : item?.kind === 'missed_call' ? 'Missed call' : 'New message';
  return { aps: { badge, ...(item && !muted ? { alert: { title, body: `${item.peer}: ${item.body}` }, sound: 'default', 'thread-id': item.peer } : item && muted ? { 'content-available': 1 } : {}) }, ...(item ? { peer: item.peer, kind: item.kind } : {}) };
}
export async function drainPushes(env: Env) {
  if (!env.APNS_PRIVATE_KEY || !env.APNS_BUNDLE_ID) return;
  const rows = await env.DB.prepare("SELECT * FROM push_deliveries WHERE status='pending' AND next_attempt<=? ORDER BY created_at LIMIT 30").bind(Date.now()).all<Delivery>();
  if (!rows.results.length) return;
  const jwt = await apnsJWT(env);
  for (const d of rows.results) {
    // A lease prevents concurrent webhook/cron invocations sending the same row.
    const lease = await env.DB.prepare("UPDATE push_deliveries SET next_attempt=?,attempts=attempts+1 WHERE id=? AND status='pending' AND next_attempt<=?").bind(Date.now()+60000, d.id, Date.now()).run();
    if (!lease.meta.changes) continue;
    try {
      const item = d.item_id ? await env.DB.prepare('SELECT peer,kind,body,read_at FROM notification_items WHERE id=? AND tenant_id=?').bind(d.item_id, d.tenant_id).first<{peer:string;kind:string;body:string;read_at:string|null}>() : null;
      const badge = (await unreadState(env, d.tenant_id)).count;
      const muted = item ? Boolean(await env.DB.prepare('SELECT 1 muted FROM conversation_mutes WHERE tenant_id=? AND peer=?').bind(d.tenant_id, item.peer).first()) : false;
      const host = d.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
      const response = await fetch(`https://${host}/3/device/${d.token}`, { method: 'POST', headers: { authorization: `bearer ${jwt}`, 'apns-topic': env.APNS_BUNDLE_ID, 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-id': d.id, 'apns-expiration': String(Math.floor((d.created_at+86400000)/1000)), 'content-type': 'application/json' }, body: JSON.stringify(pushPayload(item?.read_at == null ? item : null, badge, muted)), signal: AbortSignal.timeout(10000) });
      const reason = response.ok ? null : (await response.json<{reason?:string}>()).reason ?? String(response.status);
      if (response.status === 410 || reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic') await env.DB.prepare('DELETE FROM push_devices WHERE tenant_id=? AND token=? AND environment=?').bind(d.tenant_id, d.token, d.environment).run();
      const terminal = response.ok || (response.status >= 400 && response.status < 500 && ![403,429].includes(response.status)) || d.attempts >= 9 || Date.now()-d.created_at > 86400000;
      await env.DB.prepare('UPDATE push_deliveries SET status=?,reason=?,next_attempt=? WHERE id=?').bind(response.ok ? 'sent' : terminal ? 'failed' : 'pending', reason, Date.now()+Math.min(3600000, 60000*2**d.attempts), d.id).run();
      console.log(JSON.stringify({event:'apns_delivery', deliveryId:d.id, status:response.status, reason}));
    } catch (error) {
      await env.DB.prepare("UPDATE push_deliveries SET status=?,reason='transport_error',next_attempt=? WHERE id=?").bind(d.attempts>=9 ? 'failed':'pending',Date.now()+Math.min(3600000,60000*2**d.attempts),d.id).run();
      console.error(JSON.stringify({event:'apns_transport_error',deliveryId:d.id,error:String(error)}));
    }
  }
}
