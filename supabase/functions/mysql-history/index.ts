import { localMode, localStatus } from '../_shared/local_sync.ts'
import { createClient } from '@supabase/supabase-js'
import { createConnection, type Connection } from 'mysql2/promise'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-device-key',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function env(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`Missing Supabase Edge Function secret: ${name}`)
  return value
}

function clampLimit(value: unknown, fallback: number, max: number) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return fallback
  return Math.max(1, Math.min(max, Math.trunc(parsed)))
}

function clean(value: unknown, fallback: unknown = null) {
  if (value === undefined || value === '') return fallback
  return value
}

function nullableBoolean(value: unknown): boolean | null {
  if (typeof value === 'boolean') return value
  if (value === 1 || value === '1' || value === 'true') return true
  if (value === 0 || value === '0' || value === 'false') return false
  return null
}

function mysqlDate(value: unknown): Date {
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value
  if (typeof value === 'string' || typeof value === 'number') {
    const parsed = new Date(value)
    if (!Number.isNaN(parsed.getTime())) return parsed
  }
  return new Date()
}

async function authenticate(req: Request) {
  const authorization = req.headers.get('Authorization') ?? ''
  const token = authorization.startsWith('Bearer ')
    ? authorization.substring('Bearer '.length).trim()
    : ''

  let user: any = null
  if (token) {
    const supabase = createClient(
      env('SUPABASE_URL'),
      env('SUPABASE_ANON_KEY'),
      { global: { headers: { Authorization: `Bearer ${token}` } } },
    )
    const { data, error } = await supabase.auth.getUser(token)
    if (!error) user = data.user
  }

  const configuredDeviceKey = Deno.env.get('PYROGUARD_DEVICE_KEY')?.trim() ?? ''
  const suppliedDeviceKey = req.headers.get('x-device-key')?.trim() ?? ''
  const deviceAuthorized = configuredDeviceKey.length > 0 &&
    suppliedDeviceKey.length > 0 &&
    suppliedDeviceKey === configuredDeviceKey

  return { user, deviceAuthorized }
}

function requestedDevice(body: Record<string, unknown>, user: any): string | null {
  const requested = clean(body.device_id)?.toString().trim() ?? ''
  const owned = user?.user_metadata?.device_id?.toString().trim() ?? ''

  // If the account is paired to a specific PyroGuard ID, a client cannot
  // request another device's anonymous firmware history.
  if (user && owned && requested && owned !== requested) {
    throw new Error('Requested device is not paired to this account.')
  }
  return requested || owned || null
}

function userIdForWrite(user: any, deviceAuthorized: boolean) {
  if (user?.id) return String(user.id)
  if (deviceAuthorized) {
    const owner = Deno.env.get('PYROGUARD_OWNER_USER_ID')?.trim()
    return owner || null
  }
  return null
}

const requiredMysqlSecrets = ['MYSQL_HOST', 'MYSQL_USER', 'MYSQL_PASSWORD', 'MYSQL_DATABASE']
function missingMysqlSecrets() {
  return requiredMysqlSecrets.filter((key) => key === 'MYSQL_PASSWORD'
    ? Deno.env.get(key) === undefined : !Deno.env.get(key)?.trim())
}
function mysqlPort() {
  const port = Number(Deno.env.get('MYSQL_PORT') ?? '3306')
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid MYSQL_PORT')
  return port
}
function mysqlFailure(error: unknown) {
  const code = String((error as { code?: string })?.code ?? '')
  const message = error instanceof Error ? error.message : String(error)
  if (message.includes('Missing Supabase Edge Function secret') || message === 'Invalid MYSQL_PORT') {
    return { error_code: 'MYSQL_CONFIGURATION', error: message,
      resolution: 'Set MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD and MYSQL_DATABASE in Supabase Edge Function Secrets.' }
  }
  if (code === 'ER_ACCESS_DENIED_ERROR') return { error_code: code,
    error: 'MySQL rejected the database login.', resolution: 'Check MYSQL_USER and MYSQL_PASSWORD and grant this user remote access to the PyroGuard database.' }
  if (code === 'ER_BAD_DB_ERROR') return { error_code: code,
    error: 'The configured MySQL database does not exist.', resolution: 'Check MYSQL_DATABASE and install the PyroGuard MySQL schema.' }
  if (['ECONNREFUSED', 'ETIMEDOUT', 'ENOTFOUND', 'EHOSTUNREACH'].includes(code)) return {
    error_code: code, error: 'The Edge Function cannot reach the MySQL server.',
    resolution: 'Use a remotely reachable MySQL hostname. localhost, 127.0.0.1 and a private home IP point to a different network. Check remote access, port and firewall rules.' }
  if (/ssl|tls|certificate/i.test(message)) return { error_code: 'MYSQL_TLS',
    error: 'MySQL TLS negotiation failed.', resolution: 'Check the database provider TLS requirements. Keep MYSQL_SSL=true for a TLS-enabled server; use false only for a server configured without TLS.' }
  return { error_code: code || 'MYSQL_QUERY_FAILED', error: 'MySQL query failed.',
    resolution: 'Inspect mysql-history server logs and compare the installed schema with mysql/Pyroguard_MYSQL.sql.' }
}

function connectionOptions() {
  const sslEnabled = (Deno.env.get('MYSQL_SSL') ?? 'true').toLowerCase() !== 'false'
  return {
    host: env('MYSQL_HOST'),
    port: mysqlPort(),
    user: env('MYSQL_USER'),
    password: Deno.env.get('MYSQL_PASSWORD') ?? '',
    database: env('MYSQL_DATABASE'),
    connectTimeout: 8000,
    decimalNumbers: true,
    timezone: 'Z',
    ssl: sslEnabled ? { rejectUnauthorized: true } : undefined,
  }
}

async function withDb<T>(work: (db: Connection) => Promise<T>): Promise<T> {
  const db = await createConnection(connectionOptions())
  try {
    return await work(db)
  } finally {
    await db.end()
  }
}

async function withTransaction<T>(work: (db: Connection) => Promise<T>): Promise<T> {
  const db = await createConnection(connectionOptions())
  try {
    await db.beginTransaction()
    const result = await work(db)
    await db.commit()
    return result
  } catch (error) {
    try { await db.rollback() } catch (_) {}
    throw error
  } finally {
    await db.end()
  }
}

async function writeDualLedger(
  db: Connection,
  body: Record<string, any>,
  fallback: {
    userId: string | null,
    deviceId: string | null,
    recordType: string,
    recordKey: string,
    operation?: string,
    source?: string,
    payload: unknown,
  },
) {
  const d = (body.dual_record ?? {}) as Record<string, any>
  const recordId = String(clean(d.record_id, crypto.randomUUID()))
  const ledgerUserId = clean(d.user_id, fallback.userId)
  const ledgerDeviceId = clean(d.device_id, fallback.deviceId)
  const recordType = String(clean(d.record_type, fallback.recordType))
  const recordKey = String(clean(d.record_key, fallback.recordKey))
  const operation = String(clean(d.operation, fallback.operation ?? 'UPSERT'))
  const source = String(clean(d.source, fallback.source ?? 'edge_function'))
  const payload = clean(d.payload, fallback.payload)
  const createdAt = mysqlDate(d.created_at)

  await db.execute(
    `INSERT INTO pyroguard_dual_record_ledger
      (record_id,user_id,device_id,record_type,record_key,operation,source,payload,mysql_synced,mysql_synced_at,last_sync_error,created_at)
     VALUES (?,?,?,?,?,?,?,?,TRUE,CURRENT_TIMESTAMP(3),NULL,?)
     ON DUPLICATE KEY UPDATE
       user_id=VALUES(user_id), device_id=VALUES(device_id),
       record_type=VALUES(record_type), record_key=VALUES(record_key),
       operation=VALUES(operation), source=VALUES(source), payload=VALUES(payload),
       mysql_synced=TRUE, mysql_synced_at=CURRENT_TIMESTAMP(3), last_sync_error=NULL`,
    [recordId, ledgerUserId, ledgerDeviceId, recordType, recordKey, operation, source, JSON.stringify(payload), createdAt],
  )
  return recordId
}

async function upsertAccountIdentity(
  db: Connection,
  user: any,
  payload: Record<string, any>,
) {
  if (!user?.id) return
  const metadataRole = String(user?.app_metadata?.role ?? '').trim()
  const accountRole = metadataRole === 'head_developer' || metadataRole === 'administrator'
    ? metadataRole
    : 'homeowner'
  const email = String(user.email ?? payload.email ?? '').trim() || null
  const displayName = String(
    payload.display_name ?? payload.full_name ?? user?.user_metadata?.full_name ??
    user?.user_metadata?.name ?? (email ? email.split('@')[0] : 'PyroGuard User'),
  )
  const phone = String(payload.phone ?? user?.user_metadata?.phone_number ?? user?.phone ?? '').trim() || null
  const provider = String(user?.app_metadata?.provider ?? payload.auth_provider ?? 'email')
  const emailConfirmed = Boolean(user?.email_confirmed_at ?? payload.email_confirmed)
  const event = String(payload.event ?? '')
  const loginAt = payload.logged_in_at ?? (event.endsWith('_login') ? new Date().toISOString() : null)
  const logoutAt = payload.logged_out_at ?? (event.endsWith('_logout') ? new Date().toISOString() : null)

  await db.execute(
    `INSERT INTO pyroguard_account_identities
      (user_id,email,display_name,phone,account_role,auth_provider,email_confirmed,account_status,last_login_at,last_logout_at,mysql_synced,mysql_synced_at,last_sync_error,created_at,updated_at)
     VALUES (?,?,?,?,?,?,?,?,?,?,TRUE,CURRENT_TIMESTAMP(3),NULL,?,?)
     ON DUPLICATE KEY UPDATE
       email=VALUES(email), display_name=VALUES(display_name), phone=VALUES(phone),
       account_role=VALUES(account_role), auth_provider=VALUES(auth_provider),
       email_confirmed=VALUES(email_confirmed), account_status=VALUES(account_status),
       last_login_at=COALESCE(VALUES(last_login_at),last_login_at),
       last_logout_at=COALESCE(VALUES(last_logout_at),last_logout_at),
       mysql_synced=TRUE, mysql_synced_at=CURRENT_TIMESTAMP(3), last_sync_error=NULL,
       updated_at=VALUES(updated_at)`,
    [
      String(user.id), email, displayName, phone, accountRole, provider,
      emailConfirmed, 'active', loginAt ? mysqlDate(loginAt) : null,
      logoutAt ? mysqlDate(logoutAt) : null,
      mysqlDate(user?.created_at), new Date(),
    ],
  )
}


function canonicalRecordType(value: string) {
  const aliases: Record<string, string> = {
    account_identity: 'account_identities',
    profile: 'profiles',
    home: 'homes',
    stakeholder: 'stakeholders',
    bfp_contact: 'emergency_contacts',
    safety_setup: 'safety_setups',
    preferences: 'user_preferences',
    appearance: 'user_preferences',
    device: 'devices',
    device_heartbeat: 'device_heartbeats',
    camera_telemetry: 'pyroguard_camera_telemetry',
    device_command: 'device_commands',
    ptz_command: 'ptz_commands',
    camera_event: 'camera_events',
    audio_session: 'audio_sessions',
    emergency_action_log: 'emergency_action_logs',
  }
  return aliases[value] ?? value
}

async function upsertTypedMirror(
  db: Connection,
  recordTypeRaw: string,
  recordKey: string,
  payloadRaw: unknown,
  user: any,
  mirrorUserId: string,
  mirrorDeviceId: unknown,
) {
  const recordType = canonicalRecordType(recordTypeRaw)
  const p = (payloadRaw && typeof payloadRaw === 'object')
    ? payloadRaw as Record<string, any>
    : <Record<string, any>>{}
  const uid = String(clean(p.user_id, mirrorUserId))
  const did = String(clean(p.device_id, mirrorDeviceId ?? p.target_device_id ?? 'ESP32-001'))
  const now = new Date()

  if (recordType === 'account_identities' && user) {
    await upsertAccountIdentity(db, user, p)
    return
  }
  if (recordType === 'profiles') {
    const role = String(clean(p.account_role, user?.app_metadata?.role ?? 'homeowner'))
    await db.execute(
      `INSERT INTO pyroguard_profiles
        (id,user_id,full_name,email,phone,account_role,account_status,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE user_id=VALUES(user_id),full_name=VALUES(full_name),
         email=VALUES(email),phone=VALUES(phone),account_role=VALUES(account_role),
         account_status=VALUES(account_status),updated_at=VALUES(updated_at)`,
      [uid,uid,clean(p.full_name,p.display_name),clean(p.email,user?.email),clean(p.phone,null),role,
       String(clean(p.account_status,'active')),mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'homes') {
    await db.execute(
      `INSERT INTO pyroguard_homes
        (user_id,home_name,address,barangay,city,latitude,longitude,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE home_name=VALUES(home_name),address=VALUES(address),
         barangay=VALUES(barangay),city=VALUES(city),latitude=VALUES(latitude),longitude=VALUES(longitude),
         updated_at=VALUES(updated_at)`,
      [uid,String(clean(p.home_name,'My Home')),clean(p.address,null),clean(p.barangay,null),clean(p.city,null),
       clean(p.latitude,null),clean(p.longitude,null),mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'stakeholders') {
    const primary = Boolean(clean(p.is_primary,true))
    const [existing] = await db.execute(
      'SELECT id FROM pyroguard_stakeholders WHERE user_id=? AND is_primary=? ORDER BY id LIMIT 1',
      [uid,primary],
    )
    const rows = Array.isArray(existing) ? existing as any[] : []
    if (rows.length > 0) {
      await db.execute(
        `UPDATE pyroguard_stakeholders SET full_name=?,relationship=?,phone=?,updated_at=? WHERE id=?`,
        [String(clean(p.full_name,'Stakeholder')),clean(p.relationship,null),clean(p.phone,null),mysqlDate(p.updated_at ?? now),rows[0].id],
      )
    } else {
      await db.execute(
        `INSERT INTO pyroguard_stakeholders
          (user_id,full_name,relationship,phone,is_primary,created_at,updated_at)
         VALUES (?,?,?,?,?,?,?)`,
        [uid,String(clean(p.full_name,'Stakeholder')),clean(p.relationship,null),clean(p.phone,null),primary,
         mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
      )
    }
    return
  }
  if (recordType === 'emergency_contacts') {
    const primary = Boolean(clean(p.is_primary,true))
    const [existing] = await db.execute(
      'SELECT id FROM pyroguard_emergency_contacts WHERE user_id=? AND is_primary=? ORDER BY id LIMIT 1',
      [uid,primary],
    )
    const rows = Array.isArray(existing) ? existing as any[] : []
    const values = [String(clean(p.contact_type,'BFP')),clean(p.name,p.station_name),clean(p.station_name,null),
      clean(p.personnel_name,null),clean(p.rank_position,null),clean(p.phone,null),clean(p.address,null),
      Boolean(clean(p.is_confirmed,p.confirmed ?? false)),mysqlDate(p.updated_at ?? now)]
    if (rows.length > 0) {
      await db.execute(
        `UPDATE pyroguard_emergency_contacts SET contact_type=?,name=?,station_name=?,personnel_name=?,
          rank_position=?,phone=?,address=?,is_confirmed=?,updated_at=? WHERE id=?`,
        [...values,rows[0].id],
      )
    } else {
      await db.execute(
        `INSERT INTO pyroguard_emergency_contacts
          (user_id,contact_type,name,station_name,personnel_name,rank_position,phone,address,is_primary,is_confirmed,created_at,updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
        [uid,...values.slice(0,7),primary,values[7],mysqlDate(p.created_at),values[8]],
      )
    }
    return
  }
  if (recordType === 'safety_setups') {
    await db.execute(
      `INSERT INTO pyroguard_safety_setups
        (user_id,safety_acknowledged,entry_delay_seconds,siren_duration_seconds,ai_assist_enabled,notes,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE safety_acknowledged=VALUES(safety_acknowledged),
        entry_delay_seconds=VALUES(entry_delay_seconds),siren_duration_seconds=VALUES(siren_duration_seconds),
        ai_assist_enabled=VALUES(ai_assist_enabled),notes=VALUES(notes),updated_at=VALUES(updated_at)`,
      [uid,Boolean(clean(p.safety_acknowledged,false)),Number(clean(p.entry_delay_seconds,30)),
       Number(clean(p.siren_duration_seconds,120)),Boolean(clean(p.ai_assist_enabled,true)),clean(p.notes,null),
       mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'user_preferences') {
    const [existing] = await db.execute(
      `SELECT notifications_enabled,push_notifications,email_alerts,sms_alerts,dark_mode
         FROM pyroguard_user_preferences WHERE user_id=? LIMIT 1`, [uid],
    )
    const current = Array.isArray(existing) && existing.length > 0 ? existing[0] as any : {}
    const value = (key: string, fallback: any) =>
      Object.prototype.hasOwnProperty.call(p, key) ? p[key] : (current[key] ?? fallback)
    await db.execute(
      `INSERT INTO pyroguard_user_preferences
        (user_id,notifications_enabled,push_notifications,email_alerts,sms_alerts,dark_mode,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE notifications_enabled=VALUES(notifications_enabled),
        push_notifications=VALUES(push_notifications),email_alerts=VALUES(email_alerts),
        sms_alerts=VALUES(sms_alerts),dark_mode=VALUES(dark_mode),updated_at=VALUES(updated_at)`,
      [uid,Boolean(value('notifications_enabled',true)),Boolean(value('push_notifications',true)),
       Boolean(value('email_alerts',true)),Boolean(value('sms_alerts',false)),Boolean(value('dark_mode',false)),
       mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'devices') {
    await db.execute(
      `INSERT INTO pyroguard_devices
        (user_id,device_id,device_name,device_type,status,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE user_id=VALUES(user_id),device_name=VALUES(device_name),
        device_type=VALUES(device_type),status=VALUES(status),updated_at=VALUES(updated_at)`,
      [uid,String(clean(p.device_id,recordKey)),String(clean(p.device_name,'Main PyroGuard Controller')),
       String(clean(p.device_type,'ESP32_MAIN')),String(clean(p.status,'registered')),mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'device_current_state') {
    await db.execute(
      `INSERT INTO pyroguard_device_current_state
        (device_id,temperature,humidity,smoke_raw,smoke_level,smoke_status,flame_detected,alert_status,incident_type,
         severity_level,location,device_lat,device_lng,door_status,window_status,motion_detected,system_armed,system_mode,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE temperature=VALUES(temperature),humidity=VALUES(humidity),smoke_raw=VALUES(smoke_raw),
        smoke_level=VALUES(smoke_level),smoke_status=VALUES(smoke_status),flame_detected=VALUES(flame_detected),
        alert_status=VALUES(alert_status),incident_type=VALUES(incident_type),severity_level=VALUES(severity_level),
        location=VALUES(location),device_lat=VALUES(device_lat),device_lng=VALUES(device_lng),door_status=VALUES(door_status),
        window_status=VALUES(window_status),motion_detected=VALUES(motion_detected),system_armed=VALUES(system_armed),
        system_mode=VALUES(system_mode),updated_at=VALUES(updated_at)`,
      [did,clean(p.temperature,null),clean(p.humidity,null),clean(p.smoke_raw ?? p.mq2_raw,null),clean(p.smoke_level,null),
       clean(p.smoke_status,null),nullableBoolean(p.flame_detected ?? p.flame_status),clean(p.alert_status,null),clean(p.incident_type,null),
       clean(p.severity_level,0),clean(p.location,null),clean(p.device_lat ?? p.latitude,null),clean(p.device_lng ?? p.longitude,null),
       clean(p.door_status,null),clean(p.window_status,null),clean(p.motion_detected,null),clean(p.system_armed,false),
       String(clean(p.system_mode ?? p.arm_mode,'DISARMED')),mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'device_heartbeats') {
    await db.execute(
      `INSERT INTO pyroguard_device_heartbeats
        (device_id,wifi_ok,supabase_ok,camera_ok,ptz_ok,mic_ok,speaker_ok,pir_ok,door_ok,window_ok,ultrasonic_ok,mq2_ok,flame_ok,dht22_ok,gps_ok,gsm_ok,siren_ok,uptime_secs,battery_pct,local_ip,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE wifi_ok=VALUES(wifi_ok),supabase_ok=VALUES(supabase_ok),camera_ok=VALUES(camera_ok),
        ptz_ok=VALUES(ptz_ok),mic_ok=VALUES(mic_ok),speaker_ok=VALUES(speaker_ok),pir_ok=VALUES(pir_ok),door_ok=VALUES(door_ok),
        window_ok=VALUES(window_ok),ultrasonic_ok=VALUES(ultrasonic_ok),mq2_ok=VALUES(mq2_ok),flame_ok=VALUES(flame_ok),
        dht22_ok=VALUES(dht22_ok),gps_ok=VALUES(gps_ok),gsm_ok=VALUES(gsm_ok),siren_ok=VALUES(siren_ok),
        uptime_secs=VALUES(uptime_secs),battery_pct=VALUES(battery_pct),local_ip=VALUES(local_ip),updated_at=VALUES(updated_at)`,
      [did,Boolean(clean(p.wifi_ok,false)),Boolean(clean(p.supabase_ok,false)),Boolean(clean(p.camera_ok,false)),Boolean(clean(p.ptz_ok,false)),
       Boolean(clean(p.mic_ok,false)),Boolean(clean(p.speaker_ok,false)),Boolean(clean(p.pir_ok,false)),Boolean(clean(p.door_ok,false)),
       Boolean(clean(p.window_ok,false)),Boolean(clean(p.ultrasonic_ok,false)),Boolean(clean(p.mq2_ok,false)),Boolean(clean(p.flame_ok,false)),
       Boolean(clean(p.dht22_ok,false)),Boolean(clean(p.gps_ok,false)),Boolean(clean(p.gsm_ok,false)),Boolean(clean(p.siren_ok,false)),
       clean(p.uptime_secs,null),clean(p.battery_pct,null),clean(p.local_ip,null),mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'pyroguard_camera_telemetry') {
    const cameraId = String(clean(p.camera_device_id,recordKey || 'pyroguard_camera_001'))
    await db.execute(
      `INSERT INTO pyroguard_pyroguard_camera_telemetry
        (device_id,camera_device_id,camera_ip,status,motion_detected,motion_pixels,pan_angle,tilt_angle,wifi_rssi,uptime_ms,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE device_id=VALUES(device_id),camera_ip=VALUES(camera_ip),status=VALUES(status),
        motion_detected=VALUES(motion_detected),motion_pixels=VALUES(motion_pixels),pan_angle=VALUES(pan_angle),
        tilt_angle=VALUES(tilt_angle),wifi_rssi=VALUES(wifi_rssi),uptime_ms=VALUES(uptime_ms),updated_at=VALUES(updated_at)`,
      [did,cameraId,clean(p.camera_ip,null),String(clean(p.status,'offline')),Boolean(clean(p.motion_detected,false)),
       Number(clean(p.motion_pixels,0)),Number(clean(p.pan_angle,90)),Number(clean(p.tilt_angle,90)),clean(p.wifi_rssi,null),clean(p.uptime_ms,null),
       mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'system_state') {
    await db.execute(
      `INSERT INTO pyroguard_system_state
        (user_id,device_id,arm_mode,door_enabled,window_enabled,motion_enabled,acting_user,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE user_id=VALUES(user_id),arm_mode=VALUES(arm_mode),door_enabled=VALUES(door_enabled),
        window_enabled=VALUES(window_enabled),motion_enabled=VALUES(motion_enabled),acting_user=VALUES(acting_user),updated_at=VALUES(updated_at)`,
      [uid,did,String(clean(p.arm_mode,'DISARMED')),Boolean(clean(p.door_enabled,true)),Boolean(clean(p.window_enabled,true)),
       Boolean(clean(p.motion_enabled,true)),clean(p.acting_user,uid),mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'device_commands') {
    const created = mysqlDate(p.created_at)
    const [existing] = await db.execute(
      `SELECT id FROM pyroguard_device_commands WHERE user_id=? AND target_device_id=? AND command=? AND created_at=? LIMIT 1`,
      [uid,String(clean(p.target_device_id,did)),String(clean(p.command,'UNKNOWN')),created],
    )
    if (!Array.isArray(existing) || existing.length === 0) {
      await db.execute(
        `INSERT INTO pyroguard_device_commands
          (user_id,target_device_id,command,payload,requested_by,status,result_message,created_at,applied_at)
         VALUES (?,?,?,?,?,?,?,?,?)`,
        [uid,String(clean(p.target_device_id,did)),String(clean(p.command,'UNKNOWN')),JSON.stringify(clean(p.payload,{})),
         clean(p.requested_by,uid),String(clean(p.status,'pending')),clean(p.result_message,null),created,
         p.applied_at ? mysqlDate(p.applied_at) : null],
      )
    }
    return
  }
  if (recordType === 'ptz_state') {
    const [existing] = await db.execute(
      `SELECT pan_position,tilt_position,moving,auto_tracking,pan_angle,tilt_angle
         FROM pyroguard_ptz_state WHERE device_id=? LIMIT 1`, [did],
    )
    const current = Array.isArray(existing) && existing.length > 0 ? existing[0] as any : {}
    const value = (key: string, fallback: any) =>
      Object.prototype.hasOwnProperty.call(p, key) ? p[key] : (current[key] ?? fallback)
    const panPos = Number(value('pan_position', value('pan_angle', 90)))
    const tiltPos = Number(value('tilt_position', value('tilt_angle', 90)))
    const panAngle = Number(value('pan_angle', panPos))
    const tiltAngle = Number(value('tilt_angle', tiltPos))
    await db.execute(
      `INSERT INTO pyroguard_ptz_state
        (device_id,pan_position,tilt_position,moving,auto_tracking,pan_angle,tilt_angle,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?)
       ON DUPLICATE KEY UPDATE pan_position=VALUES(pan_position),tilt_position=VALUES(tilt_position),moving=VALUES(moving),
        auto_tracking=VALUES(auto_tracking),pan_angle=VALUES(pan_angle),tilt_angle=VALUES(tilt_angle),updated_at=VALUES(updated_at)`,
      [did,panPos,tiltPos,Boolean(value('moving',false)),Boolean(value('auto_tracking',false)),panAngle,tiltAngle,
       mysqlDate(p.created_at),mysqlDate(p.updated_at ?? now)],
    )
    return
  }
  if (recordType === 'ptz_commands') {
    const created = mysqlDate(p.created_at)
    const [existing] = await db.execute(
      `SELECT id FROM pyroguard_ptz_commands WHERE device_id=? AND created_at=? AND COALESCE(command,'')=COALESCE(?, '') LIMIT 1`,
      [did,created,clean(p.command,null)],
    )
    if (!Array.isArray(existing) || existing.length === 0) {
      await db.execute(
        `INSERT INTO pyroguard_ptz_commands
          (user_id,device_id,pan,tilt,speed,mode,preset_name,command,value,status,created_at,applied_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
        [clean(p.user_id,uid),did,Number(clean(p.pan,0)),Number(clean(p.tilt,0)),Number(clean(p.speed,0)),String(clean(p.mode,'manual')),
         clean(p.preset_name,null),clean(p.command,null),clean(p.value,null),String(clean(p.status,'created')),created,
         p.applied_at ? mysqlDate(p.applied_at) : null],
      )
    }
    return
  }
  if (recordType === 'camera_events') {
    await db.execute(
      `INSERT INTO pyroguard_camera_events
        (user_id,device_id,record_key,event_type,snapshot_url,pan_at_capture,tilt_at_capture,payload_json,mysql_synced,mysql_synced_at,last_sync_error,created_at)
       VALUES (?,?,?,?,?,?,?,?,TRUE,CURRENT_TIMESTAMP(3),NULL,?)
       ON DUPLICATE KEY UPDATE user_id=VALUES(user_id),device_id=VALUES(device_id),event_type=VALUES(event_type),
        snapshot_url=VALUES(snapshot_url),pan_at_capture=VALUES(pan_at_capture),tilt_at_capture=VALUES(tilt_at_capture),
        payload_json=VALUES(payload_json),mysql_synced=TRUE,mysql_synced_at=CURRENT_TIMESTAMP(3),last_sync_error=NULL`,
      [clean(p.user_id,uid),did,String(clean(p.record_key,recordKey)),String(clean(p.event_type,'camera_event')),
       clean(p.snapshot_url,null),clean(p.pan_at_capture,null),clean(p.tilt_at_capture,null),JSON.stringify(clean(p.payload_json,p)),mysqlDate(p.created_at)],
    )
    return
  }
  if (recordType === 'audio_sessions') {
    await db.execute(
      `INSERT INTO pyroguard_audio_sessions
        (user_id,device_id,record_key,direction,clip_url,metadata_json,mysql_synced,mysql_synced_at,last_sync_error,created_at)
       VALUES (?,?,?,?,?,?,TRUE,CURRENT_TIMESTAMP(3),NULL,?)
       ON DUPLICATE KEY UPDATE user_id=VALUES(user_id),device_id=VALUES(device_id),direction=VALUES(direction),
        clip_url=VALUES(clip_url),metadata_json=VALUES(metadata_json),mysql_synced=TRUE,mysql_synced_at=CURRENT_TIMESTAMP(3),last_sync_error=NULL`,
      [clean(p.user_id,uid),did,String(clean(p.record_key,recordKey)),String(clean(p.direction,'from_device')),
       clean(p.clip_url,null),JSON.stringify(clean(p.metadata_json,p)),mysqlDate(p.created_at)],
    )
    return
  }
  if (recordType === 'emergency_action_logs') {
    await db.execute(
      `INSERT INTO pyroguard_emergency_action_logs
        (user_id,device_id,event_type,severity,message,bfp_station,bfp_personnel,bfp_phone,occurred_at,created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`,
      [clean(p.user_id,uid),clean(p.device_id,mirrorDeviceId),String(clean(p.event_type,'emergency_action')),
       clean(p.severity,null),clean(p.message,null),clean(p.bfp_station,null),clean(p.bfp_personnel,null),clean(p.bfp_phone,null),
       mysqlDate(p.occurred_at),mysqlDate(p.created_at ?? p.occurred_at)],
    )
    return
  }
  if (recordType === 'sensor_readings') {
    await db.execute(
      `INSERT INTO pyroguard_sensor_readings
        (device_id,temperature,humidity,smoke_raw,smoke_level,smoke_status,flame_detected,alert_status,incident_type,severity_level,
         location,device_lat,device_lng,door_status,window_status,motion_detected,system_armed,created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [did,clean(p.temperature,null),clean(p.humidity,null),clean(p.smoke_raw,null),clean(p.smoke_level,null),clean(p.smoke_status,null),
       nullableBoolean(p.flame_detected),clean(p.alert_status,null),clean(p.incident_type,null),clean(p.severity_level,0),clean(p.location,null),
       clean(p.device_lat,null),clean(p.device_lng,null),clean(p.door_status,null),clean(p.window_status,null),clean(p.motion_detected,null),
       clean(p.system_armed,false),mysqlDate(p.created_at)],
    )
  }
}

function historyWhere(userId: string, deviceId: string | null) {
  if (deviceId) {
    return {
      sql: '(user_id = ? OR (user_id IS NULL AND device_id = ?))',
      params: [userId, deviceId],
    }
  }
  return { sql: 'user_id = ?', params: [userId] }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)

  try {
    const body = await req.json() as Record<string, any>
    const action = String(body.action ?? '').trim()
    const { user, deviceAuthorized } = await authenticate(req)

    const readAction = action.startsWith('list_')
    if (readAction && !user) {
      return json({ ok: false, error: 'Authentication required.' }, 401)
    }
    if (!readAction && !user && !deviceAuthorized) {
      return json({ ok: false, error: 'User or device authentication required.' }, 401)
    }

    if(localMode()) {
      // The app already persists its source row and outbox in Supabase.
      // Never claim a local MySQL write succeeded from this hosted function.
      if(action==='health') {
        if(!user)return json({ok:false,error:'Authentication required.'},401)
        const sb=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}})
        const local=await localStatus(sb)
        return json({ok:local.health.mysql===true,edge_function:true,...local.health})
      }
      if(action.startsWith('write_'))return json({ok:false,pending:true,mode:'local-pc',error:'Saved source records await the worker on the MySQL PC.'},202)
      return json({ok:false,mode:'local-pc',error:'Local MySQL history is mirrored on your PC; use Supabase history in the app.'},503)
    }

    const deviceId = requestedDevice(body, user)
    const ownerUserId = userIdForWrite(user, deviceAuthorized)

    // Authenticated connectivity probe used by the Admin Console. This proves
    // the Edge Function can reach the configured MySQL server and execute a
    // query; it does not expose credentials or private data.
    if (action === 'health') {
      if (!user) return json({ ok: false, error: 'Authentication required.' }, 401)
      const missing = missingMysqlSecrets()
      if (missing.length) return json({ ok: false, edge_function: true,
        mysql: { reachable: false, configured: false },
        error_code: 'MYSQL_CONFIGURATION', missing_secrets: missing,
        error: `Missing MySQL server secrets: ${missing.join(', ')}`,
        resolution: 'Add the missing names and their real database values in Supabase Dashboard → Edge Functions → Secrets, then refresh.' })
      try {
      const mysql = await withDb(async (db) => {
        const [rows] = await db.execute('SELECT 1 AS ok, UTC_TIMESTAMP(3) AS server_time')
        const first = Array.isArray(rows) && rows.length > 0 ? (rows[0] as any) : { ok: 1 }
        const [countRows] = await db.execute(
          `SELECT COUNT(*) AS table_count FROM information_schema.tables
            WHERE table_schema = DATABASE() AND table_name IN (
              'pyroguard_admin_accounts','pyroguard_profiles','pyroguard_account_identities',
              'pyroguard_homes','pyroguard_stakeholders','pyroguard_emergency_contacts',
              'pyroguard_safety_setups','pyroguard_user_preferences','pyroguard_devices',
              'pyroguard_device_current_state','pyroguard_device_heartbeats',
              'pyroguard_pyroguard_camera_telemetry','pyroguard_system_state',
              'pyroguard_device_commands','pyroguard_ptz_state','pyroguard_ptz_commands',
              'pyroguard_sensor_history','pyroguard_event_history','pyroguard_camera_history',
              'pyroguard_camera_events','pyroguard_audio_sessions','pyroguard_mirror_records',
              'pyroguard_dual_record_ledger','pyroguard_emergency_action_logs','pyroguard_sensor_readings'
            )`,
        )
        const countFirst = Array.isArray(countRows) && countRows.length > 0 ? (countRows[0] as any) : { table_count: 0 }
        const tableCount = Number(countFirst.table_count ?? 0)
        return {
          reachable: Number(first.ok ?? 0) === 1,
          server_time: first.server_time ?? null,
          mirrored_table_count: tableCount,
          expected_table_count: 25,
          schema_parity: tableCount === 25,
        }
      })
      return json({ ok: true, mysql: { ...mysql, configured: true }, edge_function: true })
      } catch (error) {
        console.error('mysql-history health:', error)
        return json({ ok: false, edge_function: true,
          mysql: { reachable: false, configured: true }, ...mysqlFailure(error) })
      }
    }

    if (action === 'list_sensor') {
      const limit = clampLimit(body.limit, 300, 1000)
      const where = historyWhere(String(user.id), deviceId)
      const rows = await withDb(async (db) => {
        const [result] = await db.execute(
          `SELECT id, device_id, temperature, humidity, smoke_raw, smoke_level,
                  smoke_status, flame_detected, door_status, window_status,
                  motion_detected, system_armed, system_mode, incident_type, severity_level,
                  alert_status, location, device_lat, device_lng, created_at
             FROM pyroguard_sensor_history
            WHERE ${where.sql}
            ORDER BY created_at DESC
            LIMIT ${limit}`,
          where.params,
        )
        return result
      })
      return json({ ok: true, data: rows })
    }

    if (action === 'list_incident') {
      const limit = clampLimit(body.limit, 100, 500)
      const where = historyWhere(String(user.id), deviceId)
      const rows = await withDb(async (db) => {
        const [result] = await db.execute(
          `SELECT id, device_id, event_type, sensor_name, location, event_status, image_url, acting_user_name, message, severity, payload_json,
                  created_at
             FROM pyroguard_event_history
            WHERE ${where.sql}
            ORDER BY created_at DESC
            LIMIT ${limit}`,
          where.params,
        )
        return result
      })
      return json({ ok: true, data: rows })
    }

    if (action === 'list_camera') {
      const limit = clampLimit(body.limit, 100, 500)
      const where = historyWhere(String(user.id), deviceId)
      const rows = await withDb(async (db) => {
        const [result] = await db.execute(
          `SELECT id, device_id, event_type, image_url, metadata_json, created_at
             FROM pyroguard_camera_history
            WHERE ${where.sql}
            ORDER BY created_at DESC
            LIMIT ${limit}`,
          where.params,
        )
        return result
      })
      return json({ ok: true, data: rows })
    }

    if (action === 'write_sensor') {
      const r = body.record ?? body
      const recordDevice = String(clean(r.device_id, deviceId ?? 'pyroguard_sensor'))
      const recordId = await withTransaction(async (db) => {
        await db.execute(
          `INSERT INTO pyroguard_sensor_history
            (user_id, device_id, temperature, humidity, smoke_raw, smoke_level,
             smoke_status, flame_detected, door_status, window_status,
             motion_detected, system_armed, system_mode, incident_type, severity_level,
             alert_status, location, device_lat, device_lng, payload_json, mysql_synced, mysql_synced_at, last_sync_error, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, TRUE, CURRENT_TIMESTAMP(3), NULL, ?)`,
          [
            ownerUserId, recordDevice,
            clean(r.temperature, null), clean(r.humidity, null), clean(r.smoke_raw ?? r.mq2_raw, null),
            clean(r.smoke_level, null), clean(r.smoke_status, null), nullableBoolean(r.flame_detected ?? r.flame_status),
            clean(r.door_status, 'UNKNOWN'), clean(r.window_status, 'UNKNOWN'), clean(r.motion_detected, null),
            clean(r.system_armed, null), clean(r.system_mode ?? r.arm_mode, null), clean(r.incident_type, null), clean(r.severity_level, null),
            clean(r.alert_status, null), clean(r.location, null), clean(r.device_lat ?? r.latitude, null),
            clean(r.device_lng ?? r.longitude, null), JSON.stringify(r), mysqlDate(r.created_at ?? r.recorded_at),
          ],
        )
        return await writeDualLedger(db, body, {
          userId: ownerUserId, deviceId: recordDevice,
          recordType: 'sensor_history', recordKey: String(clean(r.created_at ?? r.recorded_at, Date.now())),
          operation: 'INSERT', source: deviceAuthorized && !user ? 'firmware' : 'flutter', payload: r,
        })
      })
      return json({ ok: true, record_id: recordId })
    }

    if (action === 'write_incident') {
      const r = body.record ?? body
      const recordDevice = String(clean(r.device_id, deviceId ?? 'pyroguard_sensor'))
      const recordId = await withTransaction(async (db) => {
        await db.execute(
          `INSERT INTO pyroguard_event_history
            (user_id, device_id, event_type, sensor_name, location, event_status, image_url, acting_user_name, message, severity, payload_json, mysql_synced, mysql_synced_at, last_sync_error, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, TRUE, CURRENT_TIMESTAMP(3), NULL, ?)`,
          [
            ownerUserId, recordDevice, clean(r.event_type ?? r.incident_type, 'event'),
            clean(r.sensor_name ?? r.sensor, null), clean(r.location, null), clean(r.status ?? r.event_status, null),
            clean(r.image_url ?? r.photo_url ?? r.snapshot_url, null), clean(r.user_name ?? r.acting_user_name, null),
            clean(r.message, null), clean(r.severity ?? r.severity_level, 0),
            JSON.stringify(r), mysqlDate(r.created_at ?? r.occurred_at),
          ],
        )
        return await writeDualLedger(db, body, {
          userId: ownerUserId, deviceId: recordDevice,
          recordType: 'event_history', recordKey: String(clean(r.created_at ?? r.occurred_at, Date.now())),
          operation: 'INSERT', source: deviceAuthorized && !user ? 'firmware' : 'flutter', payload: r,
        })
      })
      return json({ ok: true, record_id: recordId })
    }

    if (action === 'write_camera') {
      const r = body.record ?? body
      const recordDevice = String(clean(r.device_id, deviceId ?? 'pyroguard_camera_001'))
      const recordId = await withTransaction(async (db) => {
        await db.execute(
          `INSERT INTO pyroguard_camera_history
            (user_id, device_id, event_type, image_url, metadata_json, mysql_synced, mysql_synced_at, last_sync_error, created_at)
           VALUES (?, ?, ?, ?, ?, TRUE, CURRENT_TIMESTAMP(3), NULL, ?)`,
          [
            ownerUserId, recordDevice, clean(r.event_type, 'camera_event'),
            clean(r.image_url ?? r.snapshot_url ?? r.photo_url ?? r.url, null), JSON.stringify(r),
            mysqlDate(r.created_at),
          ],
        )
        return await writeDualLedger(db, body, {
          userId: ownerUserId, deviceId: recordDevice,
          recordType: 'camera_history', recordKey: String(clean(r.created_at, Date.now())),
          operation: 'INSERT', source: deviceAuthorized && !user ? 'firmware' : 'flutter', payload: r,
        })
      })
      return json({ ok: true, record_id: recordId })
    }


    if (action === 'write_mirror') {
      const r = body.record ?? body
      const recordType = String(clean(r.record_type, 'unknown'))
      const recordKey = String(clean(r.record_key, 'default'))
      const mirrorUserId = String(clean(r.user_id, ownerUserId ?? 'DEVICE'))
      const mirrorDeviceId = clean(r.device_id, deviceId)
      const payload = clean(r.payload, r.payload_json ?? r)
      const recordId = await withTransaction(async (db) => {
        await upsertTypedMirror(db, recordType, recordKey, payload, user, mirrorUserId, mirrorDeviceId)
        if (user && ['user_session','admin_session'].includes(recordType)) {
          await upsertAccountIdentity(db, user, payload as Record<string, any>)
        }
        if (false && recordType === 'camera_event') {
          const p = payload as Record<string, any>
          await db.execute(
            `INSERT INTO pyroguard_camera_events
              (user_id,device_id,record_key,event_type,snapshot_url,pan_at_capture,tilt_at_capture,payload_json,mysql_synced,mysql_synced_at,last_sync_error,created_at)
             VALUES (?,?,?,?,?,?,?,?,TRUE,CURRENT_TIMESTAMP(3),NULL,?)
             ON DUPLICATE KEY UPDATE
               user_id=VALUES(user_id), device_id=VALUES(device_id), event_type=VALUES(event_type),
               snapshot_url=VALUES(snapshot_url), pan_at_capture=VALUES(pan_at_capture),
               tilt_at_capture=VALUES(tilt_at_capture), payload_json=VALUES(payload_json), mysql_synced=TRUE, mysql_synced_at=CURRENT_TIMESTAMP(3), last_sync_error=NULL`,
            [
              mirrorUserId, String(clean(p.device_id, mirrorDeviceId ?? 'ESP32-001')), recordKey,
              String(clean(p.event_type, 'camera_event')), clean(p.snapshot_url, null),
              clean(p.pan_at_capture, null), clean(p.tilt_at_capture, null),
              JSON.stringify(p), mysqlDate(p.created_at),
            ],
          )
        }
        if (false && recordType === 'audio_session') {
          const p = payload as Record<string, any>
          await db.execute(
            `INSERT INTO pyroguard_audio_sessions
              (user_id,device_id,record_key,direction,clip_url,metadata_json,mysql_synced,mysql_synced_at,last_sync_error,created_at)
             VALUES (?,?,?,?,?,?,TRUE,CURRENT_TIMESTAMP(3),NULL,?)
             ON DUPLICATE KEY UPDATE
               user_id=VALUES(user_id), device_id=VALUES(device_id), direction=VALUES(direction),
               clip_url=VALUES(clip_url), metadata_json=VALUES(metadata_json),
               mysql_synced=TRUE, mysql_synced_at=CURRENT_TIMESTAMP(3), last_sync_error=NULL`,
            [
              mirrorUserId, String(clean(p.device_id, mirrorDeviceId ?? 'ESP32-001')), recordKey,
              String(clean(p.direction, 'from_device')), clean(p.clip_url, null),
              JSON.stringify(p), mysqlDate(p.created_at),
            ],
          )
        }
        await db.execute(
          `INSERT INTO pyroguard_mirror_records
            (user_id, device_id, record_type, record_key, payload, mysql_synced, mysql_synced_at, last_sync_error, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, TRUE, CURRENT_TIMESTAMP(3), NULL, ?, ?)
           ON DUPLICATE KEY UPDATE
             device_id=VALUES(device_id), payload=VALUES(payload),
             mysql_synced=TRUE, mysql_synced_at=CURRENT_TIMESTAMP(3), last_sync_error=NULL,
             updated_at=VALUES(updated_at)`,
          [
            mirrorUserId, mirrorDeviceId, recordType, recordKey, JSON.stringify(payload),
            mysqlDate(r.created_at), mysqlDate(r.updated_at ?? r.created_at),
          ],
        )
        return await writeDualLedger(db, body, {
          userId: mirrorUserId, deviceId: mirrorDeviceId == null ? null : String(mirrorDeviceId),
          recordType, recordKey,
          operation: String(clean(body.dual_record?.operation, 'UPSERT')),
          source: deviceAuthorized && !user ? 'firmware' : 'flutter', payload,
        })
      })
      return json({ ok: true, record_id: recordId })
    }

    if (action === 'write_ledger') {
      const r = body.record ?? body
      const recordId = await withTransaction(async (db) => {
        return await writeDualLedger(db, { dual_record: r }, {
          userId: ownerUserId,
          deviceId,
          recordType: String(clean(r.record_type, 'unknown')),
          recordKey: String(clean(r.record_key, 'default')),
          operation: String(clean(r.operation, 'ACTION')),
          source: String(clean(r.source, 'retry')),
          payload: clean(r.payload, r),
        })
      })
      return json({ ok: true, record_id: recordId })
    }

    return json({ ok: false, error: `Unknown action: ${action}` }, 400)
  } catch (error) {
    console.error('mysql-history:', error)
    return json({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }, 500)
  }
})
