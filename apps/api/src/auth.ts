import type { Context, Next } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";

export type Principal = { userId: string; tenantId: string; role: "owner" | "admin" | "member" };
type RelayContext = { Bindings: Env; Variables: { principal: Principal } };
const SESSION_COOKIE = "relay_session";
const SESSION_SECONDS = 60 * 60 * 24 * 30;

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export async function sha256(value: string): Promise<string> {
  return toBase64(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

export async function createSession(c: Context<RelayContext>, userId: string): Promise<void> {
  const token = toBase64(crypto.getRandomValues(new Uint8Array(32)));
  const expiresAt = new Date(Date.now() + SESSION_SECONDS * 1000).toISOString();
  await c.env.DB.prepare("INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES (?, ?, ?, ?)")
    .bind(crypto.randomUUID(), userId, await sha256(token), expiresAt).run();
  setCookie(c, SESSION_COOKIE, token, { httpOnly: true, secure: String(c.env.ENVIRONMENT) === "production", sameSite: "Strict", path: "/", maxAge: SESSION_SECONDS });
}

export async function clearSession(c: Context<RelayContext>): Promise<void> {
  const token = getCookie(c, SESSION_COOKIE);
  if (token) await c.env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256(token)).run();
  deleteCookie(c, SESSION_COOKIE, { path: "/", secure: String(c.env.ENVIRONMENT) === "production" });
}

export async function requirePrincipal(c: Context<RelayContext>, next: Next) {
  const token = getCookie(c, SESSION_COOKIE);
  if (token) {
    const row = await c.env.DB.prepare(
      `SELECT s.user_id, m.tenant_id, m.role FROM sessions s JOIN memberships m ON m.user_id = s.user_id
       WHERE s.token_hash = ? AND s.expires_at > CURRENT_TIMESTAMP
       ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END LIMIT 1`,
    ).bind(await sha256(token)).first<{ user_id: string; tenant_id: string; role: Principal["role"] }>();
    if (row) {
      c.set("principal", { userId: row.user_id, tenantId: row.tenant_id, role: row.role });
      await next();
      return;
    }
  }
  const suppliedBearer = c.req.header("authorization")?.replace(/^Bearer\s+/i, "");
  if (suppliedBearer?.startsWith("rly_")) {
    const mobile = await c.env.DB.prepare(`
      SELECT t.user_id, t.tenant_id, m.role FROM mobile_api_tokens t
      JOIN memberships m ON m.user_id=t.user_id AND m.tenant_id=t.tenant_id
      WHERE t.token_hash=? AND t.revoked_at IS NULL AND t.expires_at > CURRENT_TIMESTAMP
    `).bind(await sha256(suppliedBearer)).first<{ user_id: string; tenant_id: string; role: Principal["role"] }>();
    if (mobile) {
      c.set("principal", { userId: mobile.user_id, tenantId: mobile.tenant_id, role: mobile.role });
      c.executionCtx.waitUntil(c.env.DB.prepare("UPDATE mobile_api_tokens SET last_used_at=CURRENT_TIMESTAMP WHERE token_hash=?").bind(await sha256(suppliedBearer)).run());
      await next();
      return;
    }
  }
  const configured = c.env.DEV_BEARER_TOKEN;
  const supplied = suppliedBearer;
  if (String(c.env.ENVIRONMENT) === "development" && configured && supplied === configured) {
    c.set("principal", { userId: "user_demo", tenantId: "tenant_demo", role: "owner" });
    await next();
    return;
  }
  return c.json({ error: "unauthorized" }, 401);
}

export async function requireSameOrigin(c: Context<RelayContext>, next: Next) {
  if (["GET", "HEAD", "OPTIONS"].includes(c.req.method)) { await next(); return; }
  const origin = c.req.header("origin");
  if (origin && origin !== c.env.WEB_ORIGIN) return c.json({ error: "invalid origin" }, 403);
  await next();
}
