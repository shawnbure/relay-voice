import * as ed from "@noble/ed25519";

const MAX_WEBHOOK_AGE_SECONDS = 300;

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

export async function verifyTelnyxWebhook(input: {
  body: string;
  signature: string | undefined;
  timestamp: string | undefined;
  publicKey: string;
  now?: number;
}): Promise<boolean> {
  if (!input.signature || !input.timestamp || !/^\d+$/.test(input.timestamp)) return false;
  const age = Math.abs((input.now ?? Date.now()) / 1000 - Number(input.timestamp));
  if (age > MAX_WEBHOOK_AGE_SECONDS) return false;
  try {
    return await ed.verifyAsync(
      fromBase64(input.signature),
      new TextEncoder().encode(`${input.timestamp}|${input.body}`),
      fromBase64(input.publicKey),
    );
  } catch {
    return false;
  }
}

export async function mintTelnyxToken(apiKey: string, credentialId: string): Promise<string> {
  const response = await fetch(`https://api.telnyx.com/v2/telephony_credentials/${encodeURIComponent(credentialId)}/token`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json", "Content-Type": "application/json" },
    body: "{}",
  });
  if (!response.ok) throw new Error(`Telnyx token request failed (${response.status})`);
  const raw = await response.text();
  if (raw.startsWith("eyJ")) return raw;
  const payload: unknown = JSON.parse(raw);
  if (!payload || typeof payload !== "object" || !("data" in payload) || typeof payload.data !== "string") throw new Error("Telnyx returned an invalid token response");
  return payload.data;
}

type TelnyxPhoneNumber = { id: string; phone_number: string };

async function telnyxJson(apiKey: string, method: "GET" | "POST" | "PATCH", path: string, body?: Record<string, unknown>): Promise<unknown> {
  const response = await fetch(`https://api.telnyx.com/v2${path}`, {
    method,
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json", "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const detail = payload && typeof payload === "object" && "errors" in payload && Array.isArray(payload.errors)
      ? payload.errors.map((item) => item && typeof item === "object" && "detail" in item ? String(item.detail) : "").filter(Boolean).join("; ")
      : "";
    throw new Error(`Telnyx ${method} ${path} failed (${response.status})${detail ? `: ${detail}` : ""}`);
  }
  return payload;
}

function stringField(value: unknown, field: string): string | null {
  return value && typeof value === "object" && field in value && typeof value[field as keyof typeof value] === "string"
    ? String(value[field as keyof typeof value])
    : null;
}

export async function configureRelayInboundVoice(apiKey: string, input: { numberId: string; credentialConnectionId: string; webhookUrl: string }): Promise<string> {
  const connection = dataOf(await telnyxJson(apiKey, "GET", `/credential_connections/${encodeURIComponent(input.credentialConnectionId)}`));
  const outbound = connection && typeof connection === "object" && "outbound" in connection && connection.outbound && typeof connection.outbound === "object" ? connection.outbound : null;
  const outboundVoiceProfileId = outbound ? stringField(outbound, "outbound_voice_profile_id") : null;
  if (!outboundVoiceProfileId) throw new Error("Relay credential connection has no outbound voice profile");

  const applicationName = "RelayInbound";
  const listing = dataOf(await telnyxJson(apiKey, "GET", `/call_control_applications?filter[application_name]=${encodeURIComponent(applicationName)}&page[size]=10`));
  const existing = Array.isArray(listing) ? listing.find((item) => stringField(item, "application_name") === applicationName) : null;
  const applicationBody = {
    application_name: applicationName,
    webhook_event_url: input.webhookUrl,
    webhook_api_version: "2",
    webhook_timeout_secs: 10,
    active: true,
    outbound: { outbound_voice_profile_id: outboundVoiceProfileId },
  };
  let applicationId = existing ? stringField(existing, "id") : null;
  if (applicationId) {
    await telnyxJson(apiKey, "PATCH", `/call_control_applications/${encodeURIComponent(applicationId)}`, applicationBody);
  } else {
    const created = dataOf(await telnyxJson(apiKey, "POST", "/call_control_applications", applicationBody));
    applicationId = stringField(created, "id");
  }
  if (!applicationId) throw new Error("Telnyx did not return a Call Control application ID");
  await telnyxJson(apiKey, "PATCH", `/phone_numbers/${encodeURIComponent(input.numberId)}/voice`, { connection_id: applicationId, call_forwarding: { call_forwarding_enabled: false } });
  return applicationId;
}

export async function getTelephonyCredentialSipUsername(apiKey: string, credentialId: string): Promise<string> {
  const credential = dataOf(await telnyxJson(apiKey, "GET", `/telephony_credentials/${encodeURIComponent(credentialId)}`));
  const username = stringField(credential, "sip_username");
  if (!username) throw new Error("Telnyx telephony credential has no SIP username");
  return username;
}

export async function enableTelephonyCredentialInbound(apiKey: string, credentialId: string): Promise<string> {
  const credential = dataOf(await telnyxJson(apiKey, "GET", `/telephony_credentials/${encodeURIComponent(credentialId)}`));
  const resourceId = stringField(credential, "resource_id");
  const connectionId = resourceId?.startsWith("connection:") ? resourceId.slice("connection:".length) : null;
  if (!connectionId) throw new Error("Telnyx telephony credential has no parent connection");
  await telnyxJson(apiKey, "PATCH", `/credential_connections/${encodeURIComponent(connectionId)}`, { sip_uri_calling_preference: "internal" });
  return connectionId;
}

export async function dialRelayClient(apiKey: string, input: { applicationId: string; sipUsername: string; callerNumber: string; inboundCallControlId: string }): Promise<string> {
  const created = dataOf(await telnyxJson(apiKey, "POST", "/calls", {
    connection_id: input.applicationId,
    to: `sip:${input.sipUsername}@sip.telnyx.com`,
    from: input.callerNumber,
    link_to: input.inboundCallControlId,
    bridge_on_answer: true,
    prevent_double_bridge: true,
  }));
  const callControlId = stringField(created, "call_control_id");
  if (!callControlId) throw new Error("Telnyx did not return the Relay client call ID");
  return callControlId;
}

export async function bridgeTelnyxCalls(apiKey: string, inboundCallControlId: string, clientCallControlId: string): Promise<void> {
  await telnyxJson(apiKey, "POST", `/calls/${encodeURIComponent(inboundCallControlId)}/actions/bridge`, { call_control_id: clientCallControlId });
}

function dataOf(payload: unknown): unknown {
  return payload && typeof payload === "object" && "data" in payload ? payload.data : null;
}

export async function configureRelayMessagingProfile(apiKey: string, numberId: string, webhookUrl: string): Promise<string> {
  const name = "Relay Voice";
  const listing = dataOf(await telnyxJson(apiKey, "GET", "/messaging_profiles?page[size]=100"));
  const existing = Array.isArray(listing) ? listing.find((item) => item && typeof item === "object" && "id" in item && "name" in item && item.name === name) : undefined;
  let profileId: string;
  if (existing && typeof existing === "object" && "id" in existing && typeof existing.id === "string") {
    profileId = existing.id;
    await telnyxJson(apiKey, "PATCH", `/messaging_profiles/${encodeURIComponent(profileId)}`, { webhook_url: webhookUrl, webhook_api_version: "2", enabled: true });
  } else {
    const created = dataOf(await telnyxJson(apiKey, "POST", "/messaging_profiles", { name, webhook_url: webhookUrl, webhook_failover_url: null, webhook_api_version: "2", enabled: true, whitelisted_destinations: ["US", "CA"] }));
    if (!created || typeof created !== "object" || !("id" in created) || typeof created.id !== "string") throw new Error("Telnyx did not return a messaging profile ID");
    profileId = created.id;
  }
  await telnyxJson(apiKey, "PATCH", `/phone_numbers/${encodeURIComponent(numberId)}/messaging`, { messaging_profile_id: profileId });
  return profileId;
}

export async function inspectTelnyxMessaging(apiKey: string, numberId: string, profileId: string) {
  return {
    profile: dataOf(await telnyxJson(apiKey, "GET", `/messaging_profiles/${encodeURIComponent(profileId)}`)),
    number: dataOf(await telnyxJson(apiKey, "GET", `/phone_numbers/${encodeURIComponent(numberId)}/messaging`)),
  };
}

export async function inspectTelnyxInboundVoice(apiKey: string, numberId: string, applicationId: string) {
  return {
    number: dataOf(await telnyxJson(apiKey, "GET", `/phone_numbers/${encodeURIComponent(numberId)}/voice`)),
    application: dataOf(await telnyxJson(apiKey, "GET", `/call_control_applications/${encodeURIComponent(applicationId)}`)),
  };
}

function randomTelnyxSecret(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(24)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function getOrCreateRelayCredentialConnection(apiKey: string, webhookUrl: string): Promise<string> {
  const connectionName = "RelayVoiceWebRTC";
  const listing = dataOf(await telnyxJson(apiKey, "GET", `/credential_connections?filter[connection_name]=${encodeURIComponent(connectionName)}&page[size]=10`));
  const existing = Array.isArray(listing) ? listing.find((item) => item && typeof item === "object" && "id" in item && "connection_name" in item && item.connection_name === connectionName) : undefined;
  if (existing && typeof existing === "object" && "id" in existing && typeof existing.id === "string") return existing.id;
  const created = dataOf(await telnyxJson(apiKey, "POST", "/credential_connections", { active: true, anchorsite_override: "Latency", connection_name: connectionName, user_name: `relay${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`, password: randomTelnyxSecret(), webhook_event_url: webhookUrl, webhook_api_version: "2" }));
  if (!created || typeof created !== "object" || !("id" in created) || typeof created.id !== "string") throw new Error("Telnyx did not return a credential connection ID");
  return created.id;
}

export async function configureRelayVoice(apiKey: string, numberId: string, sourceVoiceApplicationId: string, webhookUrl: string): Promise<string> {
  const credentialConnectionId = await getOrCreateRelayCredentialConnection(apiKey, webhookUrl);
  const source = dataOf(await telnyxJson(apiKey, "GET", `/call_control_applications/${encodeURIComponent(sourceVoiceApplicationId)}`));
  const outbound = source && typeof source === "object" && "outbound" in source && source.outbound && typeof source.outbound === "object" ? source.outbound : null;
  const outboundVoiceProfileId = outbound && "outbound_voice_profile_id" in outbound && typeof outbound.outbound_voice_profile_id === "string" ? outbound.outbound_voice_profile_id : null;
  await telnyxJson(apiKey, "PATCH", `/credential_connections/${encodeURIComponent(credentialConnectionId)}`, { webhook_event_url: webhookUrl, webhook_api_version: "2", webhook_timeout_secs: 10, outbound: { call_parking_enabled: false, ...(outboundVoiceProfileId ? { outbound_voice_profile_id: outboundVoiceProfileId } : {}) } });
  await telnyxJson(apiKey, "PATCH", `/phone_numbers/${encodeURIComponent(numberId)}/voice`, { connection_id: credentialConnectionId, call_forwarding: { call_forwarding_enabled: false } });
  return credentialConnectionId;
}

export async function provisionExistingTelnyxNumber(apiKey: string, input: { e164: string; messagingProfileId: string; voiceConnectionId: string; credentialName: string; webhookUrl: string }) {
  const listing = dataOf(await telnyxJson(apiKey, "GET", `/phone_numbers?filter[phone_number]=${encodeURIComponent(input.e164)}&page[size]=10`));
  const number = Array.isArray(listing) ? listing.find((item): item is TelnyxPhoneNumber => Boolean(item && typeof item === "object" && "id" in item && "phone_number" in item && item.phone_number === input.e164)) : undefined;
  if (!number) throw new Error("The phone number is not present in this Telnyx account");

  await telnyxJson(apiKey, "PATCH", `/phone_numbers/${encodeURIComponent(number.id)}/messaging`, { messaging_profile_id: input.messagingProfileId });
  await telnyxJson(apiKey, "PATCH", `/phone_numbers/${encodeURIComponent(number.id)}/voice`, { connection_id: input.voiceConnectionId, call_forwarding: { call_forwarding_enabled: false } });
  const credentialConnectionId = await getOrCreateRelayCredentialConnection(apiKey, input.webhookUrl);
  const credentialListing = dataOf(await telnyxJson(apiKey, "GET", `/telephony_credentials?filter[tag]=${encodeURIComponent(input.credentialName)}&page[size]=10`));
  const existingCredential = Array.isArray(credentialListing) ? credentialListing.find((item) => item && typeof item === "object" && "id" in item && (("tag" in item && item.tag === input.credentialName) || ("name" in item && item.name === input.credentialName))) : undefined;
  const credentialPayload = existingCredential ?? dataOf(await telnyxJson(apiKey, "POST", "/telephony_credentials", { connection_id: credentialConnectionId, name: input.credentialName, tag: input.credentialName }));
  if (!credentialPayload || typeof credentialPayload !== "object" || !("id" in credentialPayload) || typeof credentialPayload.id !== "string") throw new Error("Telnyx did not return a telephony credential ID");
  return { numberId: number.id, credentialId: credentialPayload.id, credentialConnectionId };
}

export type SentMessage = { id: string; from: string; to: string; text: string; status: string; occurredAt: string };

export async function sendTelnyxMessage(apiKey: string, input: { from: string; to: string; text: string; webhookUrl: string; mediaUrls?: string[] }): Promise<SentMessage> {
  const response = await fetch("https://api.telnyx.com/v2/messages", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ from: input.from, to: input.to, ...(input.text ? { text: input.text } : {}), ...(input.mediaUrls?.length ? { media_urls: input.mediaUrls } : {}), webhook_url: input.webhookUrl }),
  });
  const result: unknown = await response.json();
  if (!response.ok) throw new Error(`Telnyx message request failed (${response.status})`);
  if (!result || typeof result !== "object" || !("data" in result) || !result.data || typeof result.data !== "object") throw new Error("Telnyx returned an invalid message response");
  const data = result.data as { id?: string; from?: { phone_number?: string }; to?: Array<{ phone_number?: string; status?: string }>; text?: string; sent_at?: string; received_at?: string };
  if (!data.id || !data.from?.phone_number || !data.to?.[0]?.phone_number) throw new Error("Telnyx message response is incomplete");
  return { id: data.id, from: data.from.phone_number, to: data.to[0].phone_number, text: data.text ?? input.text, status: data.to[0].status ?? "queued", occurredAt: data.sent_at ?? data.received_at ?? new Date().toISOString() };
}
