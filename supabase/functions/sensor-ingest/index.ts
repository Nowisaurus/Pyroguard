// PyroGuard sensor-ingest (unified, 2026-11-19 sync fix)
// ---------------------------------------------------------------------------
// Stores the 5-second snapshot from each controller:
//   ESP32-001 (Batch 1): entrance, sala      ESP32-002 (Batch 2): kitchen, bedroom
//
//   pyroguard_room_sensor_readings   one row per room (every 10 s, or at once
//                                    when an alarm/fault field changes)
//   device_current_state             one live row per controller (upsert)
//   pyroguard_contact_current_state  door / window open-closed (if the table exists)
//   sensor_history                   controller snapshot, once a minute or on
//                                    every alarm change (analytics)
//
// FIRE is reported only when the firmware says fire_confirmed = true for a room
// (smoke AND flame both confirmed, sustained, neither sensor faulty). Older
// firmware without that field never produces a fire, only warnings.
// A sensor marked flame_fault / smoke_fault never contributes to a fire.
//
// Auth (either works): header x-device-key equal to the PYROGUARD_DEVICE_KEY
// (or PYROGUARD_INGEST_KEY) secret, or whose SHA-256 equals
// SENSOR_DEVICE_KEY_SHA256 (ESP32-001) / SENSOR_DEVICE_KEY_SHA256_ESP32_002.
// Also accepted: DEVICE_KEY_ESP32_001 / DEVICE_KEY_ESP32_002 (plain) or
// DEVICE_KEY_SHA256_ESP32_001 / _002 (see _shared/device_auth.ts).
// Deploy with JWT verification OFF (the ESP32 sends no user token).
// The firmware treats any reply without "stored":true as a failure.
//
// 2026-11-19 changes
//  * Accepts BOTH firmware payloads:
//      - unified sketch (2026-11-04b): rooms[] with fire_confirmed/flame_fault/smoke_fault
//      - v3.1 analog sketch: flat zone fields (smoke_status/flame/fire1 and
//        smoke2_status/flame2/fire2, temperature2, humidity2, door "open")
//  * Lower-case statuses from v3.1 (danger/normal/warning/warming/fault) are mapped.
//  * Reply also carries rooms_saved[] and count (older ESP32-001 sketches
//    check them before treating the upload as stored).
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
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  })
const env = (name: string) => Deno.env.get(name)?.trim() ?? ''

// ---------------------------------------------------------------- mapping --
export const CONTROLLERS = {
  'ESP32-001': { rooms: ['entrance', 'sala'], hashSecret: 'SENSOR_DEVICE_KEY_SHA256',
                 door: 'entrance', window: 'sala' },
  'ESP32-002': { rooms: ['kitchen', 'bedroom'], hashSecret: 'SENSOR_DEVICE_KEY_SHA256_ESP32_002',
                 door: 'kitchen', window: 'bedroom' },
} as const
export type Controller = keyof typeof CONTROLLERS
const LABEL: Record<string, string> = { entrance: 'Entrance', sala: 'Sala', kitchen: 'Kitchen', bedroom: 'Bedroom' }

const authorized = (req: Request, controller: Controller) =>
  deviceAuthorized(req, controller, [CONTROLLERS[controller].hashSecret])

/** Room key for one firmware room entry (descriptive key; old slot keys by position). */
export function roomFor(controller: Controller, entry: Record<string, unknown>, index: number): string | null {
  const allowed = CONTROLLERS[controller].rooms as readonly string[]
  const name = String(entry.room_key ?? '').trim().toLowerCase()
  if (allowed.includes(name)) return name
  return allowed[index] ?? null
}

// ------------------------------------------------------------- validation --
function num(value: unknown, min: number, max: number): number | null {
  if (value === null || value === undefined || value === '') return null
  const n = Number(value)
  return Number.isFinite(n) && n >= min && n <= max ? n : null
}
function bool(value: unknown): boolean | null {
  if (typeof value === 'boolean') return value
  if (value === 1 || value === '1' || value === 'true') return true
  if (value === 0 || value === '0' || value === 'false') return false
  return null
}
function smokeStatus(entry: Record<string, unknown>): string | null {
  const raw = String(entry.smoke_status ?? '').trim().toUpperCase()
  if (['ALARM', 'CLEAR', 'WARMUP', 'FAULT', 'WARNING'].includes(raw)) return raw
  if (['DANGER', 'SMOKE_ALARM', 'CRITICAL'].includes(raw)) return 'ALARM'
  if (['NORMAL', 'OK', 'SAFE'].includes(raw)) return 'CLEAR'
  if (['WARMING', 'WARMING UP', 'CALIBRATING', 'UNKNOWN', 'UNAVAILABLE'].includes(raw)) return 'WARMUP'
  const detected = bool(entry.smoke_detected)
  if (detected === true) return 'ALARM'
  if (detected === false) return 'CLEAR'
  return null
}

export interface RoomSample {
  room: string
  label: string
  temperature: number | null
  humidity: number | null
  smoke_raw: number | null
  smoke_status: string | null
  flame_detected: boolean | null
  buzzer_active: boolean | null
  fire_confirmed: boolean | null
  flame_fault: boolean | null
  smoke_fault: boolean | null
  sample_age_ms: number
}

/** v3.1 analog sketch: flat zone-1 fields + "2"-suffixed zone-2 fields. */
const faultFlag = (v: unknown) =>
  v === undefined || v === null ? null : typeof v === 'boolean' ? v : !['ok', 'none', ''].includes(String(v).trim().toLowerCase())
export function flatZones(body: Record<string, unknown>): Record<string, unknown>[] | null {
  const hasZone2 = ['smoke2_status', 'flame2', 'fire2', 'temperature2', 'humidity2'].some((k) => Object.hasOwn(body, k))
  const hasV31 = hasZone2 || Object.hasOwn(body, 'fire1') || Object.hasOwn(body, 'smoke_level')
  if (!hasV31) return null
  const buzzer = bool(body.buzzer_active) ?? (String(body.alarm ?? 'none') !== 'none' && bool(body.muted) !== true)
  const zone = (sfx: '' | '2', fireKey: string) => ({
    temperature: body[`temperature${sfx}`],
    humidity: body[`humidity${sfx}`],
    smoke_raw: body[`smoke${sfx}_mv`] ?? body[`smoke${sfx}_raw`],
    smoke_status: body[`smoke${sfx}_status`],
    smoke_fault: faultFlag(body[`smoke${sfx}_fault`]),
    flame_detected: body[sfx ? 'flame2' : 'flame'] ?? body[`flame${sfx}_detected`],
    flame_fault: faultFlag(body[`flame${sfx}_fault`]),
    fire_confirmed: body[fireKey],
    buzzer_active: buzzer,
  })
  return hasZone2 ? [zone('', 'fire1'), zone('2', 'fire2')] : [zone('', 'fire1')]
}

export function parseRooms(controller: Controller, body: Record<string, unknown>): RoomSample[] {
  const list: Record<string, unknown>[] = Array.isArray(body.rooms)
    ? (body.rooms as unknown[]).filter((r) => r && typeof r === 'object' && !Array.isArray(r)) as Record<string, unknown>[]
    : flatZones(body) ?? [body]
  const seen = new Set<string>()
  const out: RoomSample[] = []
  list.slice(0, 2).forEach((entry, index) => {
    const room = roomFor(controller, entry, index)
    if (!room || seen.has(room)) return
    seen.add(room)
    const flameFault = bool(entry.flame_fault)
    const smokeFault = bool(entry.smoke_fault)
    let smoke = smokeStatus(entry)
    if (smokeFault === true) smoke = 'FAULT'
    out.push({
      room,
      label: LABEL[room] ?? room,
      temperature: num(entry.temperature, -40, 125),
      humidity: num(entry.humidity, 0, 100),
      smoke_raw: num(entry.smoke_raw, 0, 4095),
      smoke_status: smoke,
      // A faulty (stuck / chattering) flame input is never reported as flame.
      flame_detected: flameFault === true ? false : bool(entry.flame_detected),
      buzzer_active: bool(entry.buzzer_active),
      fire_confirmed: bool(entry.fire_confirmed),
      flame_fault: flameFault,
      smoke_fault: smokeFault,
      sample_age_ms: num(entry.sample_age_ms ?? body.sample_age_ms, 0, 600000) ?? 0,
    })
  })
  return out
}

export const hasMeasurement = (r: RoomSample) =>
  r.temperature !== null || r.humidity !== null || r.smoke_raw !== null ||
  r.smoke_status !== null || r.flame_detected !== null

/** Fire in one room: ONLY when the guarded firmware confirmed it. Old
 *  firmware (no fire_confirmed field) produced noise-driven "fires", so its
 *  smoke/flame signals are reported as warnings only. */
export function roomOnFire(r: RoomSample) {
  if (r.flame_fault === true || r.smoke_fault === true) return false
  return r.fire_confirmed === true
}

const TEMP_WARN_C = 50

/** door_open:true|false, or v3.1 door:"open"|"closed" (window "n/a" = not installed). */
export function contactOpen(body: Record<string, unknown>, which: 'door' | 'window'): boolean | null {
  const direct = bool(body[`${which}_open`])
  if (direct !== null) return direct
  const text = String(body[which] ?? '').trim().toLowerCase()
  return text === 'open' ? true : text === 'closed' ? false : null
}

export function summarize(rooms: RoomSample[], body: Record<string, unknown>) {
  const fireRoom = rooms.find(roomOnFire)
  const flameRooms = rooms.filter((r) => r.flame_detected === true)
  const smokeRooms = rooms.filter((r) => r.smoke_status === 'ALARM')
  const hotRooms = rooms.filter((r) => r.temperature !== null && r.temperature > TEMP_WARN_C)
  const faultRooms = rooms.filter((r) => r.flame_fault === true || r.smoke_fault === true)
  const primary = fireRoom ?? rooms.find((r) => r.temperature !== null) ?? rooms[0]
  const intrusion = bool(body.intrusion) === true
  const mode = String(body.system_mode ?? '').trim().toUpperCase()
  const systemMode = ['DISARMED', 'ARM_HOME', 'ARM_AWAY'].includes(mode) ? mode : null

  // The controller-level smoke_status is ALARM only together with a confirmed
  // fire, or when no room reports flame. Smoke in one room + flame in another
  // is a WARNING, never a fire.
  let smoke: string | null
  if (fireRoom) smoke = 'ALARM'
  else if (smokeRooms.length && flameRooms.length) smoke = 'WARNING'
  else if (smokeRooms.length) smoke = 'ALARM'
  else if (rooms.some((r) => r.smoke_status === 'WARMUP')) smoke = 'WARMUP'
  else if (rooms.some((r) => r.smoke_status === 'FAULT')) smoke = 'FAULT'
  else smoke = rooms.some((r) => r.smoke_status === 'CLEAR') ? 'CLEAR' : null

  let alert = 'SAFE', incident = 'Normal', severity = 0
  if (fireRoom) {
    alert = 'CRITICAL'; incident = `Fire Detected - ${fireRoom.label}`; severity = 2
  } else if (intrusion) {
    alert = 'INTRUSION'; incident = 'Intrusion'; severity = 2
  } else if (flameRooms.length || smokeRooms.length || hotRooms.length) {
    alert = 'WARNING'; severity = 1
    const names = [...new Set([...flameRooms, ...smokeRooms, ...hotRooms].map((r) => r.label))]
    incident = `${flameRooms.length ? 'Flame' : smokeRooms.length ? 'Smoke' : 'High temperature'} warning - ${names.join(' & ')}`
  } else if (faultRooms.length) {
    alert = 'SENSOR_FAULT'; incident = `Check sensor - ${faultRooms.map((r) => r.label).join(' & ')}`
  }

  const raws = rooms.map((r) => r.smoke_raw).filter((v): v is number => v !== null)
  const door = contactOpen(body, 'door')
  const windowOpen = contactOpen(body, 'window')
  return {
    temperature: primary?.temperature ?? null,
    humidity: primary?.humidity ?? null,
    smoke_raw: raws.length ? Math.max(...raws) : null,
    smoke_level: raws.length ? Math.round((Math.max(...raws) / 4095) * 1000) / 10 : null,
    smoke_status: smoke,
    // Controller flame flag is only true together with a confirmed fire, so
    // a flame in one room + smoke in another can never look like a fire.
    flame_detected: fireRoom ? true : smokeRooms.length ? false : flameRooms.length > 0,
    alert_status: alert,
    incident_type: incident,
    severity_level: severity,
    door_status: door === null ? null : door ? 'OPEN' : 'CLOSED',
    window_status: windowOpen === null ? null : windowOpen ? 'OPEN' : 'CLOSED',
    motion_detected: bool(body.motion_detected),
    system_armed: bool(body.system_armed) ?? (systemMode ? systemMode !== 'DISARMED' : null),
    system_mode: systemMode,
    siren_active: bool(body.buzzer_active) === true || rooms.some((r) => r.buzzer_active === true),
  }
}

const ROOM_MIN_GAP_MS = 10_000
const HISTORY_MIN_GAP_MS = 60_000
const missingColumn = (msg: string) => /column|schema cache/i.test(msg)

if (import.meta.main) Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ ok: false, stored: false, error: 'POST only' }, 405)
  try {
    const raw = await req.text()
    if (raw.length > 16384) return json({ ok: false, stored: false, error: 'Payload too large' }, 413)
    let body: Record<string, unknown>
    try { body = JSON.parse(raw) } catch { return json({ ok: false, stored: false, error: 'Invalid JSON' }, 400) }
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return json({ ok: false, stored: false, error: 'JSON object required' }, 400)
    }
    const deviceId = String(body.device_id ?? req.headers.get('x-device-id') ?? '').trim()
    if (!Object.hasOwn(CONTROLLERS, deviceId)) {
      return json({ ok: false, stored: false, error: 'device_id must be ESP32-001 or ESP32-002' }, 400)
    }
    const controller = deviceId as Controller
    if (!(await authorized(req, controller))) return json({ ok: false, stored: false, error: 'Invalid device key.' }, 401)

    const url = env('SUPABASE_URL'), service = env('SUPABASE_SERVICE_ROLE_KEY')
    if (!url || !service) return json({ ok: false, stored: false, error: 'Server database configuration missing' }, 503)
    const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } })

    const { data: registered, error: registryError } = await db.from('devices')
      .select('device_id,user_id').eq('device_id', controller).maybeSingle()
    if (registryError) throw registryError
    if (!registered) return json({ ok: false, stored: false, error: `Register ${controller} in public.devices first` }, 404)
    if (!registered.user_id) return json({ ok: false, stored: false, error: `${controller} needs its owner (devices.user_id)` }, 409)
    const ownerId = String(registered.user_id)

    const rooms = parseRooms(controller, body).filter(hasMeasurement)
    if (!rooms.length) return json({ ok: false, stored: false, error: 'No real sensor measurement in payload' }, 400)
    const now = Date.now()
    const nowIso = new Date(now).toISOString()
    const summary = summarize(rooms, body)

    // 1) live controller state
    const { error: stateError } = await db.from('device_current_state')
      .upsert({ device_id: controller, ...summary, updated_at: nowIso }, { onConflict: 'device_id' })
    if (stateError) throw new Error(`device_current_state: ${stateError.message}`)

    // 2) room readings
    const roomResults: Record<string, string> = {}
    for (const r of rooms) {
      let { data: last, error: lastError } = await db.from('pyroguard_room_sensor_readings')
        .select('received_at,smoke_status,flame_detected,buzzer_active,smoke_raw,fire_confirmed,flame_fault,smoke_fault')
        .eq('controller_device_id', controller).eq('room_key', r.room)
        .order('received_at', { ascending: false }).limit(1).maybeSingle()
      // Before the 20261104b migration the safety columns do not exist yet.
      if (lastError && missingColumn(lastError.message)) {
        ({ data: last, error: lastError } = await db.from('pyroguard_room_sensor_readings')
          .select('received_at,smoke_status,flame_detected,buzzer_active')
          .eq('controller_device_id', controller).eq('room_key', r.room)
          .order('received_at', { ascending: false }).limit(1).maybeSingle())
      }
      if (lastError) throw new Error(`room read: ${lastError.message}`)
      const fireNow = r.fire_confirmed === null ? null : roomOnFire(r)
      const prev = (last ?? {}) as Record<string, unknown>
      // A confirmed fire, or a sensor fault, appearing/clearing is a change too
      // (before, flame -> confirmed fire 2 s later was skipped as "recent").
      const changed = !last || last.smoke_status !== r.smoke_status ||
        last.flame_detected !== r.flame_detected || last.buzzer_active !== r.buzzer_active ||
        ('fire_confirmed' in prev && (prev.fire_confirmed ?? null) !== fireNow) ||
        ('flame_fault' in prev && (prev.flame_fault ?? null) !== (r.flame_fault ?? null)) ||
        ('smoke_fault' in prev && (prev.smoke_fault ?? null) !== (r.smoke_fault ?? null)) ||
        // gas level moved noticeably (MQ-2 analog mV, firmware v11+)
        (typeof prev.smoke_raw === 'number' && r.smoke_raw !== null && Math.abs(prev.smoke_raw - r.smoke_raw) >= 40) ||
        ('smoke_raw' in prev && ((prev.smoke_raw ?? null) === null) !== (r.smoke_raw === null))
      const lastAt = last ? Date.parse(String(last.received_at)) : 0
      // While a room is on fire every upload is stored (min 2 s apart), so the
      // app's "two successive confirmed readings" rule is met within seconds.
      const minGap = fireNow === true ? 2_000 : ROOM_MIN_GAP_MS
      if (!changed && now - lastAt < minGap) { roomResults[r.room] = 'recent'; continue }
      const base = {
        user_id: ownerId, controller_device_id: controller, room_key: r.room,
        temperature: r.temperature, humidity: r.humidity, smoke_raw: r.smoke_raw,
        smoke_status: r.smoke_status, flame_detected: r.flame_detected, buzzer_active: r.buzzer_active,
        sampled_at: new Date(now - r.sample_age_ms).toISOString(), received_at: nowIso,
      }
      let { error } = await db.from('pyroguard_room_sensor_readings').insert({
        ...base, fire_confirmed: r.fire_confirmed === null ? null : roomOnFire(r),
        flame_fault: r.flame_fault, smoke_fault: r.smoke_fault,
      })
      // Before the 20261104b migration the safety columns do not exist yet.
      if (error && missingColumn(error.message)) ({ error } = await db.from('pyroguard_room_sensor_readings').insert(base))
      if (error) throw new Error(`room insert (${r.label}): ${error.message}`)
      roomResults[r.room] = 'stored'
    }

    // 3) door / window current state (optional table)
    const contacts: Record<string, unknown>[] = []
    const door = contactOpen(body, 'door'), win = contactOpen(body, 'window')
    if (door !== null) contacts.push({ device_id: controller, room_key: CONTROLLERS[controller].door, contact_type: 'door', is_open: door, received_at: nowIso })
    if (win !== null) contacts.push({ device_id: controller, room_key: CONTROLLERS[controller].window, contact_type: 'window', is_open: win, received_at: nowIso })
    let contactResult = 'none'
    if (contacts.length) {
      const { error } = await db.from('pyroguard_contact_current_state')
        .upsert(contacts.map((c) => ({ ...c, updated_at: nowIso })), { onConflict: 'device_id,contact_type' })
      contactResult = error ? `skipped (${error.message})` : 'stored'
    }

    // 4) controller history (analytics)
    let history = 'recent'
    const { data: lastHistory, error: hErr } = await db.from('sensor_history')
      .select('created_at,alert_status').eq('device_id', controller)
      .order('created_at', { ascending: false }).limit(1).maybeSingle()
    if (hErr) throw new Error(`sensor_history read: ${hErr.message}`)
    const lastHistoryAt = lastHistory ? Date.parse(String(lastHistory.created_at)) : 0
    if (!lastHistory || lastHistory.alert_status !== summary.alert_status || now - lastHistoryAt >= HISTORY_MIN_GAP_MS) {
      const base = { user_id: ownerId, device_id: controller, ...summary, mysql_synced: false, created_at: nowIso }
      let { error } = await db.from('sensor_history').insert({ ...base, payload_json: { rooms, source: 'sensor-ingest' } })
      if (error && /payload_json/.test(error.message)) ({ error } = await db.from('sensor_history').insert(base))
      if (error) throw new Error(`sensor_history insert: ${error.message}`)
      history = 'stored'
    }

    const roomsSaved = Object.keys(roomResults)
    return json({ ok: true, stored: true, device_id: controller, rooms: roomResults,
      rooms_saved: roomsSaved, count: roomsSaved.length,
      contacts: contactResult, history, alert_status: summary.alert_status })
  } catch (error) {
    console.error('sensor-ingest:', error)
    return json({ ok: false, stored: false, error: error instanceof Error ? error.message : String(error) }, 500)
  }
})