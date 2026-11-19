import { localMode } from '../_shared/local_sync.ts'
import { mirrorAccount } from '../_shared/account_mirror.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'
import { createConnection } from 'npm:mysql2@3/promise'
const secret = (n: string) => { const v = Deno.env.get(n); if (!v) throw new Error(`Missing ${n}`); return v }
const dt = (s: unknown) => { const v = new Date(String(s ?? '')); return isNaN(v.getTime()) ? new Date() : v }
Deno.serve(async req => {
  if (req.method !== 'POST' || req.headers.get('x-sync-secret') !== secret('SYNC_WORKER_SECRET')) return Response.json({error:'Unauthorized'}, {status:401})
  if(localMode())return Response.json({ok:false,pending:true,mode:'local-pc',message:'The worker on the MySQL PC handles local synchronization.'})
  const sb = createClient(secret('SUPABASE_URL'), secret('SUPABASE_SERVICE_ROLE_KEY'), {auth:{persistSession:false,autoRefreshToken:false}})
  const mysql = await createConnection({host:secret('MYSQL_HOST'), port:Number(Deno.env.get('MYSQL_PORT') ?? '3306'), user:secret('MYSQL_USER'), password:secret('MYSQL_PASSWORD'), database:secret('MYSQL_DATABASE'), ssl:(Deno.env.get('MYSQL_SSL') ?? 'true') === 'true' ? {rejectUnauthorized:true}:undefined})
  const stats = {ledger:0,mirror:0,identity:0,failed:0}
  try {
    for (const kind of ['ledger','mirror','identity'] as const) {
      const table = kind === 'ledger' ? 'dual_record_ledger' : kind === 'mirror' ? 'mirror_records':'account_identities'
      const key = kind === 'identity' ? 'user_id':'id'
      const {data:rows,error} = await sb.from(table).select('*').eq('mysql_synced',false).order('created_at').limit(100)
      if (error) { stats.failed++; continue }
      for (const row of rows ?? []) {
        try {
          if (kind === 'ledger') {
            // Persist an exact JSON snapshot of each source-table write, including
            // ESP32 direct REST writes captured by the Supabase trigger.
            // MySQL's unique (source_table, source_key) key makes retries idempotent.
            if (row.source === 'supabase_table_trigger') {
              await mysql.execute(
                `INSERT INTO pyroguard_source_records
                 (source_table, source_key, payload, is_deleted, source_record_id, last_operation, synced_at)
                 VALUES (?,?,?,?,?,?,UTC_TIMESTAMP(3))
                 ON DUPLICATE KEY UPDATE payload=VALUES(payload),
                   is_deleted=VALUES(is_deleted), source_record_id=VALUES(source_record_id),
                   last_operation=VALUES(last_operation), synced_at=UTC_TIMESTAMP(3)`,
                [row.record_type, row.record_key, JSON.stringify(row.payload ?? {}),
                 row.operation === 'DELETE', row.record_id, row.operation]
              )
            }
            await mysql.execute(`INSERT INTO pyroguard_dual_record_ledger (record_id,user_id,device_id,record_type,record_key,operation,source,payload,mysql_synced,mysql_synced_at,created_at) VALUES (?,?,?,?,?,?,?,?,TRUE,UTC_TIMESTAMP(3),?) ON DUPLICATE KEY UPDATE record_id=VALUES(record_id)`, [row.record_id,row.user_id,row.device_id,row.record_type,row.record_key,row.operation,row.source,JSON.stringify(row.payload ?? {}),dt(row.created_at)])
          } else if (kind === 'mirror') {
            await mysql.execute(`INSERT INTO pyroguard_mirror_records (user_id,device_id,record_type,record_key,payload,mysql_synced,mysql_synced_at,created_at,updated_at) VALUES (?,?,?,?,?,TRUE,UTC_TIMESTAMP(3),?,?) ON DUPLICATE KEY UPDATE device_id=VALUES(device_id),payload=VALUES(payload),mysql_synced=TRUE,mysql_synced_at=UTC_TIMESTAMP(3),updated_at=VALUES(updated_at)`,[row.user_id,row.device_id,row.record_type,row.record_key,JSON.stringify(row.payload ?? {}),dt(row.created_at),dt(row.updated_at)])
          } else {
            await mirrorAccount(sb,mysql,row.user_id)
            stats.identity++
            continue
          }
          const {error:markError} = await sb.from(table).update({mysql_synced:true,mysql_synced_at:new Date().toISOString(),last_sync_error:null}).eq(key,row[key]).eq('mysql_synced',false)
          if (markError) throw markError
          stats[kind]++
        } catch (e) {
          stats.failed++
          await sb.from(table).update({last_sync_error:String(e).slice(0,1000)}).eq(key,row[key]).eq('mysql_synced',false)
        }
      }
    }
    return Response.json({ok:stats.failed===0,...stats})
  } finally { await mysql.end() }
})
