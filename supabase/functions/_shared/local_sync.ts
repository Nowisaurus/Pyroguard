const bookkeeping=new Set(['mysql_synced','mysql_synced_at','last_sync_error','updated_at'])
export const localMode=()=>Deno.env.get('PYROGUARD_MYSQL_MODE')==='local-pc'
function canonical(value:any):any {
  if(Array.isArray(value))return value.map(canonical)
  if(value && typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])]))
  return value
}
export const business=(row:any)=>Object.fromEntries(Object.entries(row).filter(([key])=>!bookkeeping.has(key)))
export async function accountHash(profile:any,identity:any,registration:any) {
  const bytes=new TextEncoder().encode(JSON.stringify(canonical({profile:business(profile),identity:business(identity),registration})))
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(v=>v.toString(16).padStart(2,'0')).join('')
}
export async function localStatus(sb:any,requestSync=false) {
  if(requestSync) {
    const {error}=await sb.from('pyroguard_local_sync_status').upsert({worker_id:'local-pc',requested_at:new Date().toISOString()},{onConflict:'worker_id'})
    if(error)throw new Error('Install database/PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) before requesting local sync')
  }
  const {data,error}=await sb.from('pyroguard_local_sync_status').select('*').eq('worker_id','local-pc').maybeSingle()
  if(error)throw new Error('Local PC status table unavailable; install database/PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase)')
  const fresh=!!data?.heartbeat_at && Date.now()-Date.parse(data.heartbeat_at)<90000
  const report=data?.report??{}
  const completed=!!data?.completed_at && data.completed_at>=data.started_at
  const healthy=fresh && data?.mysql_connected===true
  return {status:data,report,health:{supabase:true,mysql:healthy,mode:'local-pc',worker_online:fresh,checked_at:data?.heartbeat_at??null,last_completed_at:data?.completed_at??null,
    cycle_complete:completed && report.ok===true,mysql_expected_table_count:25,mysql_table_count:Object.values(report.tables??{}).filter((t:any)=>t.state==='verified').length,mysql_schema_parity:Object.values(report.tables??{}).filter((t:any)=>t.state==='verified').length===25,
    table_results:report.tables??{},sync_requested:data?.requested_at!=null && (!data?.acknowledged_at || data.requested_at>data.acknowledged_at),
    error:!fresh?'Local PC sync worker is offline or has not reported. Start it on your MySQL PC.':!healthy?'Local worker cannot connect to MySQL. Check its private .env settings.':!completed?'Local worker is copying records; wait for this cycle to finish.':report.ok!==true?'Some tables are pending. Inspect the local worker output and table results.':null}}
}
