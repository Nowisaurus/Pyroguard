import { localMode } from '../_shared/local_sync.ts'
import { createClient } from '@supabase/supabase-js'
import { createConnection } from 'mysql2/promise'
import { mirrorAccount, registrationData } from '../_shared/account_mirror.ts'
const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS'}
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}})
const secret = (key: string) => {const value=Deno.env.get(key);if(!value)throw new Error(`Missing server secret: ${key}`);return value}
Deno.serve(async req => {
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors})
  if(req.method!=='POST')return json({error:'POST required'},405)
  let createdUser: any = null
  let sb: any = null
  let mysql: any = null
  try {
    const body = await req.json()
    const email = String(body.email ?? '').trim().toLowerCase()
    const password = String(body.password ?? '')
    const fixed = ['nowel@pyroguard.local','benedict@pyroguard.local','christian@pyroguard.local','danahia@pyroguard.local']
    if(fixed.includes(email))return json({error:'Administrator emails cannot be registered as homeowners.'},403)
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || password.length<12 || password.length>256 ||
       /\s/.test(password) || !/[A-Z]/.test(password) || !/[a-z]/.test(password) || !/[0-9]/.test(password) || !/[^A-Za-z0-9]/.test(password)) return json({error:'Valid email and a strong 12-character password are required.'},400)
    const metadata = registrationData(body.metadata ?? {})
    for(const [key,value] of Object.entries(metadata)) {
      if(value !== null && !['string','number','boolean'].includes(typeof value))return json({error:`Invalid ${key}`},400)
      if(typeof value==='string' && value.length>2000)return json({error:`${key} is too long`},400)
    }
    const url=secret('SUPABASE_URL')
    sb=createClient(url,secret('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}})
    // A known configuration/connection outage fails BEFORE creating Auth data.
    if(!localMode()) {
    const port=Number(Deno.env.get('MYSQL_PORT') ?? '3306')
    if(!Number.isInteger(port) || port<1 || port>65535)throw new Error('Invalid MYSQL_PORT')
    mysql=await createConnection({host:secret('MYSQL_HOST'),port,user:secret('MYSQL_USER'),password:secret('MYSQL_PASSWORD'),database:secret('MYSQL_DATABASE'),connectTimeout:8000,timezone:'Z',ssl:(Deno.env.get('MYSQL_SSL') ?? 'true').toLowerCase()==='true'?{rejectUnauthorized:true}:undefined})
    for (const table of ['pyroguard_profiles','pyroguard_account_identities','pyroguard_mirror_records']) await mysql.execute(`SELECT user_id FROM ${table} LIMIT 0`)
    }
    const signup=createClient(url,secret('SUPABASE_ANON_KEY'),{auth:{persistSession:false,autoRefreshToken:false}})
    // Honor Supabase confirmation, rate limits and CAPTCHA. Never admin-create
    // or auto-confirm a public signup; MySQL does not authenticate passwords.
    const redirect=Deno.env.get('PYROGUARD_SITE_URL')?.trim()
    const {data,error}=await signup.auth.signUp({email,password,options:{data:metadata,
      ...(redirect?{emailRedirectTo:redirect}:{}), ...(body.captcha_token?{captchaToken:String(body.captcha_token)}:{})}})
    if(error)return json({error:error.message},400)
    const user=data.user
    // Supabase can return an obfuscated user for duplicate registrations.
    // Do not disclose existing identity data or perform a mirror for that case.
    if(!user || !user.identities?.length)return json({ok:true,confirmation_required:true,dual_saved:false,pending:true})
    createdUser=user
    const {data:canonical,error:canonicalError}=await sb.auth.admin.getUserById(user.id)
    if(canonicalError || !canonical?.user)throw new Error('Canonical Auth identity unavailable.')
    const canonicalUser=canonical.user
    if(canonicalUser.email_confirmed_at && (data.session || !canonicalUser.confirmation_sent_at))return json({ok:false,account_created:true,source_saved:false,error:'Enable Confirm email in Supabase Authentication before accepting new registrations. No application account was finalized.'},409)
    if(!canonicalUser.email_confirmed_at)return json({ok:true,account_created:true,source_saved:false,awaiting_confirmation:true,confirmation_required:true,dual_saved:false,pending:false,sync_mode:localMode()?'local-pc':'hosted'})
    const canonicalMetadata=registrationData(canonicalUser.user_metadata ?? {})
    const now=new Date().toISOString()
    // Duplicate/resend signup must never reactivate or rewrite an existing
    // account. Existing rows stay authoritative; fill only missing source rows.
    const {error:profileError}=await sb.from('profiles').upsert({id:user.id,user_id:user.id,
      full_name:canonicalMetadata.full_name ?? email.split('@')[0],email:canonicalUser.email,phone:canonicalMetadata.phone_number ?? '',
      account_role:'homeowner',account_status:'active',updated_at:now},{onConflict:'id',ignoreDuplicates:true})
    const {error:identityError}=await sb.from('account_identities').upsert({user_id:user.id,email:canonicalUser.email,
      display_name:canonicalMetadata.full_name ?? email.split('@')[0],phone:canonicalMetadata.phone_number ?? '',
      account_role:'homeowner',auth_provider:'email',email_confirmed:Boolean(canonicalUser.email_confirmed_at),
      account_status:'active',mysql_synced:false,updated_at:now},{onConflict:'user_id',ignoreDuplicates:true})
    if(profileError || identityError)throw new Error('Canonical registration source could not be saved.')
    const {data:sourceProfile,error:readProfile}=await sb.from('profiles').select('user_id,email,account_role,account_status').eq('user_id',user.id).maybeSingle()
    const {data:sourceIdentity,error:readIdentity}=await sb.from('account_identities').select('user_id,email,account_role,account_status').eq('user_id',user.id).maybeSingle()
    if(readProfile || readIdentity || !sourceProfile || !sourceIdentity ||
      sourceProfile.user_id!==canonicalUser.id || sourceIdentity.user_id!==canonicalUser.id ||
      sourceProfile.email!==canonicalUser.email || sourceIdentity.email!==canonicalUser.email)throw new Error('Registration source read-back failed.')
    let dualSaved=false
    try {if(!localMode()){await mirrorAccount(sb,mysql,user.id);dualSaved=true}} catch(e) {
      console.error('register-account mirror failed:',e)
      await sb.from('account_identities').update({mysql_synced:false,last_sync_error:'Registration mirror pending; server worker must retry.'}).eq('user_id',user.id)
    }
    return json({ok:true,account_created:true,source_saved:true,dual_saved:dualSaved,pending:!dualSaved,sync_mode:localMode()?'local-pc':'hosted',
      confirmation_required:!data.session,
      ...(data.session?{session:{access_token:data.session.access_token,refresh_token:data.session.refresh_token}}:{})})
  } catch(e) {
    console.error('register-account:',e)
    return json({ok:false,account_created:createdUser!==null,source_saved:false,error:createdUser?'Authentication account exists, but application source records could not be verified. Apply the current Supabase SQL and run the PC worker to recover the real account; do not recreate it.':'Registration is unavailable until the server database connection is configured.'},503)
  } finally {try{await mysql?.end()}catch(_){}}
})
