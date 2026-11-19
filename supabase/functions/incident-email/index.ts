// PyroGuard incident-email (2026-11-19)
// ---------------------------------------------------------------------------
// Sends an alert e-mail WITH the newest camera photo when a serious incident is
// stored in public.event_history. It does NOT contact the BFP (the homeowner
// still taps CALL BFP in the app, as in fire-alert).
//
// Trigger: Supabase Dashboard -> Database -> Webhooks -> "incident-email"
//          table public.event_history, event INSERT, type "Supabase Edge Functions",
//          function incident-email, HTTP header  x-webhook-secret: <INCIDENT_WEBHOOK_SECRET>
// Manual test: POST {"record_key":"<event_history.record_key>"} with the same header.
//
// Sends for (override with INCIDENT_EMAIL_RULES, e.g. "CRITICAL_FIRE:0,DOOR_OPEN:2"):
//   CRITICAL_FIRE (any severity), DOOR_OPEN / WINDOW_OPEN / MOTION / INTRUSION with severity 2
//   (severity 2 = it happened while the system was ARMED).
// Recipients: the controller owner + approved Home 1 members, minus anyone whose
//   user_preferences.email_alerts = false. Optional extra: INCIDENT_EMAIL_EXTRA_TO.
// Photo: newest camera_events photo of that controller's camera taken from 60 s
//   before the incident up to PHOTO_WAIT_SECONDS (default 15 s) after it.
//
// E-mail provider (Edge Functions cannot use SMTP ports 25/587, so an HTTPS API is used):
//   BREVO_API_KEY  -> Brevo (works with a verified single sender, e.g. your Gmail address)
//   RESEND_API_KEY -> Resend (needs a verified domain to send to other people)
//   EMAIL_FROM     -> sender address, e.g. dev.pyroguard@gmail.com (Brevo-verified)
//   EMAIL_FROM_NAME (optional, default "PyroGuard Alerts"), APP_URL (optional link)
// ---------------------------------------------------------------------------
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { safeEqual } from '../_shared/device_auth.ts'

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined

const env = (n: string) => Deno.env.get(n)?.trim() ?? ''
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })

// Only Camera 1 exists (it covers ESP32-001's Entrance & Sala). Kitchen/Bedroom alerts from
// ESP32-002 are e-mailed without a photo.
const CAMERA_FOR: Record<string, string> = { 'ESP32-001': 'pyroguard_camera_001' }
const ROOM_LABEL: Record<string, string> = { entrance: 'Entrance', sala: 'Sala', kitchen: 'Kitchen', bedroom: 'Bedroom' }
const DEFAULT_RULES = 'CRITICAL_FIRE:0,INTRUSION:2,DOOR_OPEN:2,WINDOW_OPEN:2,MOTION:2'
const THROTTLE_MS = 5 * 60 * 1000

export function rules(text = env('INCIDENT_EMAIL_RULES') || DEFAULT_RULES): Record<string, number> {
  const out: Record<string, number> = {}
  for (const part of text.split(',')) {
    const [type, min] = part.split(':').map((s) => s.trim())
    if (type) out[type.toUpperCase()] = Number.isFinite(Number(min)) ? Number(min) : 0
  }
  return out
}
export function shouldEmail(eventType: string, severity: number, r = rules()) {
  const min = r[String(eventType).toUpperCase()]
  return min !== undefined && Number(severity ?? 0) >= min
}

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
const manila = (iso: string) =>
  new Date(iso).toLocaleString('en-PH', { timeZone: 'Asia/Manila', dateStyle: 'medium', timeStyle: 'medium' })

export function buildEmail(ev: Record<string, any>, photoUrl: string | null) {
  const p = (ev.payload_json && typeof ev.payload_json === 'object') ? ev.payload_json : {}
  const room = p.room_label ?? ROOM_LABEL[String(p.room_key ?? '')] ?? p.contact_label ?? p.coverage ?? ''
  const fire = ev.event_type === 'CRITICAL_FIRE'
  const title = fire ? `FIRE ALERT${room ? ' - ' + room : ''}` :
    ev.event_type === 'MOTION' ? 'Motion detected while ARMED' :
    `Intrusion alert - ${String(ev.event_type).replace('_', ' ').toLowerCase()}`
  const color = fire ? '#b91c1c' : '#c2410c'
  const appUrl = env('APP_URL')
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#f5f5f5;font-family:Arial,sans-serif;color:#222">
<table role="presentation" style="width:100%;max-width:600px;margin:auto;border-spacing:0;background:#fff;border-radius:18px;overflow:hidden">
<tr><td style="padding:24px 28px;background:${color};color:#fff;font-size:22px;font-weight:bold">PyroGuard - ${esc(title)}</td></tr>
<tr><td style="padding:24px 28px;line-height:1.6">
<p style="font-size:16px;margin-top:0"><b>${esc(ev.message)}</b></p>
<table style="font-size:14px;border-spacing:0 4px">
<tr><td style="color:#666;padding-right:14px">Time</td><td>${esc(manila(ev.created_at))} (PH time)</td></tr>
<tr><td style="color:#666;padding-right:14px">Controller</td><td>${esc(ev.device_id)}</td></tr>
${room ? `<tr><td style="color:#666;padding-right:14px">Area</td><td>${esc(room)}</td></tr>` : ''}
<tr><td style="color:#666;padding-right:14px">Event</td><td>${esc(ev.event_type)} (severity ${esc(ev.severity)})</td></tr>
</table>
${photoUrl ? `<p style="margin:20px 0 6px"><b>Camera photo</b> (also attached):</p>
<a href="${esc(photoUrl)}"><img src="${esc(photoUrl)}" alt="Camera photo" style="width:100%;max-width:544px;border-radius:12px;border:1px solid #ddd"></a>`
  : '<p style="color:#666">No camera photo was available for this event.</p>'}
${fire ? '<p style="margin-top:20px;padding:14px;background:#fff1ec;border-radius:12px"><b>Check the area safely. If there is a real fire, leave the house and call the BFP from the PyroGuard emergency screen.</b></p>' : ''}
${appUrl ? `<p><a href="${esc(appUrl)}" style="display:inline-block;padding:12px 20px;background:#126cba;color:#fff;border-radius:10px;text-decoration:none">Open PyroGuard</a></p>` : ''}
<p style="font-size:12px;color:#888">You receive this because e-mail alerts are on in your PyroGuard settings. Turn them off in Settings &gt; Notifications.</p>
</td></tr></table></body></html>`
  return { subject: `[PyroGuard] ${title}`, html }
}

async function recipients(db: SupabaseClient, ownerId: string | null): Promise<string[]> {
  const ids = new Set<string>()
  if (ownerId) ids.add(ownerId)
  const { data: home } = await db.from('pyroguard_shared_home').select('home_id').maybeSingle()
  if (home?.home_id) {
    const { data: members } = await db.from('pyroguard_home_members').select('user_id,membership_status')
      .eq('home_id', home.home_id)
    for (const m of members ?? []) if (String(m.membership_status ?? '').toLowerCase() === 'approved') ids.add(m.user_id)
  }
  if (!ids.size) return []
  const { data: prefs } = await db.from('user_preferences').select('user_id,email_alerts').in('user_id', [...ids])
  for (const p of prefs ?? []) if (p.email_alerts === false) ids.delete(p.user_id)
  const emails = new Set<string>()
  for (const id of ids) {
    const { data } = await db.auth.admin.getUserById(id)
    const email = data?.user?.email
    // Admin placeholder accounts (*.local) cannot receive mail.
    if (email && data?.user?.email_confirmed_at && !email.endsWith('.local')) emails.add(email.toLowerCase())
  }
  for (const extra of env('INCIDENT_EMAIL_EXTRA_TO').split(',').map((s) => s.trim()).filter(Boolean)) emails.add(extra.toLowerCase())
  return [...emails]
}

async function findPhoto(db: SupabaseClient, ev: Record<string, any>) {
  const camera = CAMERA_FOR[String(ev.device_id)]
  if (!camera) return null
  const from = new Date(Date.parse(ev.created_at) - 60_000).toISOString()
  const waitMs = Math.min(Math.max(Number(env('PHOTO_WAIT_SECONDS') || 15), 0), 40) * 1000
  const until = Date.now() + waitMs
  for (;;) {
    const { data } = await db.from('camera_events').select('snapshot_url,payload_json,created_at')
      .eq('device_id', camera).gte('created_at', from).not('snapshot_url', 'is', null)
      .order('created_at', { ascending: false }).limit(1).maybeSingle()
    if (data?.snapshot_url) {
      const path = (data.payload_json as any)?.storage_path ?? null
      return { url: String(data.snapshot_url), path: path ? String(path) : null }
    }
    if (Date.now() >= until) return null
    await new Promise((r) => setTimeout(r, 3000))
  }
}

async function attachment(db: SupabaseClient, photo: { url: string; path: string | null } | null) {
  if (!photo) return null
  try {
    let bytes: Uint8Array
    if (photo.path) {
      const { data, error } = await db.storage.from('incident-media').download(photo.path)
      if (error || !data) return null
      bytes = new Uint8Array(await data.arrayBuffer())
    } else {
      const r = await fetch(photo.url)
      if (!r.ok) return null
      bytes = new Uint8Array(await r.arrayBuffer())
    }
    if (bytes.length > 3 * 1024 * 1024) return null
    let bin = ''
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return btoa(bin)
  } catch { return null }
}

async function send(to: string[], subject: string, html: string, photoB64: string | null) {
  const from = env('EMAIL_FROM'), fromName = env('EMAIL_FROM_NAME') || 'PyroGuard Alerts'
  if (!from) throw new Error('Set the EMAIL_FROM secret')
  const filename = 'pyroguard-camera.jpg'
  if (env('BREVO_API_KEY')) {
    const r = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': env('BREVO_API_KEY'), 'Content-Type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        sender: { email: from, name: fromName }, to: to.map((email) => ({ email })), subject, htmlContent: html,
        ...(photoB64 ? { attachment: [{ name: filename, content: photoB64 }] } : {}),
      }),
    })
    if (!r.ok) throw new Error(`Brevo HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`)
    return 'brevo'
  }
  if (env('RESEND_API_KEY')) {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: `${fromName} <${from}>`, to, subject, html,
        ...(photoB64 ? { attachments: [{ filename, content: photoB64 }] } : {}),
      }),
    })
    if (!r.ok) throw new Error(`Resend HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`)
    return 'resend'
  }
  throw new Error('Set BREVO_API_KEY or RESEND_API_KEY')
}

async function handle(db: SupabaseClient, ev: Record<string, any>) {
  const key = String(ev.record_key ?? `event:${ev.id}`)
  const log = (fields: Record<string, unknown>) =>
    db.from('pyroguard_incident_emails').update(fields).eq('event_record_key', key)

  // Claim the event once (webhook retries / duplicates are ignored).
  const { data: claimed, error: claimError } = await db.from('pyroguard_incident_emails')
    .upsert({ event_record_key: key, device_id: ev.device_id, event_type: ev.event_type, status: 'pending' },
            { onConflict: 'event_record_key', ignoreDuplicates: true })
    .select('id')
  if (claimError) throw claimError
  if (!claimed?.length) return { skipped: 'already handled' }

  const { data: recent } = await db.from('pyroguard_incident_emails').select('id')
    .eq('device_id', ev.device_id).eq('event_type', ev.event_type).eq('status', 'sent')
    .gte('sent_at', new Date(Date.now() - THROTTLE_MS).toISOString()).limit(1)
  if (recent?.length) { await log({ status: 'skipped', error: 'throttled: same alert e-mailed in the last 5 minutes' }); return { skipped: 'throttled' } }

  const to = await recipients(db, ev.user_id ?? null)
  if (!to.length) { await log({ status: 'skipped', error: 'no recipient with e-mail alerts on' }); return { skipped: 'no recipients' } }

  try {
    const photo = await findPhoto(db, ev)
    const { subject, html } = buildEmail(ev, photo?.url ?? null)
    const provider = await send(to, subject, html, await attachment(db, photo))
    await log({ status: 'sent', provider, recipients: to, photo_path: photo?.path ?? photo?.url ?? null, sent_at: new Date().toISOString(), mysql_synced: false })
    return { sent: to.length, provider, photo: !!photo }
  } catch (e) {
    await log({ status: 'failed', recipients: to, error: String(e instanceof Error ? e.message : e).slice(0, 1000), mysql_synced: false })
    throw e
  }
}

if (import.meta.main) Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)
  const secret = env('INCIDENT_WEBHOOK_SECRET')
  if (!secret || !safeEqual(req.headers.get('x-webhook-secret') ?? '', secret)) return json({ ok: false, error: 'Unauthorized' }, 401)
  try {
    const body = await req.json().catch(() => ({})) as Record<string, any>
    const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } })

    let ev: Record<string, any> | null = body.record ?? null
    if (!ev && body.record_key) {
      const { data, error } = await db.from('event_history').select('*').eq('record_key', String(body.record_key)).maybeSingle()
      if (error) throw error
      ev = data
    }
    if (!ev) return json({ ok: false, error: 'No event record' }, 400)
    if (body.type && body.type !== 'INSERT') return json({ ok: true, skipped: 'not an insert' })
    if (!shouldEmail(ev.event_type, Number(ev.severity ?? 0))) return json({ ok: true, skipped: 'not an e-mail event' })

    // Answer the webhook at once; finish (wait for the photo, send) in the background.
    // Manual test: send {"record_key": "...", "wait": true} to see the result directly.
    if (body.wait || typeof EdgeRuntime === 'undefined') return json({ ok: true, result: await handle(db, ev) })
    EdgeRuntime.waitUntil(handle(db, ev).then((r) => console.log('incident-email', ev!.record_key, r))
      .catch((e) => console.error('incident-email failed', ev!.record_key, e)))
    return json({ ok: true, accepted: true }, 202)
  } catch (error) {
    console.error('incident-email:', error)
    return json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500)
  }
})
