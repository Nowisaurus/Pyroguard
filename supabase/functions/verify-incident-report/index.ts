// PyroGuard verify-incident-report (2026-11-23, v17)
// ---------------------------------------------------------------------------
// Public check used by the BFP: is this PyroGuard incident report real?
// The PDF shows a report number + verification code (and a QR code that opens
// https://pyroguard-chi.vercel.app/verify.html?r=<report>&c=<code>, which calls this).
// GET ?r=<report number>&c=<16-character code>  ->  JSON
// Compares the registered report with what is stored on the server now:
//   - the number of sensor readings for that controller/room/time window
//   - the camera photos listed in the report
// Shows no names, phone numbers or street addresses.
// Deploy with verify_jwt = false (it is a public page).
// ---------------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}
const env = (n: string) => Deno.env.get(n)?.trim() ?? ''
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } })

const TYPE_LABEL: Record<string, string> = {
  FIRE: 'Confirmed fire (flame + smoke)', SMOKE: 'Smoke / gas detected', FLAME: 'Flame detected',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const url = new URL(req.url)
    let r = url.searchParams.get('r') ?? '', c = url.searchParams.get('c') ?? ''
    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({})) as Record<string, unknown>
      r = String(body.r ?? r); c = String(body.c ?? c)
    }
    r = r.trim(); c = c.replace(/[^0-9A-Fa-f]/g, '').toUpperCase()
    if (!/^[A-Za-z0-9_-]{6,60}$/.test(r) || !/^[0-9A-F]{16}$/.test(c)) {
      return json({ ok: false, error: 'Enter the report number and the 16-character verification code from the PDF.' }, 400)
    }
    const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'),
      { auth: { persistSession: false, autoRefreshToken: false } })

    const { data: rep, error } = await db.from('pyroguard_incident_reports')
      .select('report_number,controller_id,room_key,incident_type,first_detected,last_detected,reading_count,photo_urls,data_sha256,verify_code,area_label,generated_at')
      .eq('report_number', r).eq('verify_code', c).order('generated_at', { ascending: false }).limit(1).maybeSingle()
    if (error) throw error
    if (!rep) return json({ ok: true, found: false })

    const { count: readingsNow } = await db.from('pyroguard_room_sensor_readings')
      .select('id', { count: 'exact', head: true })
      .eq('controller_device_id', rep.controller_id).eq('room_key', rep.room_key)
      .or('fire_confirmed.eq.true,smoke_status.eq.ALARM,flame_detected.eq.true')
      .gte('received_at', rep.first_detected).lte('received_at', rep.last_detected)

    const photos: string[] = Array.isArray(rep.photo_urls) ? rep.photo_urls.map(String) : []
    let photosFound = 0
    if (photos.length) {
      const { count } = await db.from('camera_events').select('id', { count: 'exact', head: true }).in('snapshot_url', photos)
      photosFound = count ?? 0
    }
    const readingsMatch = (readingsNow ?? 0) === rep.reading_count
    const photosMatch = photosFound >= photos.length
    return json({
      ok: true,
      found: true,
      valid: readingsMatch && photosMatch,
      report: {
        report_number: rep.report_number,
        incident: TYPE_LABEL[rep.incident_type] ?? rep.incident_type,
        area: rep.area_label ?? rep.room_key,
        controller: rep.controller_id,
        first_detected: rep.first_detected,
        last_detected: rep.last_detected,
        generated_at: rep.generated_at,
        reading_count: rep.reading_count,
        fingerprint: rep.data_sha256,
        photos,
      },
      server: { reading_count: readingsNow ?? 0, readings_match: readingsMatch, photos_found: photosFound, photos_match: photosMatch },
    })
  } catch (e) {
    console.error('verify-incident-report:', e)
    return json({ ok: false, error: 'Verification service error. Try again later.' }, 500)
  }
})
