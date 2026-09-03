# Architecture

## Product scope

The first sellable slice is one phone number per workspace with calling, SMS/MMS history, voicemail metadata, contacts, multiple members, and native incoming-call UI. Number porting, emergency calling, lawful messaging registration, billing, spam controls, and support tooling are launch requirements—not optional polish.

## Runtime map

```text
Web (React) -----------\
                       > Cloudflare Worker API ---- D1 (tenants, users, calls, messages)
iOS (SwiftUI/CallKit) -/             |              R2 (future: MMS/voicemail media)
                                     |              Queue (webhook fan-out/retries)
                                     v
                              Telnyx REST API
                              Telnyx Voice SDK (media goes client <-> Telnyx)
                              Telnyx signed webhooks
```

Cloudflare never sits in the RTP/media path. A client asks the Worker for a short-lived Telnyx JWT, then the Telnyx SDK connects directly to Telnyx. The Worker remains the policy and record-keeping plane.

## Tenant model

Every customer-owned row carries `tenant_id`. The authenticated principal resolves to a membership before queries execute. Phone numbers, Telnyx credentials, messages, calls, and devices cannot be addressed without that tenant scope. Platform operators should use a separate audited support surface rather than a hidden cross-tenant mode.

## Call flow

1. User authenticates and selects a workspace.
2. API validates membership and mints a Telnyx JWT from that user's stored telephony credential ID.
3. Web/iOS Telnyx SDK connects directly to Telnyx and places or receives the call.
4. Telnyx signs call events and sends them to the Worker.
5. Worker verifies Ed25519 over the raw body, rejects stale timestamps, inserts the event ID once, and updates the call record.
6. iOS incoming calls arrive through Telnyx/APNs VoIP push and are presented through CallKit.

## Security invariants

- Telnyx API keys never reach clients.
- Clients receive short-lived WebRTC JWTs, not SIP passwords.
- Webhook signatures are checked against the untouched request body and a five-minute replay window.
- Event IDs are unique for idempotency.
- Logs contain IDs and event types, not message bodies, phone credentials, or access tokens.
- E.164 normalization occurs at every external boundary.

## Roadmap

### Milestone 1 — personal dogfood

- Account/workspace setup and number assignment
- Web and iOS outbound/inbound calling
- SMS/MMS send and receive
- Call/message history and voicemail playback
- PushKit/CallKit on a physical iPhone

### Milestone 2 — service readiness

- OIDC/passkeys, invitations, roles, audit log
- Billing/metering, per-tenant quotas, abuse prevention
- A2P 10DLC/toll-free verification workflows where applicable
- E911 address registration and explicit emergency-calling UX
- Porting workflow, number inventory, support console, data export/deletion
- Queue-backed webhook processing, R2 media, retention policies, monitoring

### Milestone 3 — differentiation

- Business hours, ring groups, forwarding, transcripts, spam screening
- Shared team inbox and assignments
- Android app and public API

