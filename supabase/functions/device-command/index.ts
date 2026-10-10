import { createClient } from '@supabase/supabase-js'
import { localMode } from '../_shared/local_sync.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, x-device-key',
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

function authorized(req: Request) {
  const expected = env('PYROGUARD_DEVICE_KEY')
  const supplied = req.headers.get('x-device-key')?.trim() ?? ''
  return supplied.length > 0 && supplied === expected
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)

  try {
    if (!authorized(req)) return json({ ok: false, error: 'Invalid device key.' }, 401)

    const body = await req.json() as Record<string, any>
    const action = String(body.action ?? 'sync')
    const deviceId = String(body.device_id ?? '').trim()
    if (!deviceId) return json({ ok: false, error: 'device_id is required.' }, 400)

    const supabase = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'))

    if (action === 'sync') {
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

      return json({ ok: true, state, commands: commands ?? [] })
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
      if (localMode())return json({ok:true,mysql_synced:false,mysql_pending:true})
      if (updated) {
        try {
          await mirrorToMysql('device_commands', String(commandId), deviceId, updated)
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
