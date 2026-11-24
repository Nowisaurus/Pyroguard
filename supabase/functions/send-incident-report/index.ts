// PyroGuard send-incident-report (2026-11-23, v17)
// ---------------------------------------------------------------------------
// E-mails the incident report PDF made in the app to the homeowner's saved BFP
// station e-mail (Settings > BFP Contact Details), with a copy to the homeowner.
// Panel/BFP feedback: "the incident can be downloaded into a PDF file ... and sent
// to the BFP for their records."
//
// Called by the signed-in app user (Authorization: Bearer <user JWT>).
// Body: { report_number, pdf_base64, summary?: { room, type, first_detected, last_detected } }
// E-mail is sent from EMAIL_FROM (dev.pyroguard@gmail.com):
//   GMAIL_APP_PASSWORD -> Gmail SMTP over SSL port 465 (Supabase blocks 25/587 only)
//   or BREVO_API_KEY / RESEND_API_KEY as before. EMAIL_FROM_NAME is optional.
// Every attempt is logged in public.pyroguard_bfp_report_emails.
// ---------------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2'
import nodemailer from 'npm:nodemailer@6.9.16'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const env = (n: string) => Deno.env.get(n)?.trim() ?? ''
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/
const MAX_PDF_B64 = 8 * 1024 * 1024 // about 6 MB of PDF
const MAX_PER_HOUR = 10

async function sendMail(to: string, cc: string | null, subject: string, html: string, filename: string, pdfB64: string) {
  const from = env('EMAIL_FROM'), fromName = env('EMAIL_FROM_NAME') || 'PyroGuard Alerts'
  if (!from) throw new Error('E-mail is not set up on the server (EMAIL_FROM secret missing).')
  if (env('GMAIL_APP_PASSWORD')) {
    const transport = nodemailer.createTransport({
      host: 'smtp.gmail.com', port: 465, secure: true,
      auth: { user: env('GMAIL_USER') || from, pass: env('GMAIL_APP_PASSWORD').replace(/\s/g, '') },
    })
    await transport.sendMail({
      from: `"${fromName}" <${from}>`, to, ...(cc ? { cc, replyTo: cc } : {}),
      subject, html,
      attachments: [{ filename, content: pdfB64, encoding: 'base64', contentType: 'application/pdf' }],
    })
    return 'gmail'
  }
  if (env('BREVO_API_KEY')) {
    const r = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': env('BREVO_API_KEY'), 'Content-Type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        sender: { email: from, name: fromName }, to: [{ email: to }],
        ...(cc ? { cc: [{ email: cc }], replyTo: { email: cc } } : {}),
        subject, htmlContent: html, attachment: [{ name: filename, content: pdfB64 }],
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
        from: `${fromName} <${from}>`, to: [to], ...(cc ? { cc: [cc], reply_to: cc } : {}),
        subject, html, attachments: [{ filename, content: pdfB64 }],
      }),
    })
    if (!r.ok) throw new Error(`Resend HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`)
    return 'resend'
  }
  throw new Error('E-mail is not set up on the server (GMAIL_APP_PASSWORD missing).')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)
  try {
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    if (!token) return json({ ok: false, error: 'Sign in first.' }, 401)
    const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'),
      { auth: { persistSession: false, autoRefreshToken: false } })
    const { data: who, error: authError } = await db.auth.getUser(token)
    const user = who?.user
    if (authError || !user) return json({ ok: false, error: 'Session expired. Sign in again.' }, 401)

    const body = await req.json().catch(() => ({})) as Record<string, any>
    const reportNo = String(body.report_number ?? '').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 60)
    const pdfB64 = String(body.pdf_base64 ?? '').replace(/\s/g, '')
    if (!reportNo) return json({ ok: false, error: 'Missing report number.' }, 400)
    if (!pdfB64 || !pdfB64.startsWith('JVBER')) return json({ ok: false, error: 'The attachment is not a PDF.' }, 400)
    if (pdfB64.length > MAX_PDF_B64) return json({ ok: false, error: 'The PDF is too large to e-mail.' }, 413)

    const { data: bfp } = await db.from('emergency_contacts')
      .select('station_name,name,personnel_name,rank_position,email')
      .eq('user_id', user.id).eq('is_primary', true).maybeSingle()
    const bfpEmail = String(bfp?.email ?? '').trim().toLowerCase()
    if (!EMAIL_RE.test(bfpEmail)) {
      return json({ ok: false, error: 'No BFP e-mail saved. Add it in Settings > BFP Contact Details.' }, 400)
    }
    const station = String(bfp?.station_name ?? bfp?.name ?? 'BFP station')

    const { count } = await db.from('pyroguard_bfp_report_emails').select('id', { count: 'exact', head: true })
      .eq('user_id', user.id).gte('created_at', new Date(Date.now() - 3600_000).toISOString())
    if ((count ?? 0) >= MAX_PER_HOUR) return json({ ok: false, error: 'Too many reports sent in the last hour. Try again later.' }, 429)

    const cc = user.email && user.email_confirmed_at && !user.email.endsWith('.local') ? user.email.toLowerCase() : null
    const { data: profile } = await db.from('profiles').select('full_name,phone').eq('user_id', user.id).maybeSingle()
    const { data: home } = await db.from('homes').select('address').eq('user_id', user.id).limit(1).maybeSingle()
    const s = (body.summary && typeof body.summary === 'object') ? body.summary : {}
    const owner = String(profile?.full_name ?? user.user_metadata?.full_name ?? 'PyroGuard homeowner')
    const attn = [bfp?.rank_position, bfp?.personnel_name].filter((x) => x && String(x).trim()).join(' ')

    const subject = `[PyroGuard] Incident Report ${reportNo} - ${String(s.type ?? 'Fire/Smoke')} at ${String(home?.address ?? 'registered home').slice(0, 80)}`
    const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#f5f5f5;font-family:Arial,sans-serif;color:#222">
<table role="presentation" style="width:100%;max-width:600px;margin:auto;border-spacing:0;background:#fff;border-radius:18px;overflow:hidden">
<tr><td style="padding:22px 28px;background:#b91c1c;color:#fff;font-size:20px;font-weight:bold">PyroGuard Incident Report ${esc(reportNo)}</td></tr>
<tr><td style="padding:24px 28px;line-height:1.6;font-size:14px">
<p style="margin-top:0">To: <b>${esc(station)}</b>${attn ? `<br>Attention: ${esc(attn)}` : ''}</p>
<p>Good day. Please find attached the incident report recorded by the PyroGuard home monitoring system, submitted for your records.</p>
<table style="border-spacing:0 4px">
<tr><td style="color:#666;padding-right:14px">Reported by</td><td>${esc(owner)}${profile?.phone ? ` (${esc(profile.phone)})` : ''}</td></tr>
<tr><td style="color:#666;padding-right:14px">Address</td><td>${esc(home?.address ?? 'See attached report')}</td></tr>
${s.room ? `<tr><td style="color:#666;padding-right:14px">Area</td><td>${esc(s.room)}</td></tr>` : ''}
${s.type ? `<tr><td style="color:#666;padding-right:14px">Incident</td><td>${esc(s.type)}</td></tr>` : ''}
${s.first_detected ? `<tr><td style="color:#666;padding-right:14px">First detected</td><td>${esc(s.first_detected)}</td></tr>` : ''}
${s.last_detected ? `<tr><td style="color:#666;padding-right:14px">Last detected</td><td>${esc(s.last_detected)}</td></tr>` : ''}
</table>
<p>The attached PDF contains the location with GPS coordinates, sensor readings, camera snapshots and a certification section.</p>
${cc ? `<p>To reply, simply reply to this e-mail; it goes to the homeowner (${esc(cc)}).</p>` : ''}
<p style="font-size:12px;color:#888">Sent from the PyroGuard app by the homeowner. This is a record copy, not an emergency dispatch request. For emergencies call 911.</p>
</td></tr></table></body></html>`

    const { data: logRow } = await db.from('pyroguard_bfp_report_emails')
      .insert({ user_id: user.id, report_number: reportNo, bfp_email: bfpEmail, bfp_station: station, cc_email: cc, status: 'pending' })
      .select('id').single()
    try {
      const provider = await sendMail(bfpEmail, cc, subject, html, `PyroGuard_Incident_${reportNo}.pdf`, pdfB64)
      if (logRow) await db.from('pyroguard_bfp_report_emails').update({ status: 'sent', provider, sent_at: new Date().toISOString() }).eq('id', logRow.id)
      return json({ ok: true, sent_to: bfpEmail, cc, station })
    } catch (e) {
      const msg = String(e instanceof Error ? e.message : e).slice(0, 1000)
      if (logRow) await db.from('pyroguard_bfp_report_emails').update({ status: 'failed', error: msg }).eq('id', logRow.id)
      return json({ ok: false, error: `E-mail could not be sent: ${msg}` }, 502)
    }
  } catch (error) {
    console.error('send-incident-report:', error)
    return json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500)
  }
})
