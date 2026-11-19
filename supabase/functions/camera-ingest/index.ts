// PyroGuard camera-ingest (2026-11-19)
// ---------------------------------------------------------------------------
// Called by the camera firmware (no user login, deploy with verify_jwt = false).
//
//   POST ?action=heartbeat   JSON {device_id, ip_address, rssi, uptime_ms?, motion_detected?}
//        -> upsert public.pyroguard_camera_telemetry (status 'online')
//
//   POST ?action=photo&device_id=<camera>&reason=<motion|fire|intrusion|manual>
//        body: raw JPEG (Content-Type image/jpeg, max 2 MB)
//        -> Storage bucket incident-media/<camera>/<yyyy>/<mm>/<dd>/<time>_<reason>.jpg
//        -> public.camera_events row (snapshot_url, payload_json.reason, storage_path)
//        The incident-email function attaches the newest photo to alert e-mails.
//
// Auth: header x-device-key, checked against DEVICE_KEY_PYROGUARD_CAMERA_001 (plain),
// DEVICE_KEY_SHA256_PYROGUARD_CAMERA_001, CAMERA_DEVICE_KEY_SHA256, or the shared
// PYROGUARD_DEVICE_KEY (see _shared/device_auth.ts).
// ---------------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2'
import { deviceAuthorized } from '../_shared/device_auth.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, x-device-key, x-device-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status, headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  })
const env = (n: string) => Deno.env.get(n)?.trim() ?? ''

// PyroGuard has ONE camera: Camera 1 (DFR1154, two-way audio) on ESP32-001.
export const CAMERAS: Record<string, { controller: string; coverage: string }> = {
  pyroguard_camera_001: { controller: 'ESP32-001', coverage: 'Entrance & Sala' },
}
const REASONS = ['motion', 'fire', 'intrusion', 'manual', 'test'] as const
const BUCKET = 'incident-media'
const MAX_PHOTO_BYTES = 2 * 1024 * 1024
const PHOTO_MIN_GAP_MS = 4000
const missingColumn = (msg: string) => /column|schema cache/i.test(msg)

export function photoPath(camera: string, reason: string, at: Date) {
  const iso = at.toISOString()                       // 2026-11-19T06:31:02.123Z
  const [date, time] = iso.split('T')
  const [y, m, d] = date.split('-')
  return `${camera}/${y}/${m}/${d}/${time.replace(/[:.Z]/g, '').slice(0, 9)}_${reason}.jpg`
}
export const isJpeg = (b: Uint8Array) => b.length > 4 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff

if (import.meta.main) Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)
  try {
    const url = new URL(req.url)
    const action = (url.searchParams.get('action') ?? '').toLowerCase()
    const isPhoto = action === 'photo'

    let body: Record<string, unknown> = {}
    let photo: Uint8Array | null = null
    if (isPhoto) {
      const length = Number(req.headers.get('content-length') ?? '0')
      if (length > MAX_PHOTO_BYTES) return json({ ok: false, error: 'Photo too large (max 2 MB)' }, 413)
      photo = new Uint8Array(await req.arrayBuffer())
      if (photo.length > MAX_PHOTO_BYTES) return json({ ok: false, error: 'Photo too large (max 2 MB)' }, 413)
      if (!isJpeg(photo)) return json({ ok: false, error: 'JPEG body required' }, 415)
    } else if (action === 'heartbeat') {
      try { body = await req.json() } catch { return json({ ok: false, error: 'Invalid JSON' }, 400) }
    } else {
      return json({ ok: false, error: 'action must be heartbeat or photo' }, 400)
    }

    const camera = String(url.searchParams.get('device_id') ?? body.device_id ?? req.headers.get('x-device-id') ?? '').trim()
    const info = CAMERAS[camera]
    if (!info) return json({ ok: false, error: `Unknown camera ${camera || '(none)'}` }, 400)
    if (!(await deviceAuthorized(req, camera, ['CAMERA_DEVICE_KEY_SHA256']))) {
      return json({ ok: false, error: 'Invalid device key.' }, 401)
    }

    const supabaseUrl = env('SUPABASE_URL'), service = env('SUPABASE_SERVICE_ROLE_KEY')
    if (!supabaseUrl || !service) return json({ ok: false, error: 'Server database configuration missing' }, 503)
    const db = createClient(supabaseUrl, service, { auth: { persistSession: false, autoRefreshToken: false } })

    const { data: controller, error: regError } = await db.from('devices')
      .select('device_id,user_id').eq('device_id', info.controller).maybeSingle()
    if (regError) throw regError
    if (!controller?.user_id) return json({ ok: false, error: `Register ${info.controller} (with its owner) in public.devices first` }, 404)
    const now = new Date()

    if (!isPhoto) {
      const rssi = Number(body.rssi)
      const uptime = Number(body.uptime_ms)
      const ip = String(body.ip_address ?? '').trim()
      const record: Record<string, unknown> = {
        camera_device_id: camera, device_id: info.controller, status: 'online', updated_at: now.toISOString(),
      }
      if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) record.camera_ip = ip
      if (Number.isFinite(rssi) && rssi < 0 && rssi > -127) record.wifi_rssi = Math.round(rssi)
      if (Number.isFinite(uptime) && uptime >= 0) record.uptime_ms = Math.round(uptime)
      if (typeof body.motion_detected === 'boolean') record.motion_detected = body.motion_detected
      const { error } = await db.from('pyroguard_camera_telemetry').upsert(record, { onConflict: 'camera_device_id' })
      if (error) throw new Error(`camera telemetry: ${error.message}`)
      return json({ ok: true, saved: true, camera, controller: info.controller })
    }

    // ---- photo ----
    const reasonParam = (url.searchParams.get('reason') ?? 'manual').toLowerCase()
    const reason = (REASONS as readonly string[]).includes(reasonParam) ? reasonParam : 'manual'

    const { data: last } = await db.from('camera_events').select('created_at')
      .eq('device_id', camera).order('created_at', { ascending: false }).limit(1).maybeSingle()
    if (last && now.getTime() - Date.parse(String(last.created_at)) < PHOTO_MIN_GAP_MS && reason === 'motion') {
      return json({ ok: false, error: 'Too many photos, wait a few seconds' }, 429)
    }

    const path = photoPath(camera, reason, now)
    const { error: upError } = await db.storage.from(BUCKET)
      .upload(path, photo!, { contentType: 'image/jpeg', upsert: false })
    if (upError) throw new Error(`storage upload: ${upError.message} (run 01_SUPABASE_FINAL_SYNC_FIX.sql to create the bucket)`)
    const publicUrl = db.storage.from(BUCKET).getPublicUrl(path).data.publicUrl

    const recordKey = `${camera}:photo:${now.getTime()}`
    const payload = {
      camera_device_id: camera, controller_device_id: info.controller, coverage: info.coverage,
      reason, bytes: photo!.length, storage_bucket: BUCKET, storage_path: path, source: 'camera-ingest',
    }
    const base = {
      user_id: controller.user_id, device_id: camera, record_key: recordKey,
      event_type: reason === 'manual' ? 'manual_snapshot' : `${reason}_snapshot`,
      snapshot_url: publicUrl, created_at: now.toISOString(),
    }
    let { error } = await db.from('camera_events').insert({ ...base, payload_json: payload, mysql_synced: false })
    if (error && missingColumn(error.message)) ({ error } = await db.from('camera_events').insert({ ...base, payload_json: payload }))
    if (error) throw new Error(`camera_events: ${error.message}`)

    return json({ ok: true, stored: true, camera, reason, path, url: publicUrl, record_key: recordKey })
  } catch (error) {
    console.error('camera-ingest:', error)
    return json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500)
  }
})
