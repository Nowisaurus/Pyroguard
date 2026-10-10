// PyroGuard fire-alert — HUMAN-CONTROLLED RESPONSE
// -------------------------------------------------
// This function deliberately does NOT call, text, email, or dispatch the BFP.
// The thesis-aligned workflow is:
//   sensor hazard -> local/app alarm -> save evidence/history -> show saved
//   BFP station/personnel details -> homeowner taps CALL BFP.
//
// Keeping this no-dispatch function in the repository prevents an older
// automatic-Twilio template from being accidentally deployed.

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'content-type, authorization',
      },
    })
  }

  let payload: unknown = null
  try { payload = await req.json() } catch (_) { /* optional body */ }

  console.log('PyroGuard hazard webhook received. External BFP dispatch is intentionally disabled.', payload)
  return new Response(JSON.stringify({
    ok: true,
    external_dispatch: false,
    action: 'SHOW_CALL_BFP_TO_AUTHORIZED_USER',
    message: 'Hazard recorded. The user must place the BFP call from the PyroGuard emergency screen.',
  }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  })
})
