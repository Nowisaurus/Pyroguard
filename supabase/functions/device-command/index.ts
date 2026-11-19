import { createClient } from '@supabase/supabase-js'
import { localMode } from '../_shared/local_sync.ts'
import { deviceAuthorized } from '../_shared/device_auth.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, x-device-key, x-device-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function env(name: string) {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`Missing Edge Function secret: ${name}`)
  return value
}


async function mirrorToMysql(recordType: string, recordKey: string, deviceId: string, payload: unknown) {
  const base = env('SUPABASE_URL').replace(/\/$/, '')
  const anonKey = env('SUPABASE_ANON_KEY')
  const deviceKey = env('PYROGUARD_DEVICE_KEY')
  const response = await fetch(`${base}/functions/v1/mysql-history`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'apikey': anonKey,
      'Authorization': `Bearer ${anonKey}`,
      'x-device-key': deviceKey,
    },
    body: JSON.stringify({
      action: 'write_mirror',
      device_id: deviceId,
      record: {
        record_type: recordType,
        record_key: recordKey,
        device_id: deviceId,
        payload,
        updated_at: new Date().toISOString(),
      },
    }),
  })
  if (!response.ok) throw new Error(`MySQL mirror HTTP ${response.status}: ${await response.text()}`)
}

// 2026-11-19: per-device keys are accepted (DEVICE_KEY_ESP32_001, DEVICE_KEY_ESP32_002,
// or their DEVICE_KEY_SHA256_* hashes) in addition to the shared PYROGUARD_DEVICE_KEY,
// so ESP32-002 no longer has to reuse ESP32-001's key.
const LEGACY_HASH: Record<string, string[]> = {
  'ESP32-001': ['SENSOR_DEVICE_KEY_SHA256'],
  'ESP32-002': ['SENSOR_DEVICE_KEY_SHA256_ESP32_002'],
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)

  try {
    const body = await req.json() as Record<string, any>
    const action = String(body.action ?? 'sync')
    const deviceId = String(body.device_id ?? req.headers.get('x-device-id') ?? '').trim()
    if (!deviceId) return json({ ok: false, error: 'device_id is required.' }, 400)
    if (!(await deviceAuthorized(req, deviceId, LEGACY_HASH[deviceId] ?? []))) {
      return json({ ok: false, error: 'Invalid device key.' }, 401)
    }

    const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'))

    const {data: registered, error: registryError} = await supabase.from('devices')
      .select('device_id,user_id').eq('device_id',deviceId).maybeSingle()
    if(registryError)throw registryError
    if(!registered)return json({ok:false,error:'Register this actual device before connecting firmware'},404)

    if(action==='telemetry' || action==='record_event') {
      const table=action==='record_event'?'event_history':String(body.table??'')
      const allowed: Record<string,string[]>={
        device_current_state:['temperature','humidity','smoke_raw','smoke_level','smoke_status','flame_detected','alert_status','incident_type','severity_level','device_lat','device_lng','door_status','window_status','motion_detected','system_armed','system_mode','siren_active'],
        sensor_history:['temperature','humidity','smoke_raw','smoke_level','smoke_status','flame_detected','alert_status','incident_type','severity_level','device_lat','device_lng','door_status','window_status','motion_detected','system_armed','system_mode','siren_active'],
        device_heartbeats:['wifi_ok','supabase_ok','camera_ok','ptz_ok','mic_ok','speaker_ok','pir_ok','door_ok','window_ok','ultrasonic_ok','mq2_ok','flame_ok','dht22_ok','gps_ok','gsm_ok','siren_ok','uptime_secs','battery_pct','local_ip'],
        pyroguard_camera_telemetry:['camera_device_id','camera_ip','status','motion_detected','motion_pixels','pan_angle','tilt_angle','wifi_rssi','uptime_ms'],
        event_history:['event_type','message','severity','payload_json','record_key'],
      }
      if(!allowed[table] || !body.record || typeof body.record!=='object' || Array.isArray(body.record))return json({ok:false,error:'Supported table and record required'},400)
      const record: Record<string,unknown>={device_id:deviceId}
      for(const field of allowed[table]) if(Object.hasOwn(body.record,field))record[field]=body.record[field]
      if(table==='event_history') {
        if(!['WARNING','CRITICAL_FIRE','MOTION','DOOR_OPEN','DOOR_CLOSED','WINDOW_OPEN','WINDOW_CLOSED','ARMED','DISARMED','SIREN_ON','SIREN_OFF','INTRUSION','SENSOR_FAULT'].includes(String(record.event_type)) || typeof record.record_key!=='string' || !record.record_key.startsWith(deviceId+':') || record.record_key.length>200 || typeof record.message!=='string' || record.message.length>1000 || !Number.isInteger(record.severity) || Number(record.severity)<0 || Number(record.severity)>2)return json({ok:false,error:'Valid incident type, severity, message and device record key required'},400)
      }
      if(table==='pyroguard_camera_telemetry'){
        if(typeof record.camera_device_id!=='string'||!record.camera_device_id.trim()||record.camera_device_id.length>100)return json({ok:false,error:'Camera ID required'},400)
        const {data:existing,error:cameraError}=await supabase.from(table).select('device_id').eq('camera_device_id',record.camera_device_id).maybeSingle()
        if(cameraError)throw cameraError
        if(existing && existing.device_id!==deviceId)return json({ok:false,error:'Camera belongs to another controller'},409)
      }
      const history=table==='event_history'||table==='sensor_history'
      if(history){if(!registered.user_id)return json({ok:false,error:'Device needs its actual owner'},409);record.user_id=registered.user_id;record.mysql_synced=false;record.created_at=new Date().toISOString()}
      else record.updated_at=new Date().toISOString()
      const query=table==='event_history'?supabase.from(table).upsert(record,{onConflict:'record_key',ignoreDuplicates:true}):history?supabase.from(table).insert(record):supabase.from(table).upsert(record,{onConflict:table==='pyroguard_camera_telemetry'?'camera_device_id':'device_id'})
      const {error}=await query
      if(error)throw error
      return json({ok:true,saved:true,mysql_pending:localMode()})
    }
    if(action==='ptz_sync') {
      const {data:state,error:stateError}=await supabase.from('ptz_state').select('auto_tracking').eq('device_id',deviceId).maybeSingle()
      if(stateError)throw stateError
      const {data:commands,error}=await supabase.from('ptz_commands').select('id,mode,pan,tilt,speed,preset_name')
        .eq('device_id',deviceId).eq('status','created').order('created_at',{ascending:true}).limit(1)
      if(error)throw error
      return json({ok:true,state,commands:commands??[]})
    }
    if(action==='ptz_state') {
      const pan=Number(body.pan_position),tilt=Number(body.tilt_position)
      if(!Number.isFinite(pan)||!Number.isFinite(tilt)||pan<0||pan>180||tilt<0||tilt>180||typeof body.moving!=='boolean')return json({ok:false,error:'Valid servo angles and moving boolean required'},400)
      const now=new Date().toISOString()
      // auto_tracking is reported by ESP32-001 (v9+): the controller is the
      // source of truth for whether auto-follow is ON. Older firmware omits it.
      const row:Record<string,unknown>={device_id:deviceId,pan_position:pan,tilt_position:tilt,
        pan_angle:Math.round(pan),tilt_angle:Math.round(tilt),moving:body.moving,last_device_at:now,updated_at:now}
      if(typeof body.auto_tracking==='boolean')row.auto_tracking=body.auto_tracking
      const {error}=await supabase.from('ptz_state').upsert(row,{onConflict:'device_id'})
      if(error)throw error
      return json({ok:true,mysql_pending:localMode()})
    }
    if(action==='ptz_ack') {
      const id=Number(body.command_id),status=String(body.status)
      if(!Number.isSafeInteger(id)||id<=0||!['executed','failed'].includes(status))return json({ok:false,error:'Positive command ID and explicit PTZ status required'},400)
      const {data,error}=await supabase.from('ptz_commands').update({status,applied_at:new Date().toISOString()})
        .eq('id',id).eq('device_id',deviceId).eq('status','created').select('id').maybeSingle()
      if(error)throw error
      if(!data)return json({ok:false,error:'Pending PTZ command not found for this device'},409)
      return json({ok:true,mysql_pending:localMode()})
    }

    if (action === 'sync') {
      // ARM / DISARM from the app: the app queues a security command in
      // device_commands. Apply the newest pending one to system_state here, so
      // the state returned below already carries the requested arm_mode. The
      // controller applies it, then acknowledges each command (action "ack").
      const securityCommands = ['SET_SECURITY_MODE', 'ARM_DOOR', 'DISARM_DOOR', 'ARM_WINDOW',
        'DISARM_WINDOW', 'ENABLE_MOTION', 'DISABLE_MOTION']
      const { data: pendingSecurity, error: pendingError } = await supabase
        .from('device_commands')
        .select('id,command,payload,requested_by,created_at')
        .eq('target_device_id', deviceId)
        .eq('status', 'pending')
        .in('command', securityCommands)
        .order('created_at', { ascending: false })
        .order('id', { ascending: false })
        .limit(1)
      if (pendingError) throw pendingError
      const latest = pendingSecurity?.[0]
      if (latest) {
        const p = (latest.payload && typeof latest.payload === 'object' ? latest.payload : {}) as Record<string, unknown>
        const { data: current, error: currentError } = await supabase.from('system_state')
          .select('arm_mode,door_enabled,window_enabled,motion_enabled').eq('device_id', deviceId).maybeSingle()
        if (currentError) throw currentError
        const mode = String(p.arm_mode ?? current?.arm_mode ?? 'DISARMED').toUpperCase()
        const flag = (value: unknown, fallback: unknown) =>
          typeof value === 'boolean' ? value : typeof fallback === 'boolean' ? fallback : true
        if (['DISARMED', 'ARM_HOME', 'ARM_AWAY'].includes(mode) && registered.user_id) {
          const { error: applyError } = await supabase.from('system_state').upsert({
            user_id: registered.user_id,
            device_id: deviceId,
            arm_mode: mode,
            door_enabled: flag(p.door_enabled, current?.door_enabled),
            window_enabled: flag(p.window_enabled, current?.window_enabled),
            motion_enabled: flag(p.motion_enabled, current?.motion_enabled),
            acting_user: latest.requested_by ?? null,
            updated_at: new Date().toISOString(),
          }, { onConflict: 'device_id' })
          if (applyError) throw applyError
        }
      }

      const { data: state, error: stateError } = await supabase
        .from('system_state')
        .select('arm_mode,door_enabled,window_enabled,motion_enabled,updated_at')
        .eq('device_id', deviceId)
        .maybeSingle()
      if (stateError) throw stateError

      const { data: commands, error: commandError } = await supabase
        .from('device_commands')
        .select('id,command,payload,created_at')
        .eq('target_device_id', deviceId)
        .eq('status', 'pending')
        .order('created_at', { ascending: true })
        .limit(10)
      if (commandError) throw commandError

      // Alarm timing chosen by the homeowner in the app (Safety setup).
      // The controller uses these for its entry/exit delay and bell duration.
      let safety: Record<string, unknown> | null = null
      if (registered.user_id) {
        const { data: setup, error: safetyError } = await supabase
          .from('safety_setups')
          .select('entry_delay_seconds,siren_duration_seconds')
          .eq('user_id', registered.user_id)
          .maybeSingle()
        if (safetyError) console.error('device-command safety settings:', safetyError)
        else safety = setup
      }

      return json({ ok: true, state, safety, commands: commands ?? [] })
    }

    if (action === 'ack') {
      const commandId = Number(body.command_id)
      if (!Number.isFinite(commandId)) return json({ ok: false, error: 'command_id is required.' }, 400)
      if(!Number.isSafeInteger(commandId) || commandId<=0 || !['applied','failed'].includes(String(body.status)))return json({ok:false,error:'Explicit applied/failed status and positive integer command_id required'},400)
      const status = String(body.status)
      const appliedAt = new Date().toISOString()
      const { data: updated, error } = await supabase
        .from('device_commands')
        .update({
          status,
          result_message: body.message == null ? null : String(body.message),
          applied_at: appliedAt,
        })
        .eq('id', commandId)
        .eq('target_device_id', deviceId)
        .eq('status', 'pending')
        .select('id,target_device_id,command,payload,status,result_message,requested_by,created_at,applied_at')
        .maybeSingle()
      if (error) throw error
      if (!updated)return json({ok:false,error:'Pending command not found for this device'},409)

      // Only the authenticated device can acknowledge an actual physical
      // command. Persist desired mode as observed/applied only after ACK.
      // If ACK failed, leave the last verified security state unchanged.
      let appliedState: Record<string, unknown> | null = null
      if (status === 'applied') {
        const p = updated.payload as Record<string, unknown> | null
        if (p && typeof p === 'object' && !Array.isArray(p) &&
            ['SET_SECURITY_MODE','ARM_DOOR','DISARM_DOOR','ARM_WINDOW',
             'DISARM_WINDOW','ENABLE_MOTION','DISABLE_MOTION'].includes(String(updated.command))) {
          appliedState = {device_id: deviceId, user_id: registered.user_id,
            acting_user: updated.requested_by, updated_at: appliedAt}
          if (['DISARMED','ARM_HOME','ARM_AWAY'].includes(String(p.arm_mode)))
            appliedState.arm_mode = p.arm_mode
          for (const key of ['door_enabled','window_enabled','motion_enabled'])
            if (typeof p[key] === 'boolean') appliedState[key] = p[key]
          const { error: stateError } = await supabase.from('system_state')
            .upsert(appliedState, { onConflict: 'device_id' })
          if (stateError) {
            console.error('Hardware command ACK saved but system_state update failed', stateError)
            return json({ok:false, acknowledged:true, state_synced:false,
              error:'Hardware acknowledged; system state write failed. Reconcile before issuing another command.'},500)
          }
        }
      }
      if (localMode())return json({ok:true,acknowledged:true,state_synced:status === 'applied' ? appliedState !== null : true,mysql_synced:false,mysql_pending:true})
      if (updated) {
        try {
          await mirrorToMysql('device_commands', String(commandId), deviceId, updated)
          if (appliedState) await mirrorToMysql('system_state', deviceId, deviceId, appliedState)
        } catch (mirrorError) {
          // Supabase has already retained the acknowledgement. Return the mirror
          // warning so firmware/admin can retry rather than pretending both wrote.
          return json({ ok: true, mysql_synced: false, warning: String(mirrorError) })
        }
      }
      return json({ ok: true, mysql_synced: true })
    }

    return json({ ok: false, error: `Unknown action: ${action}` }, 400)
  } catch (error) {
    console.error('device-command:', error)
    return json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500)
  }
})
