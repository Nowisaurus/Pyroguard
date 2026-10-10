import {readFile} from 'node:fs/promises';
import {createClient} from '@supabase/supabase-js';
import {createConnection} from 'mysql2/promise';
import {business,digest,identifier,mirrorRow,pages,stable} from './core.mjs';

const tables=JSON.parse(await readFile(new URL('./tables.json',import.meta.url),'utf8'));
const registrationKeys=['full_name','phone_number','home_name','address','home_latitude','home_longitude','device_id','stakeholder_name','stakeholder_relationship','stakeholder_phone','bfp_station_name','bfp_personnel_name','bfp_rank_position','bfp_phone','bfp_address','safety_acknowledged','onboarding_completed'];
const required=name=>{const value=process.env[name]?.trim();if(!value)throw new Error('Set '+name+' in the private .env file');return value;};
const port=Number(process.env.MYSQL_PORT??3306);
if(!Number.isInteger(port)||port<1||port>65535)throw new Error('Invalid MYSQL_PORT');
const interval=Number(process.env.SYNC_INTERVAL_SECONDS??15);
if(!Number.isFinite(interval)||interval<5)throw new Error('SYNC_INTERVAL_SECONDS must be at least 5');
const sb=createClient(required('SUPABASE_URL'),required('SUPABASE_SERVER_KEY'),{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:(url,init)=>fetch(url,{...init,signal:init?.signal?AbortSignal.any([init.signal,AbortSignal.timeout(30000)]):AbortSignal.timeout(30000)})}});
const options={host:required('MYSQL_HOST'),port,user:required('MYSQL_USER'),password:process.env.MYSQL_PASSWORD??'',database:required('MYSQL_DATABASE'),connectTimeout:8000,timezone:'Z',dateStrings:true,supportBigNumbers:true,bigNumberStrings:true,
  ssl:process.env.MYSQL_SSL==='true'?{rejectUnauthorized:true,...(process.env.MYSQL_CA_FILE?{ca:await readFile(process.env.MYSQL_CA_FILE,'utf8')}:{})}:undefined};
let stop=false;
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>{stop=true;});
const checked=async promise=>{const r=await promise;if(r.error)throw new Error('Supabase operation failed ('+(r.error.code??'query')+')');return r.data;};
async function publish(fields) {
  await checked(sb.from('pyroguard_local_sync_status').upsert({worker_id:'local-pc',heartbeat_at:new Date().toISOString(),...fields},{onConflict:'worker_id'}));
}
async function prepareAccounts() {
  const registrations=new Map();
  const admins=await checked(sb.from('admin_accounts').select('*'));
  for(let page=1;page<=100;page++) {
    const {data,error}=await sb.auth.admin.listUsers({page,perPage:1000});
    if(error)throw new Error('Auth account enumeration failed');
    for(const user of data.users) {
      // Pending Auth signup is not a completed application account.
      if(!user.email_confirmed_at || (!admins.some(a=>a.user_id===user.id) && (user.app_metadata?.provider??'email')==='email' && !user.confirmation_sent_at))continue;
      const metadata=Object.fromEntries(registrationKeys.filter(k=>user.user_metadata?.[k]!==undefined).map(k=>[k,user.user_metadata[k]]));
      // Mirror only documented non-secret metadata, never Auth credential data.
      registrations.set(user.id,metadata);
      const admin=admins.find(a=>a.user_id===user.id);
      const role=admin?.admin_role??'homeowner';
      const status=(user.banned_until && new Date(user.banned_until)>new Date())?'disabled':'active';
      const name=admin?.display_name??metadata.full_name??null;
      const phone=metadata.phone_number??user.phone??null;
      const now=new Date().toISOString();
      await checked(sb.from('profiles').upsert({id:user.id,user_id:user.id,email:user.email??null,full_name:name,phone,account_role:role,account_status:status,created_at:user.created_at,updated_at:now},{onConflict:'id',ignoreDuplicates:true}));
      await checked(sb.from('account_identities').upsert({user_id:user.id,email:user.email??null,display_name:name,phone,account_role:role,account_status:status,auth_provider:user.app_metadata?.provider??'email',email_confirmed:!!user.email_confirmed_at,mysql_synced:false,created_at:user.created_at,updated_at:now},{onConflict:'user_id',ignoreDuplicates:true}));
      const identity=await checked(sb.from('account_identities').select('*').eq('user_id',user.id).maybeSingle());
      if(identity && (identity.email!==user.email || identity.email_confirmed!==!!user.email_confirmed_at))await checked(sb.from('account_identities').update({email:user.email??null,email_confirmed:!!user.email_confirmed_at,mysql_synced:false,updated_at:now}).eq('user_id',user.id).eq('updated_at',identity.updated_at));
      const existing=await checked(sb.from('mirror_records').select('*').eq('user_id',user.id).eq('record_type','registration_snapshot').eq('record_key',user.id).maybeSingle());
      if(!existing || stable(existing.payload)!==stable(metadata))await checked(sb.from('mirror_records').upsert({user_id:user.id,device_id:metadata.device_id??null,record_type:'registration_snapshot',record_key:user.id,payload:metadata,mysql_synced:false,updated_at:now},{onConflict:'user_id,record_type,record_key'}));
    }
    if(data.users.length<1000)return registrations;
  }
  throw new Error('Auth enumeration limit reached; no full verification reported');
}

async function run() {
  let db=null,heartbeat=null;
  const report={ok:false,tables:{},account_checks:{},errors:[],scope:'25 public application tables; full JSON plus matching typed columns; Supabase is authoritative'};
  const startedAt=new Date().toISOString();
  let connected=false;
  let ownsLock=false;
  let request=null;
  try {
    // Refuse a second worker on the same DB. Connection-owned lock releases on exit/crash.
    db=await createConnection(options);
    const [lock]=await db.execute("SELECT GET_LOCK('pyroguard-local-sync',0) AS acquired");
    if(Number(lock[0]?.acquired)!==1)throw new Error('Another local worker is already running');
    ownsLock=true;connected=true;
    await db.execute(`CREATE TABLE IF NOT EXISTS pyroguard_local_source_records (
      source_table VARCHAR(100) NOT NULL,source_key VARCHAR(255) NOT NULL,
      payload JSON NOT NULL,payload_hash CHAR(64) NOT NULL,is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
      synced_at DATETIME(3) NOT NULL,PRIMARY KEY(source_table,source_key)) ENGINE=InnoDB`);
    request=(await checked(sb.from('pyroguard_local_sync_status').select('requested_at').eq('worker_id','local-pc').maybeSingle()))?.requested_at??null;
    await publish({mysql_connected:true,started_at:startedAt,report});
    // Only heartbeat writes overlap. Never overlap MySQL transactions/cycles.
    let heartbeatBusy=false;
    heartbeat=setInterval(async()=>{if(heartbeatBusy)return;heartbeatBusy=true;try{await publish({mysql_connected:true});}catch{}finally{heartbeatBusy=false;}},20000);
    const registrations=await prepareAccounts();
    const [schema]=await db.execute('SELECT TABLE_NAME,COLUMN_NAME,DATA_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,CHARACTER_MAXIMUM_LENGTH,DATETIME_PRECISION FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE()');
    const accounts={profiles:new Map(),account_identities:new Map()};
    const ledger=[];
    const pending=[];
    for(const table of tables) {
      const stats={state:'running',rows:0,verified_rows:0,archive_only_fields:[]};
      report.tables[table.source]=stats;
      const columns=schema.filter(c=>c.TABLE_NAME===table.target);
      try {
        if(!columns.length)throw new Error('Missing MySQL table '+table.target+'; inspect existing safe migrations');
        for await(const batch of pages(sb,table))for(const row of batch) {
          if(stop)throw new Error('Worker stopped; cycle incomplete');
          stats.rows++;
          const result=await mirrorRow(db,table,row,columns);
          // A changed source is left pending; never acknowledge a newer version.
          const fresh=await checked(sb.from(table.source).select('*').eq(table.key,row[table.key]).maybeSingle());
          if(!fresh || digest(business(fresh))!==result.hash)throw new Error('Source changed during copy; next cycle will retry '+table.source);
          stats.verified_rows++;
          stats.archive_only_fields=[...new Set([...stats.archive_only_fields,...result.archiveOnlyFields])];
          if(accounts[table.source])accounts[table.source].set(row.user_id,row);
          if(table.source==='dual_record_ledger' && row.source==='supabase_table_trigger' && row.operation==='DELETE' && row.mysql_synced!==true)ledger.push(row);
          if(Object.hasOwn(row,'mysql_synced') && row.mysql_synced!==true)pending.push({table,row});
        }
        stats.state='verified';
      }catch(e){stats.state='pending';report.errors.push({table:table.source,error:e.message});}
    }
    // Deletes apply only to source-owned rows already copied by this worker.
    // Re-read current source: an old delete must never remove a recreated row.
    for(const event of ledger) {
      const table=tables.find(t=>t.source===event.record_type);
      const value=event.payload?.[table?.key];
      if(!table || value==null){report.errors.push({table:'deletions',error:'Delete event lacks a supported source key'});continue;}
      try {
        const current=await checked(sb.from(table.source).select(table.key).eq(table.key,value).maybeSingle());
        if(current)continue;
        const [owned]=await db.execute('SELECT payload FROM pyroguard_local_source_records WHERE source_table=? AND source_key=?',[table.source,String(value)]);
        await db.beginTransaction();
        try {
          if(owned.length)await db.execute(`DELETE FROM ${identifier(table.target)} WHERE ${identifier(table.key)}=?`,[value]);
          await db.execute(`INSERT INTO pyroguard_local_source_records (source_table,source_key,payload,payload_hash,is_deleted,synced_at) VALUES (?,?,?,?,TRUE,UTC_TIMESTAMP(3)) ON DUPLICATE KEY UPDATE payload=VALUES(payload),payload_hash=VALUES(payload_hash),is_deleted=TRUE,synced_at=VALUES(synced_at)`,[table.source,String(value),stable(event.payload),digest(event.payload)]);
          await db.commit();
        }catch(e){await db.rollback();throw e;}
      }catch(e){report.errors.push({table:'deletions',error:e.message});}
    }
    // A ledger item is acknowledged only after ALL typed tables and delete work
    // succeeded. A partial cycle leaves all acknowledgments pending for retry.
    if(!report.errors.length) {
      for(const {table,row} of pending) {
        let update=sb.from(table.source).update({mysql_synced:true,mysql_synced_at:new Date().toISOString(),last_sync_error:null}).eq(table.key,row[table.key]).eq('mysql_synced',false);
        if(row.updated_at!=null)update=update.eq('updated_at',row.updated_at);
        else if(row.payload!=null)update=update.eq('payload',JSON.stringify(row.payload));
        await checked(update);
      }
    }
    // Account hashes link the real profile/identity content and safe Auth
    // registration metadata to the last completed, verified MySQL read-back.
    for(const [id,registration] of registrations) {
      const profile=accounts.profiles.get(id),identity=accounts.account_identities.get(id);
      if(profile && identity && report.tables.profiles?.state==='verified' && report.tables.account_identities?.state==='verified' && report.tables.mirror_records?.state==='verified')report.account_checks[id]=digest({profile:business(profile),identity:business(identity),registration});
    }
    report.ok=report.errors.length===0 && tables.every(t=>report.tables[t.source]?.state==='verified');
    await db.execute('SELECT 1 AS final_connection_check');
    await publish({mysql_connected:true,completed_at:new Date().toISOString(),report,...(request && report.ok?{acknowledged_at:request}:{})});
    console.log(`${new Date().toISOString()} ${report.ok?'VERIFIED':'PENDING'}: ${Object.values(report.tables).filter(t=>t.state==='verified').length}/${tables.length} tables; ${report.errors.length} errors`);
    for(const e of report.errors)console.error(`${e.table}: ${e.error}`);
  }catch(e) {
    if(['ECONNREFUSED','ECONNRESET','ETIMEDOUT','PROTOCOL_CONNECTION_LOST'].includes(e.code))connected=false;
    report.errors.push({table:'worker',error:e.message});
    // Connection failures do not expose password/connection strings to the UI.
    try{if(db && !ownsLock)throw new Error('Worker lock not owned');await publish({mysql_connected:connected,report});}catch{console.error('Cannot publish status. Check server key and database/PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase).');}
    console.error('Cycle failed:',e.code??e.message);
  }finally {
    if(heartbeat)clearInterval(heartbeat);
    await db?.end().catch(()=>{});
  }
  return report.ok;
}

do {
  const ok=await run();
  if(process.argv.includes('--once')){process.exitCode=ok?0:1;break;}
  for(let seconds=0;seconds<interval && !stop;seconds++)await new Promise(resolve=>setTimeout(resolve,1000));
}while(!stop);
