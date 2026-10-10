import { createClient } from '@supabase/supabase-js'
import { createConnection } from 'mysql2/promise'
import { mirrorAccount, registrationData } from '../_shared/account_mirror.ts'
import { localMode, localStatus, accountHash } from '../_shared/local_sync.ts'

const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS'}
const json = (body: unknown, status=200) => new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}})
const fixedEmails = new Set(['nowel@pyroguard.local','benedict@pyroguard.local','christian@pyroguard.local','danahia@pyroguard.local'])
const secret = (key: string) => {const v=Deno.env.get(key);if(!v)throw new Error(`Missing ${key}`);return v}
const normalized = (v: unknown) => String(v ?? '').trim().toLowerCase()
const equivalent = (a: unknown,b: unknown) => (a ?? '') === (b ?? '')
const confirmed = (v: unknown) => v === true || v === 1 || v === '1'
export function accountParity(user: any, profile: any, identity: any, mysqlProfile: any, mysqlIdentity: any, snapshot: any) {
  if (!profile || !identity) return 'source_missing'
  if (!mysqlProfile || !mysqlIdentity || !snapshot) return 'mysql_missing'
  if (mysqlProfile.user_id !== user.id || mysqlIdentity.user_id !== user.id ||
      normalized(profile.email) !== normalized(user.email) || normalized(identity.email) !== normalized(user.email) ||
      normalized(mysqlProfile.email) !== normalized(user.email) || normalized(mysqlIdentity.email) !== normalized(user.email)) return 'mismatch'
  for (const field of ['full_name','phone','account_role','account_status']) if (!equivalent(profile[field],mysqlProfile[field])) return 'mismatch'
  for (const field of ['display_name','phone','account_role','account_status','auth_provider']) if (!equivalent(identity[field],mysqlIdentity[field])) return 'mismatch'
  if (confirmed(identity.email_confirmed) !== Boolean(user.email_confirmed_at) || confirmed(mysqlIdentity.email_confirmed) !== Boolean(user.email_confirmed_at)) return 'mismatch'
  if (profile.account_role !== identity.account_role) return 'mismatch'
  let payload: any
  try {payload=typeof snapshot.payload==='string'?JSON.parse(snapshot.payload):snapshot.payload} catch(_){return 'mismatch'}
  for (const [key,value] of Object.entries(registrationData(user.user_metadata ?? {}))) if (payload?.[key] !== value) return 'mismatch'
  return 'verified'
}

Deno.serve(async req => {
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors})
  if(req.method!=='POST')return json({error:'POST required'},405)
  let mysql: any = null
  try {
    const token=(req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i,'').trim()
    if(!token)return json({error:'Authentication required'},401)
    const sb=createClient(secret('SUPABASE_URL'),secret('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}})
    const {data:auth,error:authError}=await sb.auth.getUser(token)
    if(authError || !auth?.user)return json({error:'Valid session required'},401)
    if(!fixedEmails.has(normalized(auth.user.email)))return json({error:'Administrator access required'},403)
    const {data:admin,error:adminError}=await sb.from('admin_accounts').select('*').eq('user_id',auth.user.id).eq('active',true).maybeSingle()
    if(adminError || !admin || normalized(admin.email)!==normalized(auth.user.email) || !['administrator','head_developer'].includes(admin.admin_role))return json({error:'Active administrator registry entry required'},403)
    const body=await req.json()
    const action=String(body.action ?? 'read')
    if(action==='identity')return json({ok:true,admin})
    if(action==='manage_user') {
      const userId=String(body.user_id??'')
      const status=String(body.account_status??'')
      if(!['active','disabled'].includes(status))return json({error:'Invalid account status'},400)
      const {data:target,error:targetError}=await sb.auth.admin.getUserById(userId)
      if(targetError || !target.user)return json({error:'User not found'},404)
      if(fixedEmails.has(normalized(target.user.email)))return json({error:'Administrator accounts cannot be changed here'},403)
      const {data:profile,error:pe}=await sb.from('profiles').select('user_id').eq('user_id',userId).maybeSingle()
      const {data:identity,error:ie}=await sb.from('account_identities').select('user_id').eq('user_id',userId).maybeSingle()
      if(pe || ie || !profile || !identity)return json({error:'Repair the missing account source records before managing this account'},409)
      const {error:authWrite}=await sb.auth.admin.updateUserById(userId,{ban_duration:status==='disabled'?'876000h':'none'})
      if(authWrite)throw authWrite
      const now=new Date().toISOString()
      const {error:p}=await sb.from('profiles').update({account_status:status,updated_at:now}).eq('user_id',userId)
      const {error:i}=await sb.from('account_identities').update({account_status:status,mysql_synced:false,updated_at:now}).eq('user_id',userId)
      if(p || i)return json({error:'Authentication updated, but application status update is incomplete. Retry this action.'},409)
      return json({ok:true,mysql_pending:true})
    }
    if(action==='manage_device') {
      const deviceId=String(body.device_id??'').trim()
      const {data:device,error:de}=await sb.from('devices').select('*').eq('device_id',deviceId).maybeSingle()
      if(de || !device)return json({error:'Registered device not found'},404)
      const name=String(body.device_name??'').trim()
      if(!name || name.length>120)return json({error:'Enter a device name of 1–120 characters'},400)
      const {error:e}=await sb.from('devices').update({device_name:name,updated_at:new Date().toISOString()}).eq('device_id',deviceId)
      if(e)throw e
      return json({ok:true,mysql_pending:true})
    }
    if(action==='queue_security') {
      const deviceId=String(body.device_id??'').trim()
      const {data:device,error:de}=await sb.from('devices').select('*').eq('device_id',deviceId).maybeSingle()
      if(de || !device)return json({error:'Registered device not found'},404)
      const mode=String(body.arm_mode??'')
      if(!['DISARMED','ARM_HOME','ARM_AWAY'].includes(mode))return json({error:'Invalid security mode'},400)
      const {data:state,error:se}=await sb.from('system_state').select('*').eq('device_id',deviceId).maybeSingle()
      if(se)throw se
      const payload={arm_mode:mode,door_enabled:state?.door_enabled??true,window_enabled:state?.window_enabled??true,motion_enabled:state?.motion_enabled??true}
      const {error:stateWrite}=await sb.from('system_state').upsert({user_id:device.user_id,device_id:deviceId,...payload,acting_user:auth.user.id,updated_at:new Date().toISOString()},{onConflict:'device_id'})
      if(stateWrite)throw stateWrite
      const {data:queued,error:qe}=await sb.from('device_commands').insert({user_id:device.user_id,target_device_id:deviceId,command:'SET_SECURITY_MODE',payload,requested_by:auth.user.id,status:'pending'}).select('id,status').single()
      if(qe)throw qe
      return json({ok:true,command:queued,mysql_pending:true})
    }
    if(!['read','sync'].includes(action))return json({error:'Unknown action'},400)
    const failures: string[]=[]
    const authUsers: any[]=[]
    let truncated=false
    // Enumerate actual Auth records, including unconfirmed registrations.
    // Never infer their existence from a profile count or seed a placeholder.
    for(let page=1;page<=5;page++) {
      const {data,error}=await sb.auth.admin.listUsers({page,perPage:1000})
      if(error)throw new Error('Auth account listing failed')
      authUsers.push(...data.users)
      if(data.users.length<1000)break
      if(page===5)truncated=true
    }
    const users=authUsers.filter(u=>!fixedEmails.has(normalized(u.email)))
      .sort((a,b)=>new Date(b.created_at).getTime()-new Date(a.created_at).getTime()).slice(0,100)
    const ids=users.map(u=>u.id)
    const read=async (label: string,request: any) => {
      const {data,error}=await request
      if(error){failures.push(`${label} could not be read. Check the installed schema and server logs.`);console.error(label,error);return []}
      return data ?? []
    }
    let [profiles,identities,admins,devices,events,mirrors,ledger]=await Promise.all([
      ids.length?read('Profiles',sb.from('profiles').select('*').in('user_id',ids)):[],
      ids.length?read('Identities',sb.from('account_identities').select('*').in('user_id',ids)):[],
      read('Admin registry',sb.from('admin_accounts').select('*').order('admin_order')),
      read('Devices',sb.from('devices').select('*').order('updated_at',{ascending:false}).limit(100)),
      read('Events',sb.from('event_history').select('*').order('created_at',{ascending:false}).limit(100)),
      read('Mirror queue',sb.from('mirror_records').select('*').eq('mysql_synced',false).limit(100)),
      read('Ledger queue',sb.from('dual_record_ledger').select('*').eq('mysql_synced',false).limit(100)),
    ])
    const health: any={supabase:true,mysql:false,checked_at:new Date().toISOString(),mysql_expected_table_count:25,account_verification_scope:users.length}
    const syncResults: any[]=[]
    const pmap=new Map<string,any>(profiles.map((p:any)=>[p.user_id,p]))
    const imap=new Map<string,any>(identities.map((p:any)=>[p.user_id,p]))
    const verification=new Map<string,string>()
    if(localMode()) {
      const local=await localStatus(sb,action==='sync')
      Object.assign(health,local.health)
      health.account_verification_scope=users.length
      for(const user of users) {
        const profile=pmap.get(user.id),identity=imap.get(user.id)
        const hash=profile && identity?await accountHash(profile,identity,registrationData(user.user_metadata??{})):null
        const matches=hash!==null && local.report.account_checks?.[user.id]===hash
        verification.set(user.id,!health.mysql?'unavailable':!profile || !identity?'source_missing':matches?'verified':'pending')
      }
      health.verified_accounts=[...verification.values()].filter(s=>s==='verified').length
      if(action==='sync')syncResults.push({status:'requested',message:'The local PC worker will retry on its next cycle.'})
    }else try {
      const port=Number(Deno.env.get('MYSQL_PORT') ?? '3306')
      if(!Number.isInteger(port) || port<1 || port>65535)throw new Error('Invalid MYSQL_PORT')
      mysql=await createConnection({host:secret('MYSQL_HOST'),port,user:secret('MYSQL_USER'),password:secret('MYSQL_PASSWORD'),database:secret('MYSQL_DATABASE'),connectTimeout:8000,timezone:'Z',ssl:(Deno.env.get('MYSQL_SSL') ?? 'true').toLowerCase()==='true'?{rejectUnauthorized:true}:undefined})
      await mysql.execute('SELECT 1 AS ok')
      health.mysql=true
      const tables=['pyroguard_admin_accounts', 'pyroguard_profiles', 'pyroguard_account_identities', 'pyroguard_homes', 'pyroguard_stakeholders', 'pyroguard_emergency_contacts', 'pyroguard_safety_setups', 'pyroguard_user_preferences', 'pyroguard_devices', 'pyroguard_device_current_state', 'pyroguard_device_heartbeats', 'pyroguard_pyroguard_camera_telemetry', 'pyroguard_system_state', 'pyroguard_device_commands', 'pyroguard_ptz_state', 'pyroguard_ptz_commands', 'pyroguard_sensor_history', 'pyroguard_event_history', 'pyroguard_camera_history', 'pyroguard_camera_events', 'pyroguard_audio_sessions', 'pyroguard_mirror_records', 'pyroguard_dual_record_ledger', 'pyroguard_emergency_action_logs', 'pyroguard_sensor_readings']
      const [tableRows]=await mysql.execute(`SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN (${tables.map(()=>'?').join(',')})`,tables)
      health.mysql_table_count=Number((tableRows as any[])[0]?.count ?? 0)
      health.mysql_schema_parity=health.mysql_table_count===25
      if(action==='sync') {
        for(const user of users) {
          if(!user.email_confirmed_at || ((user.app_metadata?.provider??'email')==='email' && !user.confirmation_sent_at))continue;
          try {
            // Fill a genuinely missing application row from the actual Auth
            // account. Existing permissions and status remain unchanged.
            const now=new Date().toISOString()
            const data=registrationData(user.user_metadata ?? {})
            const banned=Boolean(user.banned_until && new Date(user.banned_until)>new Date())
            if(!pmap.has(user.id)) {
              const {error}=await sb.from('profiles').upsert({id:user.id,user_id:user.id,email:user.email,full_name:data.full_name ?? null,phone:data.phone_number ?? null,account_role:'homeowner',account_status:banned?'disabled':'active',created_at:user.created_at,updated_at:now},{onConflict:'id',ignoreDuplicates:true})
              if(error)throw error
            }
            if(!imap.has(user.id)) {
              const {error}=await sb.from('account_identities').upsert({user_id:user.id,email:user.email,display_name:data.full_name ?? null,phone:data.phone_number ?? null,account_role:'homeowner',account_status:banned?'disabled':'active',auth_provider:user.app_metadata?.provider ?? 'email',email_confirmed:Boolean(user.email_confirmed_at),mysql_synced:false,created_at:user.created_at,updated_at:now},{onConflict:'user_id',ignoreDuplicates:true})
              if(error)throw error
            }
            // Reconcile identifying fields only from the actual Auth record.
            // Never change existing permissions or status based on user metadata.
            const existingProfile=pmap.get(user.id)
            const actualName=typeof data.full_name==='string'?data.full_name:existingProfile?.full_name ?? null
            const actualPhone=typeof data.phone_number==='string'?data.phone_number:user.phone ?? existingProfile?.phone ?? null
            const {error:profileUpdate}=await sb.from('profiles').update({email:user.email,full_name:actualName,phone:actualPhone,updated_at:now}).eq('user_id',user.id)
            const {error:identityUpdate}=await sb.from('account_identities').update({email:user.email,display_name:actualName,phone:actualPhone,email_confirmed:Boolean(user.email_confirmed_at),mysql_synced:false,updated_at:now}).eq('user_id',user.id)
            if(profileUpdate || identityUpdate)throw new Error('Canonical account fields could not be reconciled')
            await mirrorAccount(sb,mysql,user.id)
            syncResults.push({user_id:user.id,status:'saved'})
          }catch(e){console.error('Account repair',user.id,e);syncResults.push({user_id:user.id,status:'pending',error:'Source disagreement or a database write failed; inspect server logs.'})}
        }
        const workerSecret=Deno.env.get('SYNC_WORKER_SECRET')
        if(workerSecret) {
          try {
            const response=await fetch(`${secret('SUPABASE_URL')}/functions/v1/sync-outbox`,{method:'POST',headers:{'Content-Type':'application/json','x-sync-secret':workerSecret},body:'{}'})
            if(!response.ok)throw new Error('Outbox worker unavailable')
            const worker=await response.json()
            health.outbox_result={ok:worker.ok===true,failed:worker.failed ?? null,ledger:worker.ledger ?? 0,mirror:worker.mirror ?? 0,identity:worker.identity ?? 0}
            if(worker.ok!==true)failures.push('Some outbox writes still failed; inspect sync-outbox logs.')
          }catch(e){console.error('Global outbox retry',e);failures.push('Global outbox retry is unavailable. Deploy sync-outbox and verify SYNC_WORKER_SECRET.')}
        }else failures.push('Account sync ran; global outbox retry requires SYNC_WORKER_SECRET.')
        mirrors=await read('Mirror queue',sb.from('mirror_records').select('*').eq('mysql_synced',false).limit(100))
        ledger=await read('Ledger queue',sb.from('dual_record_ledger').select('*').eq('mysql_synced',false).limit(100))
        profiles=ids.length?await read('Profiles',sb.from('profiles').select('*').in('user_id',ids)):[]
        identities=ids.length?await read('Identities',sb.from('account_identities').select('*').in('user_id',ids)):[]
        pmap.clear();imap.clear()
        for(const p of profiles)pmap.set(p.user_id,p)
        for(const p of identities)imap.set(p.user_id,p)
      }
      if(ids.length) {
        const placeholders=ids.map(()=>'?').join(',')
        const [mp]=await mysql.execute(`SELECT * FROM pyroguard_profiles WHERE user_id IN (${placeholders})`,ids)
        const [mi]=await mysql.execute(`SELECT * FROM pyroguard_account_identities WHERE user_id IN (${placeholders})`,ids)
        const [snap]=await mysql.execute(`SELECT user_id,payload FROM pyroguard_mirror_records WHERE record_type='registration_snapshot' AND user_id IN (${placeholders})`,ids)
        const mm=new Map((mp as any[]).map(p=>[p.user_id,p]));const ii=new Map((mi as any[]).map(p=>[p.user_id,p]));const ss=new Map((snap as any[]).map(p=>[p.user_id,p]))
        for(const u of users)verification.set(u.id,accountParity(u,pmap.get(u.id),imap.get(u.id),mm.get(u.id),ii.get(u.id),ss.get(u.id)))
      }
      health.verified_accounts=[...verification.values()].filter(s=>s==='verified').length
    }catch(e){console.error('Admin MySQL check',e);health.error='MySQL verification failed. Configure the MySQL Edge Function secrets, remote connectivity and installed tables.'}
    return json({ok:true,admin,admins,devices,events,mirrors,ledger,profiles,identities,health,failures,sync_results:syncResults,commands:await read('Commands',sb.from('device_commands').select('*').order('created_at',{ascending:false}).limit(100)),auth_scan_truncated:truncated,
      users:users.map(u=>({user_id:u.id,email:u.email,full_name:(pmap.get(u.id) as any)?.full_name ?? u.user_metadata?.full_name ?? null,created_at:u.created_at,email_confirmed:Boolean(u.email_confirmed_at),profile_present:failures.some(f=>f.startsWith('Profiles '))?null:pmap.has(u.id),identity_present:failures.some(f=>f.startsWith('Identities '))?null:imap.has(u.id),account_role:(imap.get(u.id) as any)?.account_role ?? null,account_status:(imap.get(u.id) as any)?.account_status ?? null,verification:(!u.email_confirmed_at || ((u.app_metadata?.provider??'email')==='email' && !u.confirmation_sent_at))?'awaiting_confirmation':failures.some(f=>f.startsWith('Profiles ') || f.startsWith('Identities '))?'source_unavailable':verification.get(u.id) ?? 'unavailable'}))})
  }catch(e){console.error('admin-console',e);return json({error:'Admin data could not be loaded. Check function deployment and server logs.'},500)}
  finally{try{await mysql?.end()}catch(_){}}
})
