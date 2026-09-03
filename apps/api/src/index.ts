import { Hono } from "hono";
import { cors } from "hono/cors";
import { generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse } from "@simplewebauthn/server";
import type { AuthenticationResponseJSON, RegistrationResponseJSON } from "@simplewebauthn/server";
import { clearSession, createSession, requirePrincipal, requireSameOrigin, sha256, type Principal } from "./auth";
import { dialRelayClient, getTelephonyCredentialSipUsername, mintTelnyxToken, sendTelnyxMessage, verifyTelnyxWebhook } from "./telnyx";
export { RelayEvents } from "./events";

type Variables = { principal: Principal };
const app = new Hono<{ Bindings: Env; Variables: Variables }>();
const E164 = /^\+[1-9]\d{7,14}$/;

app.use("/v1/*", cors({ origin: (origin, c) => origin === c.env.WEB_ORIGIN ? origin : c.env.WEB_ORIGIN, credentials: true }));
app.use("/v1/*", requireSameOrigin);
app.get("/health", (c) => c.json({ ok: true }));

app.get("/v1/outbound-media/:token", async (c) => {
  const token = c.req.param("token");
  if (!/^[0-9a-f-]{36}$/.test(token)) return c.notFound();
  return mediaResponse(c.env.MEDIA, `outbound-public/${token}`);
});

app.get("/v1/auth/status", async (c) => {
  const row = await c.env.DB.prepare("SELECT COUNT(*) count FROM passkeys").first<{ count: number }>();
  return c.json({ needsSetup: Number(row?.count ?? 0) === 0 });
});

app.post("/v1/auth/register/options", async (c) => {
  const existing = await c.env.DB.prepare("SELECT COUNT(*) count FROM passkeys").first<{ count: number }>();
  if (Number(existing?.count ?? 0) > 0) return c.json({ error: "registration is closed" }, 409);
  const body = await c.req.json<{ email?: string; displayName?: string; workspaceName?: string }>();
  const email = body.email?.trim().toLowerCase();
  const displayName = body.displayName?.trim();
  const workspaceName = body.workspaceName?.trim();
  if (!email || !/^\S+@\S+\.\S+$/.test(email) || !displayName || !workspaceName) return c.json({ error: "valid email, name, and workspace are required" }, 400);
  const userId = crypto.randomUUID();
  const tenantId = crypto.randomUUID();
  const rp = relyingParty(c.env.WEB_ORIGIN);
  const options = await generateRegistrationOptions({
    rpName: "Relay",
    rpID: rp.id,
    userID: Uint8Array.from(new TextEncoder().encode(userId)),
    userName: email,
    userDisplayName: displayName,
    attestationType: "none",
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
  });
  const challengeId = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + 5 * 60_000).toISOString();
  await c.env.DB.prepare("DELETE FROM passkey_challenges WHERE expires_at <= CURRENT_TIMESTAMP").run();
  await c.env.DB.prepare("INSERT INTO passkey_challenges (id, challenge, kind, payload, expires_at) VALUES (?, ?, 'registration', ?, ?)")
    .bind(challengeId, options.challenge, JSON.stringify({ userId, tenantId, email, displayName, workspaceName }), expiresAt).run();
  return c.json({ challengeId, options });
});

app.post("/v1/auth/register/verify", async (c) => {
  const body = await c.req.json<{ challengeId?: string; credential?: RegistrationResponseJSON }>();
  const pending = await challenge(c.env.DB, body.challengeId, "registration");
  if (!pending || !body.credential) return c.json({ error: "setup request expired; try again" }, 400);
  const existing = await c.env.DB.prepare("SELECT COUNT(*) count FROM passkeys").first<{ count: number }>();
  if (Number(existing?.count ?? 0) > 0) return c.json({ error: "registration is closed" }, 409);
  const rp = relyingParty(c.env.WEB_ORIGIN);
  const verification = await verifyRegistrationResponse({ response: body.credential, expectedChallenge: pending.challenge, expectedOrigin: rp.origin, expectedRPID: rp.id, requireUserVerification: true });
  if (!verification.verified) return c.json({ error: "passkey could not be verified" }, 401);
  const profile = JSON.parse(pending.payload) as { userId: string; tenantId: string; email: string; displayName: string; workspaceName: string };
  const key = verification.registrationInfo.credential;
  await c.env.DB.batch([
    c.env.DB.prepare("INSERT INTO tenants (id, name, slug) VALUES (?, ?, ?)").bind(profile.tenantId, profile.workspaceName, `workspace-${profile.tenantId.slice(0, 8)}`),
    c.env.DB.prepare("INSERT INTO users (id, email, display_name) VALUES (?, ?, ?)").bind(profile.userId, profile.email, profile.displayName),
    c.env.DB.prepare("INSERT INTO memberships (tenant_id, user_id, role) VALUES (?, ?, 'owner')").bind(profile.tenantId, profile.userId),
    c.env.DB.prepare("INSERT INTO passkeys (id, user_id, public_key, counter, transports, device_type, backed_up) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(key.id, profile.userId, key.publicKey.buffer, key.counter, JSON.stringify(key.transports ?? []), verification.registrationInfo.credentialDeviceType, verification.registrationInfo.credentialBackedUp ? 1 : 0),
    c.env.DB.prepare("DELETE FROM passkey_challenges WHERE id = ?").bind(body.challengeId),
    c.env.DB.prepare("INSERT INTO audit_log (id, tenant_id, user_id, action) VALUES (?, ?, ?, 'workspace.created')").bind(crypto.randomUUID(), profile.tenantId, profile.userId),
  ]);
  await createSession(c, profile.userId);
  return c.json({ created: true }, 201);
});

app.post("/v1/auth/login/options", async (c) => {
  const rp = relyingParty(c.env.WEB_ORIGIN);
  const options = await generateAuthenticationOptions({ rpID: rp.id, userVerification: "required", allowCredentials: [] });
  const challengeId = crypto.randomUUID();
  await c.env.DB.prepare("DELETE FROM passkey_challenges WHERE expires_at <= CURRENT_TIMESTAMP").run();
  await c.env.DB.prepare("INSERT INTO passkey_challenges (id, challenge, kind, expires_at) VALUES (?, ?, 'authentication', ?)").bind(challengeId, options.challenge, new Date(Date.now() + 5 * 60_000).toISOString()).run();
  return c.json({ challengeId, options });
});

app.post("/v1/auth/login/verify", async (c) => {
  const body = await c.req.json<{ challengeId?: string; credential?: AuthenticationResponseJSON }>();
  const pending = await challenge(c.env.DB, body.challengeId, "authentication");
  if (!pending || !body.credential) return c.json({ error: "sign-in request expired; try again" }, 400);
  const saved = await c.env.DB.prepare("SELECT id, user_id, public_key, counter, transports FROM passkeys WHERE id = ?").bind(body.credential.id).first<{ id: string; user_id: string; public_key: ArrayBuffer; counter: number; transports: string | null }>();
  if (!saved) return c.json({ error: "passkey is not registered with Relay" }, 401);
  const rp = relyingParty(c.env.WEB_ORIGIN);
  const verification = await verifyAuthenticationResponse({ response: body.credential, expectedChallenge: pending.challenge, expectedOrigin: rp.origin, expectedRPID: rp.id, requireUserVerification: true, credential: { id: saved.id, publicKey: new Uint8Array(saved.public_key), counter: saved.counter, transports: saved.transports ? JSON.parse(saved.transports) : undefined } });
  if (!verification.verified) return c.json({ error: "passkey could not be verified" }, 401);
  await c.env.DB.batch([
    c.env.DB.prepare("UPDATE passkeys SET counter = ? WHERE id = ?").bind(verification.authenticationInfo.newCounter, saved.id),
    c.env.DB.prepare("DELETE FROM passkey_challenges WHERE id = ?").bind(body.challengeId),
  ]);
  await createSession(c, saved.user_id);
  return c.json({ authenticated: true });
});

app.post("/v1/auth/logout", async (c) => { await clearSession(c); return c.json({ authenticated: false }); });

app.post("/v1/webhooks/telnyx", async (c) => {
  const body = await c.req.text();
  const valid = await verifyTelnyxWebhook({ body, signature: c.req.header("telnyx-signature-ed25519"), timestamp: c.req.header("telnyx-timestamp"), publicKey: c.env.TELNYX_PUBLIC_KEY });
  if (!valid) return c.json({ error: "invalid signature" }, 403);
  const envelope = JSON.parse(body) as { data?: { id?: string; event_type?: string; occurred_at?: string; payload?: TelnyxEventPayload } };
  const data = envelope.data;
  if (!data?.id || !data.event_type) return c.json({ error: "invalid event" }, 400);
  const inserted = await c.env.DB.prepare("INSERT OR IGNORE INTO webhook_events (id, event_type) VALUES (?, ?)").bind(data.id, data.event_type).run();
  let tenantId: string | null = null;
  if (inserted.meta.changes > 0 && data.payload) {
    const occurredAt = data.occurred_at ?? new Date().toISOString();
    tenantId = data.event_type.startsWith("message.")
      ? await applyMessageEvent(c.env, c.executionCtx, data.event_type, occurredAt, data.payload)
      : data.event_type === "call.recording.saved"
        ? await applyRecordingEvent(c.env, c.executionCtx, occurredAt, data.payload)
      : data.event_type.startsWith("call.")
        ? await applyAndRouteCallEvent(c.env, data.event_type, occurredAt, data.payload)
        : await resolveEventTenant(c.env.DB, data.payload);
    if (tenantId) c.env.EVENTS.getByName(tenantId).broadcast(JSON.stringify({ type: data.event_type, at: data.occurred_at ?? new Date().toISOString() }));
  }
  console.log(JSON.stringify({ event: "telnyx_webhook_received", eventId: data.id, eventType: data.event_type }));
  return c.json({ received: true }, 200);
});

app.use("/v1/*", requirePrincipal);

app.get("/v1/events", (c) => c.env.EVENTS.getByName(c.get("principal").tenantId).fetch(c.req.raw));

app.post("/v1/mobile/token", async (c) => {
  const p = c.get("principal");
  const body: { deviceName?: string } = await c.req.json<{ deviceName?: string }>().catch(() => ({}));
  const token = `rly_${Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  const expiresAt = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();
  await c.env.DB.prepare("INSERT INTO mobile_api_tokens (id, tenant_id, user_id, token_hash, device_name, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(crypto.randomUUID(), p.tenantId, p.userId, await sha256(token), body.deviceName?.slice(0, 80) || "Relay for iPhone", expiresAt).run();
  return c.json({ token, expiresAt }, 201);
});

app.get("/v1/me", async (c) => {
  const p = c.get("principal");
  const me = await c.env.DB.prepare(`SELECT u.id, u.email, u.display_name, t.id tenant_id, t.name tenant_name, m.role FROM users u JOIN memberships m ON m.user_id=u.id JOIN tenants t ON t.id=m.tenant_id WHERE u.id=? AND t.id=?`).bind(p.userId, p.tenantId).first();
  const phone = await c.env.DB.prepare("SELECT id, e164 FROM phone_numbers WHERE tenant_id = ? ORDER BY created_at LIMIT 1").bind(p.tenantId).first();
  return c.json({ user: me, phone });
});

app.get("/v1/conversations", async (c) => {
  const { tenantId } = c.get("principal");
  const result = await c.env.DB.prepare(`
    WITH activity AS (
      SELECT CASE WHEN direction='inbound' THEN from_number ELSE to_number END peer,
        body, direction, status, occurred_at, 'message' kind
      FROM messages WHERE tenant_id=?
      UNION ALL
      SELECT CASE WHEN direction='inbound' THEN from_number ELSE to_number END peer,
        CASE WHEN direction='inbound' THEN 'Incoming call' ELSE 'Outgoing call' END body,
        direction, status, started_at occurred_at, 'call' kind
      FROM calls WHERE tenant_id=?
      UNION ALL
      SELECT from_number peer, 'Voicemail' body, 'inbound' direction, status, occurred_at, 'voicemail' kind
      FROM voicemails WHERE tenant_id=?
    ), ranked AS (
      SELECT activity.*, ROW_NUMBER() OVER (PARTITION BY peer ORDER BY occurred_at DESC) rn FROM activity
    ) SELECT r.peer, r.body, r.direction, r.status, r.occurred_at, r.kind, COALESCE(c.display_name, r.peer) display_name
      FROM ranked r LEFT JOIN contacts c ON c.tenant_id=? AND c.phone_number=r.peer
      WHERE r.rn=1
        AND r.peer GLOB '+[1-9]*'
        AND r.peer NOT GLOB '*[^0-9+]*'
        AND length(r.peer) BETWEEN 9 AND 16
        AND NOT EXISTS (SELECT 1 FROM phone_numbers owned WHERE owned.tenant_id=? AND owned.e164=r.peer)
      ORDER BY r.occurred_at DESC LIMIT 100
  `).bind(tenantId, tenantId, tenantId, tenantId, tenantId).all();
  return c.json({ data: result.results });
});

app.delete("/v1/conversations", async (c) => {
  const { tenantId } = c.get("principal");
  const peer = c.req.query("peer");
  if (!peer || !E164.test(peer)) return c.json({ error: "valid peer is required" }, 400);
  const [messageRows, voicemailRows] = await Promise.all([
    c.env.DB.prepare("SELECT media_json FROM messages WHERE tenant_id=? AND ((direction='inbound' AND from_number=?) OR (direction='outbound' AND to_number=?))").bind(tenantId, peer, peer).all<{ media_json: string }>(),
    c.env.DB.prepare("SELECT object_key FROM voicemails WHERE tenant_id=? AND from_number=? AND object_key IS NOT NULL").bind(tenantId, peer).all<{ object_key: string }>(),
  ]);
  const results = await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM messages WHERE tenant_id=? AND ((direction='inbound' AND from_number=?) OR (direction='outbound' AND to_number=?))").bind(tenantId, peer, peer),
    c.env.DB.prepare("DELETE FROM calls WHERE tenant_id=? AND ((direction='inbound' AND from_number=?) OR (direction='outbound' AND to_number=?))").bind(tenantId, peer, peer),
    c.env.DB.prepare("DELETE FROM voicemails WHERE tenant_id=? AND from_number=?").bind(tenantId, peer),
  ]);
  const mediaKeys = messageRows.results.flatMap((row) => (JSON.parse(row.media_json || "[]") as StoredMedia[]).map((item) => item.key));
  const objectKeys = voicemailRows.results.map((row) => row.object_key).filter(Boolean);
  if (mediaKeys.length || objectKeys.length) c.executionCtx.waitUntil(c.env.MEDIA.delete([...mediaKeys, ...objectKeys]));
  const deleted = results.reduce((total, result) => total + result.meta.changes, 0);
  c.env.EVENTS.getByName(tenantId).broadcast(JSON.stringify({ type: "conversation.deleted", at: new Date().toISOString(), peer }));
  return c.json({ deleted: true, records: deleted });
});

app.get("/v1/messages", async (c) => {
  const { tenantId } = c.get("principal");
  const peer = c.req.query("peer");
  if (!peer || !E164.test(peer)) return c.json({ error: "valid peer is required" }, 400);
  const result = await c.env.DB.prepare(`SELECT id, direction, from_number, to_number, body, status, occurred_at FROM messages WHERE tenant_id=? AND ((direction='inbound' AND from_number=?) OR (direction='outbound' AND to_number=?)) ORDER BY occurred_at ASC LIMIT 500`).bind(tenantId, peer, peer).all();
  return c.json({ data: result.results });
});

app.get("/v1/activity", async (c) => {
  const { tenantId } = c.get("principal");
  const peer = c.req.query("peer");
  if (!peer || !E164.test(peer)) return c.json({ error: "valid peer is required" }, 400);
  const result = await c.env.DB.prepare(`
    SELECT id, 'message' kind, direction, body, status, occurred_at,
      media_json media, NULL answered_at, NULL ended_at, NULL duration_seconds
    FROM messages WHERE tenant_id=? AND ((direction='inbound' AND from_number=?) OR (direction='outbound' AND to_number=?))
    UNION ALL
    SELECT id, 'call' kind, direction,
      CASE WHEN direction='inbound' THEN 'Incoming call' ELSE 'Outgoing call' END body,
      status, started_at occurred_at, '[]' media, answered_at, ended_at,
      CASE WHEN ended_at IS NOT NULL THEN CAST(strftime('%s', ended_at) - strftime('%s', COALESCE(answered_at, started_at)) AS INTEGER) ELSE NULL END duration_seconds
    FROM calls WHERE tenant_id=? AND ((direction='inbound' AND from_number=?) OR (direction='outbound' AND to_number=?))
    UNION ALL
    SELECT id, 'voicemail' kind, 'inbound' direction, 'Voicemail' body, status, occurred_at,
      '[]' media, NULL answered_at, NULL ended_at, duration_seconds
    FROM voicemails WHERE tenant_id=? AND from_number=?
    ORDER BY occurred_at ASC LIMIT 750
  `).bind(tenantId, peer, peer, tenantId, peer, peer, tenantId, peer).all<Record<string, unknown>>();
  return c.json({ data: result.results.map((row) => ({ ...row, media: typeof row.media === "string" ? JSON.parse(row.media) : [] })) });
});

app.get("/v1/messages/:id/media/:index", async (c) => {
  const p = c.get("principal");
  const row = await c.env.DB.prepare("SELECT media_json FROM messages WHERE id=? AND tenant_id=?").bind(c.req.param("id"), p.tenantId).first<{ media_json: string }>();
  const media = row ? JSON.parse(row.media_json) as StoredMedia[] : [];
  const item = media[Number(c.req.param("index"))];
  if (!item?.key) return c.json({ error: "media not found" }, 404);
  return mediaResponse(c.env.MEDIA, item.key);
});

app.get("/v1/voicemails/:id/audio", async (c) => {
  const p = c.get("principal");
  const row = await c.env.DB.prepare("SELECT object_key FROM voicemails WHERE id=? AND tenant_id=? AND status='ready'").bind(c.req.param("id"), p.tenantId).first<{ object_key: string }>();
  if (!row?.object_key) return c.json({ error: "voicemail audio is not ready" }, 404);
  return mediaResponse(c.env.MEDIA, row.object_key);
});

app.post("/v1/messages", async (c) => {
  const p = c.get("principal");
  const body = await c.req.json<{ to?: string; text?: string; attachment?: { name?: string; contentType?: string; base64?: string } }>();
  const to = body.to?.trim(); const text = body.text?.trim() ?? "";
  if (!to || !E164.test(to) || (!text && !body.attachment) || text.length > 1600) return c.json({ error: "valid E.164 destination and message content are required" }, 400);
  const phone = await c.env.DB.prepare("SELECT e164 FROM phone_numbers WHERE tenant_id=? ORDER BY created_at LIMIT 1").bind(p.tenantId).first<{ e164: string }>();
  if (!phone) return c.json({ error: "workspace has no provisioned phone number" }, 409);
  const media: StoredMedia[] = [];
  const mediaUrls: string[] = [];
  if (body.attachment) {
    const contentType = body.attachment.contentType?.toLowerCase() ?? "";
    if (!/^(image|audio|video)\/[a-z0-9.+-]+$/.test(contentType) && contentType !== "application/pdf") return c.json({ error: "unsupported attachment type" }, 415);
    let bytes: Uint8Array;
    try { bytes = Uint8Array.from(atob(body.attachment.base64 ?? ""), (value) => value.charCodeAt(0)); } catch { return c.json({ error: "invalid attachment" }, 400); }
    if (!bytes.byteLength || bytes.byteLength > 5_000_000) return c.json({ error: "attachment must be between 1 byte and 5 MB" }, 413);
    const token = crypto.randomUUID(); const key = `outbound-public/${token}`;
    await c.env.MEDIA.put(key, bytes, { httpMetadata: { contentType, cacheControl: "private, max-age=86400" }, customMetadata: { tenantId: p.tenantId, name: (body.attachment.name ?? "attachment").slice(0, 120) } });
    media.push({ key, contentType, size: bytes.byteLength }); mediaUrls.push(`${c.env.WEB_ORIGIN}/v1/outbound-media/${token}`);
  }
  let sent: Awaited<ReturnType<typeof sendTelnyxMessage>>;
  try { sent = await sendTelnyxMessage(c.env.TELNYX_API_KEY, { from: phone.e164, to, text, mediaUrls, webhookUrl: `${c.env.WEB_ORIGIN}/v1/webhooks/telnyx` }); }
  catch (error) { if (media.length) await c.env.MEDIA.delete(media.map((item) => item.key)); throw error; }
  await c.env.DB.prepare("INSERT OR IGNORE INTO messages (id, tenant_id, telnyx_message_id, direction, from_number, to_number, body, status, occurred_at, media_json) VALUES (?, ?, ?, 'outbound', ?, ?, ?, ?, ?, ?)").bind(crypto.randomUUID(), p.tenantId, sent.id, sent.from, sent.to, sent.text, sent.status, sent.occurredAt, JSON.stringify(media)).run();
  c.env.EVENTS.getByName(p.tenantId).broadcast(JSON.stringify({ type: "message.created", at: sent.occurredAt }));
  return c.json({ data: sent }, 201);
});

app.delete("/v1/messages/:id", async (c) => {
  const p = c.get("principal");
  const id = c.req.param("id");
  const existing = await c.env.DB.prepare("SELECT media_json FROM messages WHERE id=? AND tenant_id=?").bind(id, p.tenantId).first<{ media_json: string }>();
  const removed = await c.env.DB.prepare("DELETE FROM messages WHERE id=? AND tenant_id=?").bind(id, p.tenantId).run();
  if (removed.meta.changes === 0) return c.json({ error: "message not found" }, 404);
  const media = existing ? JSON.parse(existing.media_json) as StoredMedia[] : [];
  if (media.length) c.executionCtx.waitUntil(c.env.MEDIA.delete(media.map((item) => item.key)));
  c.env.EVENTS.getByName(p.tenantId).broadcast(JSON.stringify({ type: "message.deleted", at: new Date().toISOString() }));
  return c.json({ deleted: true });
});

app.get("/v1/contacts", async (c) => {
  const result = await c.env.DB.prepare("SELECT id, display_name, phone_number FROM contacts WHERE tenant_id=? ORDER BY display_name").bind(c.get("principal").tenantId).all();
  return c.json({ data: result.results });
});

app.post("/v1/contacts", async (c) => {
  const p = c.get("principal"); const body = await c.req.json<{ displayName?: string; phoneNumber?: string }>();
  const name = body.displayName?.trim(); const phone = body.phoneNumber?.trim();
  if (!name || !phone || !E164.test(phone)) return c.json({ error: "name and E.164 phone number are required" }, 400);
  const id = crypto.randomUUID();
  await c.env.DB.prepare("INSERT INTO contacts (id, tenant_id, display_name, phone_number) VALUES (?, ?, ?, ?)").bind(id, p.tenantId, name, phone).run();
  return c.json({ data: { id, displayName: name, phoneNumber: phone } }, 201);
});

app.get("/v1/settings", async (c) => {
  const p = c.get("principal");
  const row = await c.env.DB.prepare(`
    SELECT receive_web, receive_mobile, voicemail_enabled,
      CASE WHEN voicemail_greeting IS NULL THEN 0 ELSE 1 END has_voicemail_greeting,
      voicemail_updated_at
    FROM call_preferences WHERE tenant_id=? AND user_id=?
  `).bind(p.tenantId, p.userId).first<{ receive_web: number; receive_mobile: number; voicemail_enabled: number; has_voicemail_greeting: number; voicemail_updated_at: string | null }>();
  return c.json({ data: {
    receiveWeb: Boolean(row?.receive_web ?? 1),
    receiveMobile: Boolean(row?.receive_mobile ?? 1),
    voicemailEnabled: Boolean(row?.voicemail_enabled ?? 1),
    hasVoicemailGreeting: Boolean(row?.has_voicemail_greeting),
    voicemailUpdatedAt: row?.voicemail_updated_at ?? null,
  } });
});

app.put("/v1/settings", async (c) => {
  const p = c.get("principal");
  const body = await c.req.json<{ receiveWeb?: boolean; receiveMobile?: boolean; voicemailEnabled?: boolean }>();
  if (typeof body.receiveWeb !== "boolean" || typeof body.receiveMobile !== "boolean" || typeof body.voicemailEnabled !== "boolean") return c.json({ error: "invalid call settings" }, 400);
  await c.env.DB.prepare(`
    INSERT INTO call_preferences (tenant_id, user_id, receive_web, receive_mobile, voicemail_enabled)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(tenant_id, user_id) DO UPDATE SET
      receive_web=excluded.receive_web,
      receive_mobile=excluded.receive_mobile,
      voicemail_enabled=excluded.voicemail_enabled,
      updated_at=CURRENT_TIMESTAMP
  `).bind(p.tenantId, p.userId, body.receiveWeb ? 1 : 0, body.receiveMobile ? 1 : 0, body.voicemailEnabled ? 1 : 0).run();
  c.env.EVENTS.getByName(p.tenantId).broadcast(JSON.stringify({ type: "settings.updated", at: new Date().toISOString() }));
  return c.json({ saved: true });
});

app.put("/v1/settings/voicemail-greeting", async (c) => {
  const p = c.get("principal");
  const contentType = c.req.header("content-type")?.split(";")[0] ?? "";
  if (!contentType.startsWith("audio/")) return c.json({ error: "an audio recording is required" }, 415);
  const audio = await c.req.arrayBuffer();
  if (!audio.byteLength || audio.byteLength > 2_000_000) return c.json({ error: "voicemail greeting must be under 2 MB" }, 413);
  await c.env.DB.prepare(`
    INSERT INTO call_preferences (tenant_id, user_id, voicemail_greeting, voicemail_greeting_type, voicemail_updated_at)
    VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ON CONFLICT(tenant_id, user_id) DO UPDATE SET
      voicemail_greeting=excluded.voicemail_greeting,
      voicemail_greeting_type=excluded.voicemail_greeting_type,
      voicemail_updated_at=CURRENT_TIMESTAMP,
      updated_at=CURRENT_TIMESTAMP
  `).bind(p.tenantId, p.userId, audio, contentType).run();
  return c.json({ saved: true });
});

app.get("/v1/settings/voicemail-greeting", async (c) => {
  const p = c.get("principal");
  const row = await c.env.DB.prepare("SELECT voicemail_greeting, voicemail_greeting_type FROM call_preferences WHERE tenant_id=? AND user_id=?")
    .bind(p.tenantId, p.userId).first<{ voicemail_greeting: ArrayBuffer | null; voicemail_greeting_type: string | null }>();
  if (!row?.voicemail_greeting) return c.json({ error: "no voicemail greeting recorded" }, 404);
  return new Response(row.voicemail_greeting, { headers: { "Content-Type": row.voicemail_greeting_type ?? "audio/webm", "Cache-Control": "private, no-store" } });
});

app.get("/v1/calls", async (c) => {
  const result = await c.env.DB.prepare("SELECT id, direction, from_number, to_number, status, started_at, ended_at FROM calls WHERE tenant_id=? ORDER BY started_at DESC LIMIT 100").bind(c.get("principal").tenantId).all();
  return c.json({ data: result.results });
});

app.post("/v1/voice/token", async (c) => {
  const p = c.get("principal");
  const credential = await c.env.DB.prepare("SELECT telnyx_credential_id FROM telephony_credentials WHERE tenant_id=? AND user_id=?").bind(p.tenantId, p.userId).first<{ telnyx_credential_id: string }>();
  if (!credential) return c.json({ error: "voice is not provisioned" }, 409);
  const [token, sipUsername] = await Promise.all([
    mintTelnyxToken(c.env.TELNYX_API_KEY, credential.telnyx_credential_id),
    getTelephonyCredentialSipUsername(c.env.TELNYX_API_KEY, credential.telnyx_credential_id),
  ]);
  return c.json({ token, expiresIn: 86400, selfTarget: `sip:${sipUsername}@sip.telnyx.com` });
});

app.onError((error, c) => { console.error(JSON.stringify({ event: "request_failed", message: error.message })); return c.json({ error: "internal error" }, 500); });

function relyingParty(webOrigin: string) {
  const origin = new URL(webOrigin).origin;
  return { origin, id: new URL(origin).hostname };
}

async function challenge(db: D1Database, id: string | undefined, kind: "registration" | "authentication") {
  if (!id) return null;
  return db.prepare("SELECT challenge, payload FROM passkey_challenges WHERE id = ? AND kind = ? AND expires_at > CURRENT_TIMESTAMP").bind(id, kind).first<{ challenge: string; payload: string }>();
}

type TelnyxMedia = { url?: string; content_type?: string; size?: number; sha256?: string };
type StoredMedia = { key: string; contentType: string; size?: number };
type TelnyxEventPayload = { id?: string; call_control_id?: string; recording_id?: string; direction?: string; text?: string; type?: string; from?: string | { phone_number?: string }; to?: string | Array<{ phone_number?: string; status?: string }>; media?: TelnyxMedia[]; recording_urls?: Record<string, string>; public_recording_urls?: Record<string, string>; format?: string; received_at?: string; sent_at?: string; start_time?: string; end_time?: string; recording_started_at?: string; recording_ended_at?: string; hangup_cause?: string; hangup_source?: string; sip_hangup_cause?: string };
function eventFrom(payload: TelnyxEventPayload) { return typeof payload.from === "string" ? payload.from : payload.from?.phone_number; }
function eventTo(payload: TelnyxEventPayload) { return typeof payload.to === "string" ? payload.to : payload.to?.[0]?.phone_number; }
async function applyMessageEvent(env: Env, ctx: { waitUntil(promise: Promise<unknown>): void }, eventType: string, occurredAt: string, payload: TelnyxEventPayload): Promise<string | null> {
  const id = payload.id; const from = eventFrom(payload); const to = eventTo(payload);
  if (!id || !from || !to) return null;
  const ownedNumber = payload.direction === "inbound" ? to : from;
  const number = await env.DB.prepare("SELECT tenant_id FROM phone_numbers WHERE e164=?").bind(ownedNumber).first<{ tenant_id: string }>();
  if (!number) return null;
  if (eventType === "message.received") {
    const localId = crypto.randomUUID();
    const storedMedia = (payload.media ?? []).filter((item) => item.url).map((item, index) => ({ key: `${number.tenant_id}/messages/${localId}/${index}`, contentType: item.content_type ?? "application/octet-stream", size: item.size }));
    await env.DB.prepare("INSERT OR IGNORE INTO messages (id, tenant_id, telnyx_message_id, direction, from_number, to_number, body, status, occurred_at, media_json) VALUES (?, ?, ?, 'inbound', ?, ?, ?, 'received', ?, ?)").bind(localId, number.tenant_id, id, from, to, payload.text ?? "", payload.received_at ?? occurredAt, JSON.stringify(storedMedia)).run();
    if (storedMedia.length) ctx.waitUntil(persistMessageMedia(env, payload.media ?? [], storedMedia));
  } else {
    const destinationStatus = Array.isArray(payload.to) ? payload.to[0]?.status : undefined;
    await env.DB.prepare("UPDATE messages SET status=? WHERE tenant_id=? AND telnyx_message_id=?").bind(destinationStatus ?? eventType.replace("message.", ""), number.tenant_id, id).run();
  }
  return number.tenant_id;
}

async function persistMessageMedia(env: Env, source: TelnyxMedia[], destination: StoredMedia[]): Promise<void> {
  await Promise.all(destination.map(async (item, index) => {
    const url = source[index]?.url;
    if (!url) return;
    const response = await fetch(url, { headers: { Authorization: `Bearer ${env.TELNYX_API_KEY}` } });
    if (!response.ok || !response.body) throw new Error(`Telnyx MMS download failed (${response.status})`);
    await env.MEDIA.put(item.key, response.body, { httpMetadata: { contentType: item.contentType, cacheControl: "private, no-store" } });
  }));
}

async function applyRecordingEvent(env: Env, ctx: { waitUntil(promise: Promise<unknown>): void }, occurredAt: string, payload: TelnyxEventPayload): Promise<string | null> {
  if (!payload.recording_id || !payload.call_control_id) return null;
  const call = await env.DB.prepare("SELECT tenant_id, from_number, to_number FROM calls WHERE telnyx_call_control_id=?").bind(payload.call_control_id).first<{ tenant_id: string; from_number: string; to_number: string }>();
  if (!call) return null;
  const recordingUrl = payload.recording_urls?.mp3 ?? payload.recording_urls?.wav ?? payload.public_recording_urls?.mp3 ?? payload.public_recording_urls?.wav;
  if (!recordingUrl) return call.tenant_id;
  const id = crypto.randomUUID();
  const format = payload.recording_urls?.mp3 || payload.public_recording_urls?.mp3 ? "mp3" : "wav";
  const contentType = format === "mp3" ? "audio/mpeg" : "audio/wav";
  const objectKey = `${call.tenant_id}/voicemails/${id}.${format}`;
  const started = payload.recording_started_at ?? payload.start_time ?? occurredAt;
  const ended = payload.recording_ended_at ?? payload.end_time;
  const duration = ended ? Math.max(0, Math.round((Date.parse(ended) - Date.parse(started)) / 1000)) : null;
  await env.DB.prepare("INSERT OR IGNORE INTO voicemails (id, tenant_id, telnyx_recording_id, telnyx_call_control_id, from_number, to_number, duration_seconds, status, object_key, content_type, occurred_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'processing', ?, ?, ?)")
    .bind(id, call.tenant_id, payload.recording_id, payload.call_control_id, call.from_number, call.to_number, duration, objectKey, contentType, started).run();
  ctx.waitUntil((async () => {
    const response = await fetch(recordingUrl);
    if (!response.ok || !response.body) throw new Error(`Telnyx voicemail download failed (${response.status})`);
    await env.MEDIA.put(objectKey, response.body, { httpMetadata: { contentType, cacheControl: "private, no-store" } });
    await env.DB.prepare("UPDATE voicemails SET status='ready' WHERE tenant_id=? AND telnyx_recording_id=?").bind(call.tenant_id, payload.recording_id).run();
    env.EVENTS.getByName(call.tenant_id).broadcast(JSON.stringify({ type: "voicemail.ready", at: new Date().toISOString() }));
  })());
  return call.tenant_id;
}

async function mediaResponse(bucket: R2Bucket, key: string): Promise<Response> {
  const object = await bucket.get(key);
  if (!object) return Response.json({ error: "media not found" }, { status: 404 });
  const headers = new Headers({ "Cache-Control": "private, no-store", "Accept-Ranges": "bytes" });
  object.writeHttpMetadata(headers);
  return new Response(object.body, { headers });
}

async function applyAndRouteCallEvent(env: Env, eventType: string, occurredAt: string, payload: TelnyxEventPayload): Promise<string | null> {
  if (eventType === "call.hangup") {
    console.log(JSON.stringify({ event: "telnyx_call_hangup", callControlId: payload.call_control_id, from: eventFrom(payload), to: eventTo(payload), hangupCause: payload.hangup_cause, hangupSource: payload.hangup_source, sipHangupCause: payload.sip_hangup_cause }));
  }
  const callControlId = payload.call_control_id;
  if (!callControlId) return resolveEventTenant(env.DB, payload);

  const clientRoute = await env.DB.prepare("SELECT tenant_id, inbound_call_control_id FROM inbound_call_routes WHERE client_call_control_id=?")
    .bind(callControlId).first<{ tenant_id: string; inbound_call_control_id: string }>();
  if (clientRoute) {
    if (eventType === "call.answered") {
      await env.DB.prepare("UPDATE inbound_call_routes SET status='bridged', updated_at=? WHERE client_call_control_id=?").bind(occurredAt, callControlId).run();
    } else if (eventType === "call.hangup") {
      await env.DB.prepare("UPDATE inbound_call_routes SET status='client_hangup', updated_at=? WHERE client_call_control_id=?").bind(occurredAt, callControlId).run();
    }
    return clientRoute.tenant_id;
  }

  const tenantId = await applyCallEvent(env.DB, eventType, occurredAt, payload);
  const direction = payload.direction === "incoming" || payload.direction === "inbound" ? "inbound" : "outbound";
  if (eventType === "call.initiated" && direction === "inbound" && tenantId) {
    const from = eventFrom(payload);
    const to = eventTo(payload);
    if (!from || !to) return tenantId;
    const phone = await env.DB.prepare("SELECT connection_id FROM phone_numbers WHERE tenant_id=? AND e164=?").bind(tenantId, to).first<{ connection_id: string }>();
    const credential = await env.DB.prepare("SELECT telnyx_credential_id FROM telephony_credentials WHERE tenant_id=? ORDER BY created_at LIMIT 1").bind(tenantId).first<{ telnyx_credential_id: string }>();
    if (!phone || !credential) throw new Error("Inbound call cannot be routed because voice is not provisioned");
    const sipUsername = await getTelephonyCredentialSipUsername(env.TELNYX_API_KEY, credential.telnyx_credential_id);
    const clientCallControlId = await dialRelayClient(env.TELNYX_API_KEY, { applicationId: phone.connection_id, sipUsername, callerNumber: from, inboundCallControlId: callControlId });
    await env.DB.prepare("INSERT OR IGNORE INTO inbound_call_routes (id, tenant_id, inbound_call_control_id, client_call_control_id, caller_number, relay_number, status) VALUES (?, ?, ?, ?, ?, ?, 'ringing')")
      .bind(crypto.randomUUID(), tenantId, callControlId, clientCallControlId, from, to).run();
  } else if (eventType === "call.hangup") {
    await env.DB.prepare("UPDATE inbound_call_routes SET status='caller_hangup', updated_at=? WHERE inbound_call_control_id=?").bind(occurredAt, callControlId).run();
  }
  return tenantId;
}

async function applyCallEvent(db: D1Database, eventType: string, occurredAt: string, payload: TelnyxEventPayload): Promise<string | null> {
  const callControlId = payload.call_control_id;
  const from = eventFrom(payload);
  const to = eventTo(payload);
  if (!callControlId || !from || !to) return resolveEventTenant(db, payload);
  const tenantId = await resolveEventTenant(db, payload);
  if (!tenantId) return null;
  const direction = payload.direction === "incoming" || payload.direction === "inbound" ? "inbound" : "outbound";
  const status = eventType.replace("call.", "");
  const answeredAt = eventType === "call.answered" ? occurredAt : null;
  const endedAt = eventType === "call.hangup" ? occurredAt : null;
  await db.prepare(`
    INSERT INTO calls (id, tenant_id, telnyx_call_control_id, direction, from_number, to_number, status, started_at, answered_at, ended_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(telnyx_call_control_id) DO UPDATE SET
      status=excluded.status,
      answered_at=COALESCE(calls.answered_at, excluded.answered_at),
      ended_at=COALESCE(calls.ended_at, excluded.ended_at)
  `).bind(crypto.randomUUID(), tenantId, callControlId, direction, from, to, status, payload.start_time ?? occurredAt, answeredAt, endedAt).run();
  return tenantId;
}

async function resolveEventTenant(db: D1Database, payload: TelnyxEventPayload): Promise<string | null> {
  const values = [eventFrom(payload), eventTo(payload)].filter((value): value is string => Boolean(value));
  for (const value of values) {
    const number = await db.prepare("SELECT tenant_id FROM phone_numbers WHERE e164=?").bind(value).first<{ tenant_id: string }>();
    if (number) return number.tenant_id;
  }
  return null;
}

export default app;
