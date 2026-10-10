import { createClient } from '@supabase/supabase-js'
import { createConnection, type Connection } from 'mysql2/promise'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type,x-bootstrap-key,authorization,apikey',
  'Access-Control-Allow-Methods': 'POST,OPTIONS',
}

const fixedAdmins = [
  { email: 'noelfajardoll9@gmail.com', name: 'Nowel · Head Developer', role: 'head_developer', order: 1, referenceCode: 'PG-NWL-84QF-29MX', secret: 'ADMIN_NOWEL_PASSWORD' },
  { email: 'benedict@pyroguard.local', name: 'Benedict A. Carungcong', role: 'administrator', order: 2, referenceCode: 'PG-BEN-61KD-73RV', secret: 'ADMIN_BENEDICT_PASSWORD' },
  { email: 'danahia@pyroguard.local', name: 'Ma. Danahia Meish R. Lubgoban', role: 'administrator', order: 3, referenceCode: 'PG-DAN-95TS-42HC', secret: 'ADMIN_DANAHIA_PASSWORD' },
  { email: 'christian@pyroguard.local', name: 'Christian Dave M. Sapata', role: 'administrator', order: 4, referenceCode: 'PG-CHR-38WP-57LJ', secret: 'ADMIN_CHRISTIAN_PASSWORD' },
]

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return new Response('POST only', { status: 405, headers: cors })

  const bootstrapKey = Deno.env.get('ADMIN_BOOTSTRAP_KEY') ?? ''
  if (!bootstrapKey || req.headers.get('x-bootstrap-key') !== bootstrapKey) {
    return new Response(JSON.stringify({ ok: false, error: 'Invalid bootstrap key' }), {
      status: 401, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }

  const url = Deno.env.get('SUPABASE_URL')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } })

  // The fixed registry exists in both databases. MySQL is optional during
  // bootstrap only so a temporary MySQL outage never prevents creation of the
  // Supabase Auth accounts; failures are reported in the response for retry.
  let mysql: Connection | null = null
  let mysqlInitError: string | null = null
  try {
    const host = Deno.env.get('MYSQL_HOST')?.trim()
    const user = Deno.env.get('MYSQL_USER')?.trim()
    const password = Deno.env.get('MYSQL_PASSWORD') ?? ''
    const database = Deno.env.get('MYSQL_DATABASE')?.trim()
    const port = Number(Deno.env.get('MYSQL_PORT') ?? '3306')
    if (host && user && database) {
      const sslEnabled = (Deno.env.get('MYSQL_SSL') ?? 'true').toLowerCase() !== 'false'
      mysql = await createConnection({
        host, user, password, database, port, connectTimeout: 8000,
        ssl: sslEnabled ? { rejectUnauthorized: true } : undefined,
      })
    } else {
      mysqlInitError = 'MySQL secrets are not fully configured; admin registry mirror skipped.'
    }
  } catch (e) {
    mysqlInitError = `MySQL admin-registry mirror unavailable: ${e}`
  }

  const results = []
  for (const item of fixedAdmins) {
    const password = Deno.env.get(item.secret) ?? ''
    const strong = /^(?=.*[a-z])(?=.*[A-Z])(?=.*[0-9])(?=.*[^A-Za-z0-9\s])\S{12,}$/.test(password)
    const rotateExisting = Deno.env.get('ADMIN_ROTATE_EXISTING_PASSWORDS') === 'true'

    const listed = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 })
    let user = listed.data.users.find((u) => (u.email ?? '').toLowerCase() === item.email.toLowerCase())

    if (!user) {
      if (!strong) {
        results.push({ email: item.email, ok: false, error: `Strong ${item.secret} required to create a missing administrator (12+ chars, upper/lower/digit/symbol, no spaces).` })
        continue
      }
      const created = await admin.auth.admin.createUser({
        email: item.email,
        password,
        email_confirm: true,
        user_metadata: { full_name: item.name, fixed_admin: true },
        app_metadata: { role: item.role, pyroguard_admin: true },
      })
      if (created.error || !created.data.user) {
        results.push({ email: item.email, ok: false, error: created.error?.message ?? 'Could not create admin.' })
        continue
      }
      user = created.data.user
    } else {
      if (rotateExisting && !strong) {
        results.push({ email: item.email, ok: false, error: `Strong ${item.secret} required for explicit password rotation.` })
        continue
      }
      const updated = await admin.auth.admin.updateUserById(user.id, {
        ...(rotateExisting ? { password } : {}),
        email_confirm: true,
        user_metadata: { ...(user.user_metadata ?? {}), full_name: item.name, fixed_admin: true },
        app_metadata: { ...(user.app_metadata ?? {}), role: item.role, pyroguard_admin: true },
      })
      if (updated.error) {
        results.push({ email: item.email, ok: false, error: updated.error.message })
        continue
      }
      user = updated.data.user
    }

    await admin.from('admin_accounts').upsert({
      admin_order: item.order,
      user_id: user.id,
      email: item.email,
      display_name: item.name,
      admin_role: item.role,
      admin_reference_code: item.referenceCode,
      active: true,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'email' })

    await admin.from('profiles').upsert({
      id: user.id,
      user_id: user.id,
      full_name: item.name,
      email: item.email,
      account_role: item.role,
      account_status: 'active',
      updated_at: new Date().toISOString(),
    }, { onConflict: 'id' })

    await admin.from('account_identities').upsert({
      user_id: user.id,
      email: item.email,
      display_name: item.name,
      account_role: item.role,
      auth_provider: 'email',
      email_confirmed: true,
      account_status: 'active',
      mysql_synced: false,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id' })

    const dualRecordId = crypto.randomUUID()
    const dualPayload = {
      user_id: user.id,
      email: item.email,
      display_name: item.name,
      admin_role: item.role,
      admin_reference_code: item.referenceCode,
      active: true,
    }
    await admin.from('dual_record_ledger').insert({
      record_id: dualRecordId,
      user_id: user.id,
      record_type: 'admin_account',
      record_key: item.email,
      operation: 'UPSERT',
      source: 'bootstrap-admins',
      payload: dualPayload,
      mysql_synced: false,
    })

    let mysqlMirrored = false
    let mysqlError: string | null = mysqlInitError
    if (mysql) {
      try {
        await mysql.execute(
          `INSERT INTO pyroguard_admin_accounts
            (admin_order,user_id,email,display_name,admin_role,admin_reference_code,active)
           VALUES (?,?,?,?,?,?,TRUE)
           ON DUPLICATE KEY UPDATE
             user_id=VALUES(user_id), display_name=VALUES(display_name),
             admin_role=VALUES(admin_role), admin_reference_code=VALUES(admin_reference_code),
             active=TRUE, updated_at=CURRENT_TIMESTAMP(3)`,
          [item.order, user.id, item.email, item.name, item.role, item.referenceCode],
        )
        const adminProfilePayload = {
          id: user.id,
          user_id: user.id,
          email: item.email,
          full_name: item.name,
          role: item.role,
          fixed_admin: true,
        }
        await mysql.execute(
          `INSERT INTO pyroguard_profiles
            (id,user_id,full_name,email,account_role,account_status,created_at,updated_at)
           VALUES (?,?,?,?,?,'active',CURRENT_TIMESTAMP(3),CURRENT_TIMESTAMP(3))
           ON DUPLICATE KEY UPDATE user_id=VALUES(user_id),full_name=VALUES(full_name),email=VALUES(email),
             account_role=VALUES(account_role),account_status='active',updated_at=CURRENT_TIMESTAMP(3)`,
          [user.id, user.id, item.name, item.email, item.role],
        )
        await mysql.execute(
          `INSERT INTO pyroguard_account_identities
            (user_id,email,display_name,account_role,auth_provider,email_confirmed,account_status,
             mysql_synced,mysql_synced_at,last_sync_error,created_at,updated_at)
           VALUES (?,?,?,?, 'email', TRUE, 'active', TRUE, CURRENT_TIMESTAMP(3), NULL, CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3))
           ON DUPLICATE KEY UPDATE
             email=VALUES(email), display_name=VALUES(display_name), account_role=VALUES(account_role),
             auth_provider='email', email_confirmed=TRUE, account_status='active',
             mysql_synced=TRUE,mysql_synced_at=CURRENT_TIMESTAMP(3),last_sync_error=NULL,
             updated_at=CURRENT_TIMESTAMP(3)`,
          [user.id, item.email, item.name, item.role],
        )
        await mysql.execute(
          `INSERT INTO pyroguard_mirror_records
            (user_id,record_type,record_key,payload,mysql_synced,mysql_synced_at,last_sync_error,created_at,updated_at)
           VALUES (?, 'profiles', ?, ?, TRUE, CURRENT_TIMESTAMP(3), NULL, CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3))
           ON DUPLICATE KEY UPDATE payload=VALUES(payload),mysql_synced=TRUE,
             mysql_synced_at=CURRENT_TIMESTAMP(3),last_sync_error=NULL,updated_at=CURRENT_TIMESTAMP(3)`,
          [user.id, user.id, JSON.stringify(adminProfilePayload)],
        )
        await mysql.execute(
          `INSERT INTO pyroguard_dual_record_ledger
            (record_id,user_id,record_type,record_key,operation,source,payload,mysql_synced,mysql_synced_at,last_sync_error,created_at)
           VALUES (?,?,?,?, 'UPSERT','bootstrap-admins',?,TRUE,CURRENT_TIMESTAMP(3),NULL,CURRENT_TIMESTAMP(3))
           ON DUPLICATE KEY UPDATE payload=VALUES(payload),mysql_synced=TRUE,
             mysql_synced_at=CURRENT_TIMESTAMP(3),last_sync_error=NULL`,
          [dualRecordId, user.id, 'admin_accounts', item.email, JSON.stringify(dualPayload)],
        )
        await admin.from('dual_record_ledger').update({
          mysql_synced: true,
          mysql_synced_at: new Date().toISOString(),
          last_sync_error: null,
        }).eq('record_id', dualRecordId)
        await admin.from('account_identities').update({
          mysql_synced: true,
          mysql_synced_at: new Date().toISOString(),
          last_sync_error: null,
        }).eq('user_id', user.id)
        mysqlMirrored = true
        mysqlError = null
      } catch (e) {
        mysqlError = `${e}`
        try {
          await admin.from('dual_record_ledger').update({
            mysql_synced: false,
            last_sync_error: mysqlError,
          }).eq('record_id', dualRecordId)
        } catch (_) {}
      }
    }

    results.push({
      email: item.email, ok: true, user_id: user.id, role: item.role,
      reference_code: item.referenceCode, mysql_mirrored: mysqlMirrored, mysql_error: mysqlError,
    })
  }

  if (mysql) {
    try { await mysql.end() } catch (_) {}
  }

  return new Response(JSON.stringify({ ok: results.every((r) => r.ok), results }), {
    status: 200, headers: { ...cors, 'Content-Type': 'application/json' },
  })
})
