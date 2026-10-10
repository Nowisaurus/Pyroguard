// Only non-secret registration metadata is copied. Never copy Auth tokens/hashes.
export const registrationKeys = ['full_name','phone_number','home_name','address','home_latitude','home_longitude','device_id','stakeholder_name','stakeholder_relationship','stakeholder_phone','bfp_station_name','bfp_personnel_name','bfp_rank_position','bfp_phone','bfp_address','safety_acknowledged','onboarding_completed'] as const
export function registrationData(raw: Record<string, unknown>) {
  return Object.fromEntries(registrationKeys.filter(key => raw[key] !== undefined).map(key => [key, raw[key]]))
}
export async function mirrorAccount(sb: any, mysql: any, userId: string) {
  const [{ data: auth, error: authError }, { data: profile, error: profileError }, { data: identity, error: identityError }, { data: admin, error: adminError }] = await Promise.all([
    sb.auth.admin.getUserById(userId),
    sb.from('profiles').select('*').eq('user_id', userId).maybeSingle(),
    sb.from('account_identities').select('*').eq('user_id', userId).maybeSingle(),
    sb.from('admin_accounts').select('*').eq('user_id', userId).maybeSingle(),
  ])
  const user = auth?.user
  if (authError || profileError || identityError || adminError || !user || !profile || !identity) throw new Error('Registration source records are incomplete; retry required.')
  if (profile.account_status !== 'active' || identity.account_status !== 'active' ||
      profile.account_role !== identity.account_role || user.email?.toLowerCase() !== String(identity.email).toLowerCase() ||
      String(profile.email).toLowerCase() !== String(identity.email).toLowerCase()) throw new Error('Account identity disagreement; manual reconciliation required.')
  if (admin) {
    if (!admin.active || admin.admin_role !== identity.account_role || String(admin.email).toLowerCase() !== String(identity.email).toLowerCase() || user.app_metadata?.role !== identity.account_role) throw new Error('Administrator registry disagreement.')
  } else if (identity.account_role !== 'homeowner') throw new Error('Unregistered administrator denied.')
  const registration = registrationData(user.user_metadata ?? {})
  const date = (value: unknown) => { const d = new Date(String(value)); return Number.isNaN(d.getTime()) ? new Date() : d }
  const version = identity.updated_at
  await mysql.beginTransaction()
  try {
    await mysql.execute(`INSERT INTO pyroguard_profiles (id,user_id,full_name,email,phone,account_role,account_status,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE full_name=VALUES(full_name),email=VALUES(email),phone=VALUES(phone),account_role=VALUES(account_role),account_status=VALUES(account_status),updated_at=VALUES(updated_at)`,
      [profile.id,userId,profile.full_name,profile.email,profile.phone,profile.account_role,profile.account_status,date(profile.created_at),date(profile.updated_at)])
    await mysql.execute(`INSERT INTO pyroguard_account_identities (user_id,email,display_name,phone,account_role,auth_provider,email_confirmed,account_status,mysql_synced,mysql_synced_at,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,TRUE,UTC_TIMESTAMP(3),?,?) ON DUPLICATE KEY UPDATE email=VALUES(email),display_name=VALUES(display_name),phone=VALUES(phone),account_role=VALUES(account_role),auth_provider=VALUES(auth_provider),email_confirmed=VALUES(email_confirmed),account_status=VALUES(account_status),mysql_synced=TRUE,mysql_synced_at=UTC_TIMESTAMP(3),updated_at=VALUES(updated_at)`,
      [userId,identity.email,identity.display_name,identity.phone,identity.account_role,identity.auth_provider,Boolean(identity.email_confirmed),identity.account_status,date(identity.created_at),date(identity.updated_at)])
    await mysql.execute(`INSERT INTO pyroguard_mirror_records (user_id,device_id,record_type,record_key,payload,mysql_synced,mysql_synced_at,created_at,updated_at)
      VALUES (?,?,'registration_snapshot',?,?,TRUE,UTC_TIMESTAMP(3),?,?) ON DUPLICATE KEY UPDATE device_id=VALUES(device_id),payload=VALUES(payload),mysql_synced=TRUE,mysql_synced_at=UTC_TIMESTAMP(3),updated_at=VALUES(updated_at)`,
      [userId,registration.device_id ?? null,userId,JSON.stringify(registration),date(identity.created_at),date(identity.updated_at)])
    await mysql.commit()
  } catch (e) { await mysql.rollback(); throw e }
  // A concurrent source change must stay pending; never mark newer data saved.
  const { data: marked, error: markError } = await sb.from('account_identities').update({mysql_synced:true,mysql_synced_at:new Date().toISOString(),last_sync_error:null})
    .eq('user_id',userId).eq('updated_at',version).select('user_id')
  if (markError || !marked?.length) throw new Error('Account changed during mirror; retry required.')
  return {user_id:userId,dual_saved:true}
}
