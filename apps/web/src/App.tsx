import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import { TelnyxRTC, type Call, type INotification } from "@telnyx/webrtc";
import { ArrowLeft, Check, CircleStop, Cog, Grid3X3, MessageCircle, Mic, Phone, PhoneCall, Play, Search, Send, Trash2, X } from "lucide-react";

type Me = { user: { display_name: string; email: string; tenant_name: string; role: string }; phone: { e164: string } | null };
type Conversation = { peer: string; display_name: string; body: string; direction: string; status: string; occurred_at: string; kind: "message" | "call" | "voicemail" };
type Activity = { id: string; kind: "message" | "call" | "voicemail"; direction: "inbound" | "outbound"; body: string; status: string; occurred_at: string; duration_seconds: number | null; media: Array<{ key: string; contentType: string; size?: number }> };
type Contact = { id: string; display_name: string; phone_number: string };
type Settings = { receiveWeb: boolean; receiveMobile: boolean; voicemailEnabled: boolean; hasVoicemailGreeting: boolean; voicemailUpdatedAt: string | null };
type AuthMode = "loading" | "setup" | "login" | "authenticated";

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, { ...init, credentials: "include", headers: { "Content-Type": "application/json", ...init?.headers } });
  const body = await response.json().catch(() => ({})) as T & { error?: string };
  if (!response.ok) throw new Error(body.error ?? `Request failed (${response.status})`);
  return body;
}

const defaultSettings: Settings = { receiveWeb: true, receiveMobile: true, voicemailEnabled: true, hasVoicemailGreeting: false, voicemailUpdatedAt: null };
function initials(name: string) { return name.split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "?"; }
function formatTime(value: string) { const date = new Date(value); return date.toLocaleDateString() === new Date().toLocaleDateString() ? date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : date.toLocaleDateString([], { month: "short", day: "numeric" }); }
function formatDuration(seconds: number) { return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`; }
function phoneDigits(value: string) { return value.replace(/\D/g, ""); }
function displayPhone(value: string) { const digits = phoneDigits(value); const local = digits.length === 11 && digits.startsWith("1") ? digits.slice(1) : digits; return local.length === 10 ? `(${local.slice(0, 3)}) ${local.slice(3, 6)}-${local.slice(6)}` : local; }
function phoneInput(value: string) { const digits = phoneDigits(value); return (digits.length > 10 && digits.startsWith("1") ? digits.slice(1) : digits).slice(0, 10); }
function phoneE164(value: string) { const digits = phoneDigits(value); if (digits.length === 10) return `+1${digits}`; if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`; return value.startsWith("+") && /^\+[1-9]\d{7,14}$/.test(value) ? value : ""; }
function isMobileApp() { return matchMedia("(display-mode: standalone)").matches || ("standalone" in navigator && Boolean((navigator as Navigator & { standalone?: boolean }).standalone)); }

export function App() {
  const [auth, setAuth] = useState<AuthMode>("loading");
  const [me, setMe] = useState<Me | null>(null);
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [messages, setMessages] = useState<Activity[]>([]);
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  const [peer, setPeer] = useState("");
  const [draft, setDraft] = useState("");
  const [dialNumber, setDialNumber] = useState("");
  const [mobileDialer, setMobileDialer] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [error, setError] = useState("");
  const [sending, setSending] = useState(false);
  const [callStatus, setCallStatus] = useState("");
  const [callPeer, setCallPeer] = useState("");
  const [callStartedAt, setCallStartedAt] = useState<number | null>(null);
  const [callSeconds, setCallSeconds] = useState(0);
  const [voiceReady, setVoiceReady] = useState(false);
  const [selfTarget, setSelfTarget] = useState("");
  const [incomingFrom, setIncomingFrom] = useState("");
  const rtcClient = useRef<TelnyxRTC | null>(null);
  const activeCall = useRef<Call | null>(null);
  const localHangup = useRef(false);
  const composerInput = useRef<HTMLInputElement | null>(null);

  const loadApp = useCallback(async () => {
    try {
      const [identity, conversationData, contactData, settingsData] = await Promise.all([
        api<Me>("/v1/me"), api<{ data: Conversation[] }>("/v1/conversations"), api<{ data: Contact[] }>("/v1/contacts"), api<{ data: Settings }>("/v1/settings"),
      ]);
      setMe(identity); setConversations(conversationData.data); setContacts(contactData.data); setSettings(settingsData.data); setAuth("authenticated");
    } catch {
      const status = await api<{ needsSetup: boolean }>("/v1/auth/status");
      setAuth(status.needsSetup ? "setup" : "login");
    }
  }, []);

  const refreshMessages = useCallback(async (number = peer) => {
    const destination = phoneE164(number);
    if (!destination) { setMessages([]); return; }
    const result = await api<{ data: Activity[] }>(`/v1/activity?peer=${encodeURIComponent(destination)}`);
    setMessages(result.data);
  }, [peer]);

  useEffect(() => { void loadApp(); }, [loadApp]);
  useEffect(() => {
    if (auth !== "authenticated" || location.pathname !== "/mobile-connect") return;
    void api<{ token: string }>("/v1/mobile/token", { method: "POST", body: JSON.stringify({ deviceName: "Relay for iPhone" }) })
      .then(({ token }) => { location.href = `relay://auth?token=${encodeURIComponent(token)}`; })
      .catch((reason: Error) => setError(reason.message));
  }, [auth]);
  useEffect(() => { if (auth === "authenticated") void refreshMessages(); }, [peer, auth, refreshMessages]);
  useEffect(() => () => { activeCall.current?.hangup(); void rtcClient.current?.disconnect(); }, []);

  useEffect(() => {
    if (auth !== "authenticated") return;
    let socket: WebSocket | null = null; let reconnectTimer = 0; let stopped = false; let delay = 1_000;
    const refresh = () => Promise.all([loadApp(), refreshMessages()]);
    const connect = () => {
      socket = new WebSocket(`${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/v1/events`);
      socket.onopen = () => { delay = 1_000; };
      socket.onmessage = (event) => { if (event.data !== "pong") void refresh().catch(() => undefined); };
      socket.onclose = () => { if (!stopped) { reconnectTimer = window.setTimeout(connect, delay); delay = Math.min(delay * 2, 15_000); } };
    };
    connect();
    const refreshTimer = window.setInterval(() => void refresh().catch(() => undefined), 15_000);
    const heartbeat = window.setInterval(() => { if (socket?.readyState === WebSocket.OPEN) socket.send("ping"); }, 25_000);
    return () => { stopped = true; clearTimeout(reconnectTimer); clearInterval(refreshTimer); clearInterval(heartbeat); socket?.close(); };
  }, [auth, loadApp, refreshMessages]);

  useEffect(() => {
    const shouldReceive = isMobileApp() ? settings.receiveMobile : settings.receiveWeb;
    if (auth !== "authenticated" || !shouldReceive || rtcClient.current) return;
    let disposed = false;
    void api<{ token: string; selfTarget: string }>("/v1/voice/token", { method: "POST", body: "{}" }).then(async ({ token, selfTarget: target }) => {
      if (disposed) return;
      setSelfTarget(target);
      const client = new TelnyxRTC({ login_token: token });
      rtcClient.current = client; client.remoteElement = "relay-remote-audio";
      client.on("telnyx.ready", () => setVoiceReady(true));
      client.on("telnyx.notification", (notification: INotification) => {
        if (!notification.call) return;
        const call = notification.call; activeCall.current = call;
        if (call.direction === "inbound" && ["ringing", "new"].includes(call.state)) {
          const caller = call.options.remoteCallerNumber ?? call.options.remoteCallerName ?? "Unknown caller";
          setIncomingFrom(caller); setCallPeer(caller); setCallStatus("Incoming call");
        } else if (call.state === "active") { setIncomingFrom(""); setCallStatus("In call"); setCallStartedAt((value) => value ?? Date.now()); }
        else if (["ringing", "early"].includes(call.state)) setCallStatus("Ringing…");
        else if (["new", "trying", "requesting", "recovering"].includes(call.state)) setCallStatus("Connecting…");
        else if (call.state === "held") setCallStatus("On hold");
        else if (["hangup", "destroy", "done"].includes(call.state)) {
          const endedLocally = localHangup.current;
          localHangup.current = false;
          activeCall.current = null; setIncomingFrom(""); setCallStatus("Call ended"); setCallStartedAt(null); setCallSeconds(0);
          if (!endedLocally) {
            const details = [call.sipCode ? `SIP ${call.sipCode}` : "", call.sipReason, call.cause].filter(Boolean).join(" · ");
            setError(details ? `Call ended: ${details}` : "The other side ended the call.");
          }
          window.setTimeout(() => setCallStatus(""), 4_000);
        }
      });
      client.on("telnyx.error", (event: unknown) => {
        const failure = event as { error?: { message?: string; code?: number }; message?: string };
        const detail = failure.error?.message ?? failure.message;
        setError(detail ? `Calling error: ${detail}` : "Calling connection was interrupted. Refresh to reconnect.");
      });
      await client.connect();
    }).catch((e: Error) => setError(e.message));
    return () => { disposed = true; setVoiceReady(false); activeCall.current = null; const client = rtcClient.current; rtcClient.current = null; void client?.disconnect(); };
  }, [auth, settings.receiveMobile, settings.receiveWeb]);
  useEffect(() => {
    if (!callStartedAt) return;
    const update = () => setCallSeconds(Math.floor((Date.now() - callStartedAt) / 1000));
    update(); const timer = window.setInterval(update, 1_000);
    return () => window.clearInterval(timer);
  }, [callStartedAt]);

  const selected = useMemo(() => conversations.find((item) => item.peer === peer), [conversations, peer]);
  const selectPeer = (number: string) => { setPeer(phoneE164(number)); setSettingsOpen(false); setMobileDialer(false); };
  const sendMessage = async (event: FormEvent) => {
    event.preventDefault(); const to = phoneE164(peer); if (!to || !draft.trim()) return;
    setSending(true); setError("");
    try { await api("/v1/messages", { method: "POST", body: JSON.stringify({ to, text: draft.trim() }) }); setDraft(""); await Promise.all([loadApp(), refreshMessages(to)]); }
    catch (e) { setError(e instanceof Error ? e.message : "Message failed"); } finally { setSending(false); }
  };
  const deleteMessage = async (message: Activity) => {
    if (!window.confirm("Delete this message from Relay? This cannot be undone.")) return;
    setError("");
    try {
      await api(`/v1/messages/${encodeURIComponent(message.id)}`, { method: "DELETE" });
      setMessages((current) => current.filter((item) => item.id !== message.id));
      await loadApp();
    } catch (e) { setError(e instanceof Error ? e.message : "Message could not be deleted"); }
  };
  const deleteConversation = async (conversation: Conversation) => {
    if (!window.confirm(`Delete all messages, calls, and voicemails with ${displayPhone(conversation.peer)}? This cannot be undone.`)) return;
    setError("");
    try {
      await api(`/v1/conversations?peer=${encodeURIComponent(conversation.peer)}`, { method: "DELETE" });
      setConversations((current) => current.filter((item) => item.peer !== conversation.peer));
      if (peer === conversation.peer) { setPeer(""); setMessages([]); }
    } catch (e) { setError(e instanceof Error ? e.message : "Conversation could not be deleted"); }
  };
  const placeCall = async (destination: string) => {
    const to = phoneE164(destination); if (!me?.phone || !to) return;
    if (activeCall.current) { setError("A call is already in progress. Use Hang up before starting another call."); return; }
    if (!rtcClient.current || !voiceReady) { setError("Calling is connecting. Try again in a moment."); return; }
    setError(""); setCallPeer(to); setCallStatus("Connecting…"); setMobileDialer(true);
    const target = to === me.phone.e164 ? selfTarget : phoneDigits(to);
    if (!target) { setError("Self-test calling is still connecting. Try again in a moment."); return; }
    activeCall.current = rtcClient.current.newCall({ destinationNumber: target, callerNumber: phoneDigits(me.phone.e164), audio: true, remoteElement: "relay-remote-audio" });
  };

  const hangUp = async () => {
    const call = activeCall.current;
    if (!call) return;
    localHangup.current = true;
    setCallStatus("Ending…");
    await call.hangup();
  };

  if (auth === "loading") return <div className="loading-screen"><span className="brand-mark"><PhoneCall size={20}/></span><p>Opening Relay…</p></div>;
  if (auth === "setup" || auth === "login") return <AuthScreen mode={auth} onAuthenticated={() => void loadApp()}/>;
  if (!me) return null;

  return <main className={`unified-shell dialer-open ${peer && !settingsOpen ? "conversation-open" : ""} ${mobileDialer ? "mobile-dialer-open" : ""}`}>
    <aside className="activity-pane">
      <header className="app-header"><div className="brand compact"><span className="brand-mark"><PhoneCall size={19}/></span><span>Relay</span></div><div className="header-actions"><button className="settings-button" aria-label="Settings" onClick={() => setSettingsOpen(true)}><Cog size={19}/></button></div></header>
      <div className="own-number"><span className={`status-dot ${voiceReady ? "" : "offline"}`}/><div><small>Your number</small><strong>{me.phone ? displayPhone(me.phone.e164) : "Not provisioned"}</strong></div></div>
      <label className="search"><Search size={17}/><input placeholder="Search phone numbers"/></label>
      <p className="list-label">All communication</p>
      <div className="thread-list">
        {conversations.map((item) => <div className="thread-row" key={item.peer}><button className={`thread ${peer === item.peer && !settingsOpen ? "selected" : ""}`} onClick={() => selectPeer(item.peer)}><span className="avatar green">{initials(item.display_name)}</span><span className="thread-copy"><span><strong>{item.display_name === item.peer ? displayPhone(item.peer) : item.display_name}</strong><time>{formatTime(item.occurred_at)}</time></span><small>{item.kind === "call" ? <Phone size={12}/> : item.kind === "voicemail" ? <Play size={12}/> : null}{item.direction === "outbound" && item.kind === "message" ? "You: " : ""}{item.body}</small></span></button><button className="delete-thread" aria-label={`Delete conversation with ${displayPhone(item.peer)}`} title="Delete conversation" onClick={() => void deleteConversation(item)}><Trash2 size={15}/></button></div>)}
        {!conversations.length && <div className="empty-list"><p>No activity yet</p><small>Use the phone pane to start a call or message.</small></div>}
      </div>
      <footer><div className="profile"><span>{initials(me.user.display_name)}</span><div><strong>{me.user.display_name}</strong><small>{me.user.tenant_name}</small></div></div></footer>
    </aside>

    {settingsOpen ? <SettingsPane settings={settings} setSettings={setSettings} onClose={() => setSettingsOpen(false)} onSignOut={async () => { await api("/v1/auth/logout", { method: "POST" }); location.reload(); }}/> : <section className="communication-pane">
      <header><button className="mobile-back" aria-label="Back" onClick={() => setPeer("")}><ArrowLeft size={21}/></button><div className="avatar coral">{initials(selected?.display_name ?? displayPhone(peer))}</div><div><h2>{selected?.display_name ?? (displayPhone(peer) || "Communication")}</h2><small>{peer ? displayPhone(peer) : "Choose a number or start a conversation"}</small></div><div className="conversation-actions"><button aria-label="Message" disabled={!phoneE164(peer)} onClick={() => composerInput.current?.focus()}><MessageCircle size={19}/></button><button aria-label="Call" disabled={!phoneE164(peer)} onClick={() => void placeCall(peer)}><Phone size={19}/></button></div></header>
      <div className="messages">{!peer ? <div className="provision-state"><MessageCircle size={30}/><h3>One conversation, all communication</h3><p>Calls, texts, MMS, and voicemail activity for each number stay together.</p></div> : messages.length ? messages.map((item) => item.kind === "message" ? <div key={item.id} className={`bubble ${item.direction === "inbound" ? "incoming" : "outgoing"}`}><span className="message-body">{item.body}</span>{item.media?.length > 0 && <div className="message-media">{item.media.map((media, index) => media.contentType.startsWith("image/") ? <img key={media.key} src={`/v1/messages/${item.id}/media/${index}`} alt="MMS attachment"/> : media.contentType.startsWith("audio/") ? <audio key={media.key} controls src={`/v1/messages/${item.id}/media/${index}`}/> : <a key={media.key} href={`/v1/messages/${item.id}/media/${index}`} target="_blank" rel="noreferrer">Open attachment</a>)}</div>}<span className="message-meta"><time>{formatTime(item.occurred_at)}{item.direction === "outbound" ? ` · ${item.status}` : ""}</time><button className="delete-message" aria-label="Delete message" title="Delete message" onClick={() => void deleteMessage(item)}><Trash2 size={14}/></button></span></div> : item.kind === "call" ? <div key={item.id} className={`history-event call-event ${item.direction}`}><span className="history-icon"><Phone size={18}/></span><div><strong>{item.direction === "inbound" ? "Incoming call" : "Outgoing call"}</strong><small>{formatTime(item.occurred_at)} · {item.status}{item.duration_seconds != null ? ` · ${formatDuration(item.duration_seconds)}` : ""}</small></div></div> : <div key={item.id} className="history-event voicemail-event"><span className="history-icon"><Play size={18}/></span><div><strong>Voicemail</strong><small>{formatTime(item.occurred_at)}{item.duration_seconds != null ? ` · ${formatDuration(item.duration_seconds)}` : ""}</small>{item.status === "ready" ? <audio controls preload="metadata" src={`/v1/voicemails/${item.id}/audio`}/> : <span className="processing">Processing recording…</span>}</div></div>) : <div className="provision-state"><h3>{displayPhone(peer)}</h3><p>No communication with this number yet.</p></div>}</div>
      {error && <div className="inline-error">{error}</div>}
      <form className="composer" onSubmit={sendMessage}><button type="button" className="attach">+</button><input ref={composerInput} value={draft} onChange={(event) => setDraft(event.target.value)} disabled={!phoneE164(peer)} placeholder={peer ? `Message ${displayPhone(peer)}…` : "Select a phone number"}/><button type="button"><Mic size={19}/></button><button className="send" disabled={!draft.trim() || sending}><Send size={18}/><span>{sending ? "Sending" : "Send"}</span></button></form>
    </section>}

    <Dialer initialNumber={dialNumber || peer} ownNumber={me.phone?.e164} callStatus={callStatus} callSeconds={callSeconds} activeCall={activeCall.current} onNumber={setDialNumber} onMessage={(number) => { selectPeer(number); requestAnimationFrame(() => composerInput.current?.focus()); }} onCall={(number) => { setPeer(phoneE164(number)); setSettingsOpen(false); setMobileDialer(true); void placeCall(number); }} onHangup={() => void hangUp()} onClose={() => setMobileDialer(false)}/>
    <nav className="mobile-nav" aria-label="Relay navigation"><button className={!mobileDialer ? "active" : ""} onClick={() => setMobileDialer(false)}><MessageCircle/><span>Conversations</span></button><button className={mobileDialer ? "active" : ""} onClick={() => { setSettingsOpen(false); setMobileDialer(true); }}><Grid3X3/><span>Dialpad</span></button></nav>
    {incomingFrom && <div className="incoming-call"><div><small>Incoming Relay call</small><strong>{displayPhone(incomingFrom)}</strong></div><button className="decline" onClick={() => void activeCall.current?.hangup()}><X/></button><button className="answer" onClick={() => void activeCall.current?.answer({ remoteElement: "relay-remote-audio" })}><Phone/></button></div>}
    {callStatus && !incomingFrom && <div className="active-call-controller" role="status"><span className="call-live-dot"/><div><small>{callStatus}</small><strong>{displayPhone(callPeer)}</strong><time>{formatDuration(callSeconds)}</time></div><button className="keypad-toggle" aria-label="Open DTMF keypad" onClick={() => { setSettingsOpen(false); setMobileDialer(true); }}><Grid3X3/><span>Keypad</span></button><button className="hangup-control" onClick={() => void hangUp()}><Phone/><span>Hang up</span></button></div>}
    <audio id="relay-remote-audio" autoPlay/>
  </main>;
}

function SettingsPane({ settings, setSettings, onClose, onSignOut }: { settings: Settings; setSettings: (value: Settings) => void; onClose: () => void; onSignOut: () => void }) {
  const [saving, setSaving] = useState(false); const [recording, setRecording] = useState(false); const [message, setMessage] = useState(""); const recorder = useRef<MediaRecorder | null>(null); const chunks = useRef<Blob[]>([]);
  const save = async (next: Settings) => { setSettings(next); setSaving(true); setMessage(""); try { await api("/v1/settings", { method: "PUT", body: JSON.stringify(next) }); setMessage("Saved"); } catch (e) { setMessage(e instanceof Error ? e.message : "Could not save"); } finally { setSaving(false); } };
  const toggle = (key: "receiveWeb" | "receiveMobile" | "voicemailEnabled") => void save({ ...settings, [key]: !settings[key] });
  const record = async () => {
    if (recording) { recorder.current?.stop(); return; }
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true }); chunks.current = [];
    const nextRecorder = new MediaRecorder(stream); recorder.current = nextRecorder;
    nextRecorder.ondataavailable = (event) => { if (event.data.size) chunks.current.push(event.data); };
    nextRecorder.onstop = async () => { setRecording(false); stream.getTracks().forEach((track) => track.stop()); const audio = new Blob(chunks.current, { type: nextRecorder.mimeType || "audio/webm" }); const response = await fetch("/v1/settings/voicemail-greeting", { method: "PUT", credentials: "include", headers: { "Content-Type": audio.type }, body: audio }); if (response.ok) { setSettings({ ...settings, hasVoicemailGreeting: true, voicemailUpdatedAt: new Date().toISOString() }); setMessage("Voicemail greeting saved"); } else setMessage("Could not save the recording"); };
    nextRecorder.start(); setRecording(true); setMessage("Recording… tap stop when finished"); window.setTimeout(() => { if (nextRecorder.state === "recording") nextRecorder.stop(); }, 60_000);
  };
  return <section className="settings-pane"><header><button className="mobile-back" onClick={onClose}><ArrowLeft/></button><div><p>Relay</p><h1>Settings</h1></div><button className="close-settings" onClick={onClose}><X/></button></header><div className="settings-content"><section><h2>Receive calls on</h2><p>Choose which open Relay apps will ring.</p><SettingToggle label="Web browsers" detail="Relay tabs open on a computer" checked={settings.receiveWeb} onClick={() => toggle("receiveWeb")}/><SettingToggle label="Installed mobile app" detail="Relay added to your iPhone Home Screen" checked={settings.receiveMobile} onClick={() => toggle("receiveMobile")}/></section><section><h2>Voicemail</h2><p>Use a personal greeting when voicemail answering is enabled.</p><SettingToggle label="Voicemail answering" detail="Save unanswered calls to Relay" checked={settings.voicemailEnabled} onClick={() => toggle("voicemailEnabled")}/><div className="recording-card"><div><strong>{settings.hasVoicemailGreeting ? "Personal greeting" : "Default greeting"}</strong><small>{settings.hasVoicemailGreeting ? `Recorded ${settings.voicemailUpdatedAt ? formatTime(settings.voicemailUpdatedAt) : "recently"}` : "Record up to 60 seconds"}</small></div>{settings.hasVoicemailGreeting && <button aria-label="Play greeting" onClick={() => new Audio("/v1/settings/voicemail-greeting").play()}><Play/></button>}<button className={recording ? "recording" : ""} onClick={() => void record()}>{recording ? <CircleStop/> : <Mic/>}<span>{recording ? "Stop" : "Record"}</span></button></div></section>{message && <p className="settings-message">{saving ? "Saving…" : message}</p>}<button className="sign-out" onClick={onSignOut}>Sign out</button></div></section>;
}

function SettingToggle({ label, detail, checked, onClick }: { label: string; detail: string; checked: boolean; onClick: () => void }) { return <button className="setting-row" onClick={onClick}><span><strong>{label}</strong><small>{detail}</small></span><span className={`toggle ${checked ? "on" : ""}`}>{checked && <Check size={14}/>}</span></button>; }

function AuthScreen({ mode, onAuthenticated }: { mode: "setup" | "login"; onAuthenticated: () => void }) {
  const [error, setError] = useState(""); const [busy, setBusy] = useState(false);
  const submit = async (event: FormEvent<HTMLFormElement>) => { event.preventDefault(); setBusy(true); setError(""); const data = Object.fromEntries(new FormData(event.currentTarget)); try { if (mode === "setup") { const pending = await api<{ challengeId: string; options: Parameters<typeof startRegistration>[0]["optionsJSON"] }>("/v1/auth/register/options", { method: "POST", body: JSON.stringify(data) }); const credential = await startRegistration({ optionsJSON: pending.options }); await api("/v1/auth/register/verify", { method: "POST", body: JSON.stringify({ challengeId: pending.challengeId, credential }) }); } else { const pending = await api<{ challengeId: string; options: Parameters<typeof startAuthentication>[0]["optionsJSON"] }>("/v1/auth/login/options", { method: "POST", body: "{}" }); const credential = await startAuthentication({ optionsJSON: pending.options }); await api("/v1/auth/login/verify", { method: "POST", body: JSON.stringify({ challengeId: pending.challengeId, credential }) }); } onAuthenticated(); } catch (e) { setError(e instanceof Error ? e.message : "Authentication failed"); } finally { setBusy(false); } };
  return <main className="auth-screen"><section className="auth-card"><div className="brand auth-brand"><span className="brand-mark"><PhoneCall size={20}/></span><span>Relay</span></div><p className="eyebrow">{mode === "setup" ? "PRIVATE SETUP" : "WELCOME BACK"}</p><h1>{mode === "setup" ? "Create the owner account" : "Sign in to Relay"}</h1><p>{mode === "setup" ? "Create a secure passkey protected by Face ID or Touch ID." : "Use your Relay passkey to sign in."}</p><form onSubmit={submit}>{mode === "setup" && <><label>Your name<input name="displayName" required autoComplete="name"/></label><label>Workspace name<input name="workspaceName" required/></label><label>Email<input name="email" type="email" required autoComplete="email"/></label></>}{error && <div className="inline-error">{error}</div>}<button disabled={busy}>{busy ? "Waiting for your device…" : mode === "setup" ? "Create workspace with passkey" : "Sign in with passkey"}</button></form></section></main>;
}

function Dialer({ initialNumber, ownNumber, callStatus, callSeconds, activeCall, onNumber, onMessage, onCall, onHangup, onClose }: { initialNumber: string; ownNumber?: string; callStatus: string; callSeconds: number; activeCall: Call | null; onNumber: (number: string) => void; onMessage: (number: string) => void; onCall: (number: string) => void; onHangup: () => void; onClose: () => void }) {
  const [number, setNumber] = useState(phoneInput(initialNumber)); useEffect(() => setNumber(phoneInput(initialNumber)), [initialNumber]); const destination = phoneE164(number); const update = (value: string) => { const next = phoneInput(value); setNumber(next); onNumber(next); }; const pressKey = (key: string) => { if (activeCall && callStatus === "In call") activeCall.dtmf(key); else if (/\d/.test(key)) update(number + key); }; const minutes = `${String(Math.floor(callSeconds / 60)).padStart(2, "0")}:${String(callSeconds % 60).padStart(2, "0")}`;
  return <aside className="dialer-panel"><header><div><small>{callStatus === "In call" ? "DTMF KEYPAD" : "PHONE"}</small><h2>{callStatus || "New conversation"}</h2></div><button className="mobile-dialer-close" aria-label="Close dialpad" onClick={onClose}><X/></button></header><div className="dial-from"><span className={`status-dot ${ownNumber ? "" : "offline"}`}/><div><small>Calling from</small><strong>{ownNumber ? displayPhone(ownNumber) : "Not provisioned"}</strong></div></div><label className="dial-input"><Search/><input inputMode="tel" value={number} onChange={(event) => update(event.target.value)} placeholder="10-digit phone number" disabled={Boolean(activeCall)}/></label><div className="keypad">{["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"].map((key) => <button key={key} aria-label={callStatus === "In call" ? `Send DTMF ${key}` : key} onClick={() => pressKey(key)}>{key}</button>)}</div>{callStatus && <div className="call-progress"><span className="call-live-dot"/><div><strong>{callStatus}</strong><small>{callStatus === "In call" ? minutes : callStatus === "Call ended" ? "" : "Connecting"}</small></div></div>}<div className="dial-actions"><button className="message-button" disabled={!destination || Boolean(callStatus)} onClick={() => onMessage(destination)}><MessageCircle/><span>Message</span></button><button className="call-button" disabled={!activeCall && (!destination || callStatus === "Call ended")} onClick={() => activeCall ? onHangup() : onCall(destination)}><Phone/><span>{activeCall ? "Hang up" : "Call"}</span></button></div></aside>;
}
