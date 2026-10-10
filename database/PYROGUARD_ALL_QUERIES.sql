-- PYROGUARD — ALL CURRENT DATABASE QUERIES
-- This file contains TWO database dialects. Do not execute the whole file at once.
-- Run SECTION 1 only in the Supabase SQL Editor.
-- Run SECTION 2 only in MySQL Workbench.
-- Back up existing databases first. No reset or sample-data inserts are included.

-- ==================== SECTION 1: SUPABASE / POSTGRESQL BEGIN ====================
-- PYROGUARD CURRENT SUPABASE REPAIR / SETUP — 2026-10-10

-- Run in Supabase SQL Editor. Copy the complete file, including final COMMIT.

-- Adds missing tables only; existing application tables/records/policies stay intact.

-- No reset, Auth account deletion, seeded users or fabricated measurements.

BEGIN;

CREATE TEMP TABLE pyroguard_new_tables(name text PRIMARY KEY) ON COMMIT DROP;

DO $create_missing$
BEGIN
  IF to_regclass('public.admin_accounts') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.admin_accounts (
  id bigint generated always as identity primary key,
  admin_order smallint not null unique check (admin_order between 1 and 4),
  user_id uuid unique references auth.users(id) on delete set null,
  email text not null unique,
  display_name text not null,
  admin_role text not null check (admin_role in ('head_developer','administrator')),
  admin_reference_code text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.admin_accounts ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.admin_accounts FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.admin_accounts TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('admin_accounts');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.profiles') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  account_role text not null default 'homeowner'
    check (account_role in ('homeowner','administrator','head_developer')),
  account_status text not null default 'active'
    check (account_status in ('active','disabled','locked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.profiles FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.profiles TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('profiles');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.account_identities') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.account_identities (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text unique,
  display_name text,
  phone text,
  account_role text not null default 'homeowner'
    check (account_role in ('homeowner','administrator','head_developer')),
  auth_provider text not null default 'email',
  email_confirmed boolean not null default false,
  account_status text not null default 'active'
    check (account_status in ('active','disabled','locked')),
  last_login_at timestamptz,
  last_logout_at timestamptz,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.account_identities ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.account_identities FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.account_identities TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('account_identities');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.homes') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.homes (
  id bigint generated always as identity primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  home_name text not null default 'My Home',
  address text,
  barangay text,
  city text,
  latitude double precision,
  longitude double precision,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.homes ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.homes FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.homes TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('homes');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.stakeholders') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.stakeholders (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  full_name text not null,
  relationship text,
  phone text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    create unique index stakeholders_one_primary_per_user on public.stakeholders(user_id) where is_primary;
    ALTER TABLE public.stakeholders ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.stakeholders FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.stakeholders TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('stakeholders');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.emergency_contacts') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.emergency_contacts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  contact_type text not null default 'BFP',
  name text,
  station_name text,
  personnel_name text,
  rank_position text,
  phone text,
  address text,
  is_primary boolean not null default false,
  is_confirmed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    create unique index emergency_contacts_one_primary_per_user on public.emergency_contacts(user_id) where is_primary;
    ALTER TABLE public.emergency_contacts ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.emergency_contacts FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.emergency_contacts TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('emergency_contacts');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.safety_setups') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.safety_setups (
  id bigint generated always as identity primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  safety_acknowledged boolean not null default false,
  entry_delay_seconds integer not null default 30 check (entry_delay_seconds between 0 and 600),
  siren_duration_seconds integer not null default 120 check (siren_duration_seconds between 10 and 3600),
  ai_assist_enabled boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.safety_setups ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.safety_setups FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.safety_setups TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('safety_setups');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.user_preferences') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.user_preferences (
  id bigint generated always as identity primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  notifications_enabled boolean not null default true,
  push_notifications boolean not null default true,
  email_alerts boolean not null default true,
  sms_alerts boolean not null default false,
  dark_mode boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.user_preferences ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.user_preferences FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.user_preferences TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('user_preferences');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.devices') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.devices (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null unique,
  device_name text not null default 'Main PyroGuard Controller',
  device_type text not null default 'ESP32_MAIN',
  status text not null default 'registered',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    create index devices_user_idx on public.devices(user_id);
    ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.devices FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.devices TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('devices');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.device_current_state') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.device_current_state (
  id bigint generated always as identity primary key,
  device_id text not null unique,
  temperature numeric,
  humidity numeric,
  smoke_raw integer,
  smoke_level numeric,
  smoke_status text,
  flame_detected boolean default false,
  alert_status text,
  incident_type text,
  severity_level integer default 0,
  location text,
  device_lat numeric,
  device_lng numeric,
  door_status text,
  window_status text,
  motion_detected boolean,
  system_armed boolean default false,
  system_mode text default 'DISARMED',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.device_current_state ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.device_current_state FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.device_current_state TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('device_current_state');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.device_heartbeats') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.device_heartbeats (
  id bigint generated always as identity primary key,
  device_id text not null unique,
  wifi_ok boolean not null default false,
  supabase_ok boolean not null default false,
  camera_ok boolean not null default false,
  ptz_ok boolean not null default false,
  mic_ok boolean not null default false,
  speaker_ok boolean not null default false,
  pir_ok boolean not null default false,
  door_ok boolean not null default false,
  window_ok boolean not null default false,
  ultrasonic_ok boolean not null default false,
  mq2_ok boolean not null default false,
  flame_ok boolean not null default false,
  dht22_ok boolean not null default false,
  gps_ok boolean not null default false,
  gsm_ok boolean not null default false,
  siren_ok boolean not null default false,
  uptime_secs bigint,
  battery_pct numeric,
  local_ip text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.device_heartbeats ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.device_heartbeats FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.device_heartbeats TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('device_heartbeats');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.pyroguard_camera_telemetry') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.pyroguard_camera_telemetry (
  id bigint generated always as identity primary key,
  device_id text not null,
  camera_device_id text not null unique default 'pyroguard_camera_001',
  camera_ip text,
  status text not null default 'offline',
  motion_detected boolean not null default false,
  motion_pixels integer not null default 0,
  pan_angle integer not null default 90,
  tilt_angle integer not null default 90,
  wifi_rssi integer,
  uptime_ms bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.pyroguard_camera_telemetry ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.pyroguard_camera_telemetry FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.pyroguard_camera_telemetry TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('pyroguard_camera_telemetry');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.system_state') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.system_state (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null unique,
  arm_mode text not null default 'DISARMED'
    check (arm_mode in ('DISARMED','ARM_HOME','ARM_AWAY')),
  door_enabled boolean not null default true,
  window_enabled boolean not null default true,
  motion_enabled boolean not null default true,
  acting_user uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.system_state ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.system_state FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.system_state TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('system_state');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.device_commands') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.device_commands (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  target_device_id text not null,
  command text not null,
  payload jsonb not null default '{}'::jsonb,
  requested_by uuid references auth.users(id),
  status text not null default 'pending'
    check (status in ('pending','processing','applied','failed','expired')),
  result_message text,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);$definition$;
    create index device_commands_pending_idx on public.device_commands(target_device_id,status,created_at);
    ALTER TABLE public.device_commands ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.device_commands FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.device_commands TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('device_commands');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.ptz_state') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.ptz_state (
  id bigint generated always as identity primary key,
  device_id text not null unique,
  pan_position numeric not null default 90,
  tilt_position numeric not null default 90,
  moving boolean not null default false,
  auto_tracking boolean not null default false,
  -- Legacy aliases retained for older camera/diagnostic code.
  pan_angle integer not null default 90,
  tilt_angle integer not null default 90,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.ptz_state ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.ptz_state FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.ptz_state TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('ptz_state');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.ptz_commands') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.ptz_commands (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text not null,
  pan numeric not null default 0,
  tilt numeric not null default 0,
  speed numeric not null default 0,
  mode text not null default 'manual',
  preset_name text,
  -- Legacy command/value columns remain optional for compatibility.
  command text,
  value integer,
  status text not null default 'created'
    check (status in ('created','processing','executed','failed','expired')),
  created_at timestamptz not null default now(),
  applied_at timestamptz
);$definition$;
    
    ALTER TABLE public.ptz_commands ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.ptz_commands FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.ptz_commands TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('ptz_commands');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.sensor_history') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.sensor_history (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text not null,
  temperature numeric,
  humidity numeric,
  smoke_raw integer,
  smoke_level numeric,
  smoke_status text,
  flame_detected boolean,
  door_status text,
  window_status text,
  motion_detected boolean,
  system_armed boolean,
  system_mode text,
  incident_type text,
  severity_level integer default 0,
  alert_status text,
  location text,
  device_lat numeric,
  device_lng numeric,
  payload_json jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now()
);$definition$;
    create index sensor_history_user_time on public.sensor_history(user_id,created_at desc);
create index sensor_history_device_time on public.sensor_history(device_id,created_at desc);
    ALTER TABLE public.sensor_history ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.sensor_history FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.sensor_history TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('sensor_history');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.event_history') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.event_history (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text,
  event_type text not null,
  sensor_name text,
  location text,
  event_status text,
  image_url text,
  acting_user_name text,
  message text,
  severity integer not null default 0,
  payload_json jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now()
);$definition$;
    create index event_history_user_time on public.event_history(user_id,created_at desc);
create index event_history_device_time on public.event_history(device_id,created_at desc);
    ALTER TABLE public.event_history ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.event_history FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.event_history TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('event_history');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.camera_history') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.camera_history (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text,
  event_type text not null,
  image_url text,
  metadata_json jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now()
);$definition$;
    create index camera_history_user_time on public.camera_history(user_id,created_at desc);
    ALTER TABLE public.camera_history ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.camera_history FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.camera_history TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('camera_history');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.camera_events') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.camera_events (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text not null,
  record_key text not null unique,
  event_type text not null default 'camera_event',
  snapshot_url text,
  pan_at_capture numeric,
  tilt_at_capture numeric,
  payload_json jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now()
);$definition$;
    create index camera_events_user_time on public.camera_events(user_id,created_at desc);
create index camera_events_device_time on public.camera_events(device_id,created_at desc);
    ALTER TABLE public.camera_events ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.camera_events FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.camera_events TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('camera_events');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.audio_sessions') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.audio_sessions (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text not null,
  record_key text not null unique,
  direction text not null default 'from_device',
  clip_url text,
  metadata_json jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now()
);$definition$;
    create index audio_sessions_user_time on public.audio_sessions(user_id,created_at desc);
create index audio_sessions_device_time on public.audio_sessions(device_id,created_at desc);
    ALTER TABLE public.audio_sessions ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.audio_sessions FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.audio_sessions TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('audio_sessions');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.mirror_records') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.mirror_records (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text,
  record_type text not null,
  record_key text not null,
  payload jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id,record_type,record_key)
);$definition$;
    
    ALTER TABLE public.mirror_records ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.mirror_records FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.mirror_records TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('mirror_records');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.dual_record_ledger') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.dual_record_ledger (
  id bigint generated always as identity primary key,
  record_id uuid not null default gen_random_uuid() unique,
  user_id uuid references auth.users(id) on delete set null,
  device_id text,
  record_type text not null,
  record_key text not null,
  operation text not null default 'UPSERT' check (operation in ('INSERT','UPDATE','UPSERT','DELETE','ACTION','SNAPSHOT')),
  source text not null default 'flutter',
  payload jsonb not null default '{}'::jsonb,
  mysql_synced boolean not null default false,
  mysql_synced_at timestamptz,
  last_sync_error text,
  created_at timestamptz not null default now()
);$definition$;
    create index dual_record_ledger_user_time_idx on public.dual_record_ledger(user_id, created_at desc);
create index dual_record_ledger_type_time_idx on public.dual_record_ledger(record_type, created_at desc);
create index dual_record_ledger_sync_idx on public.dual_record_ledger(mysql_synced, created_at);
    ALTER TABLE public.dual_record_ledger ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.dual_record_ledger FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.dual_record_ledger TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('dual_record_ledger');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.emergency_action_logs') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.emergency_action_logs (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  device_id text,
  event_type text not null,
  severity text,
  message text,
  bfp_station text,
  bfp_personnel text,
  bfp_phone text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.emergency_action_logs ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.emergency_action_logs FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.emergency_action_logs TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('emergency_action_logs');
  END IF;
END;
$create_missing$;

DO $create_missing$
BEGIN
  IF to_regclass('public.sensor_readings') IS NULL THEN
    EXECUTE $definition$CREATE TABLE public.sensor_readings (
  id bigint generated always as identity primary key,
  device_id text not null,
  temperature numeric,
  humidity numeric,
  smoke_raw integer,
  smoke_level numeric,
  smoke_status text,
  flame_detected boolean default false,
  alert_status text,
  incident_type text,
  severity_level integer default 0,
  location text,
  device_lat numeric,
  device_lng numeric,
  door_status text,
  window_status text,
  motion_detected boolean,
  system_armed boolean,
  created_at timestamptz not null default now()
);$definition$;
    
    ALTER TABLE public.sensor_readings ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.sensor_readings FROM PUBLIC, anon, authenticated;
    GRANT ALL ON public.sensor_readings TO service_role;
    -- Tag tables created by this transaction only; existing policies are preserved.
    INSERT INTO pyroguard_new_tables(name) VALUES ('sensor_readings');
  END IF;
END;
$create_missing$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='admin_accounts') THEN
    GRANT SELECT ON public.admin_accounts TO authenticated;
    CREATE POLICY pyroguard_registry_self ON public.admin_accounts FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
    seq := pg_get_serial_sequence('public.admin_accounts','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='profiles') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.profiles TO authenticated;
    CREATE POLICY pyroguard_owner ON public.profiles FOR ALL TO authenticated USING ((id = (SELECT auth.uid()) AND user_id = (SELECT auth.uid())) AND account_role = 'homeowner' AND account_status = 'active') WITH CHECK ((id = (SELECT auth.uid()) AND user_id = (SELECT auth.uid())) AND account_role = 'homeowner' AND account_status = 'active');
    CREATE POLICY pyroguard_admin_read ON public.profiles FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.profiles','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='account_identities') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.account_identities TO authenticated;
    CREATE POLICY pyroguard_owner ON public.account_identities FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid())) AND account_role = 'homeowner' AND account_status = 'active') WITH CHECK ((user_id = (SELECT auth.uid())) AND account_role = 'homeowner' AND account_status = 'active');
    CREATE POLICY pyroguard_admin_read ON public.account_identities FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.account_identities','user_id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='homes') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.homes TO authenticated;
    CREATE POLICY pyroguard_owner ON public.homes FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.homes FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.homes','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='stakeholders') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.stakeholders TO authenticated;
    CREATE POLICY pyroguard_owner ON public.stakeholders FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.stakeholders FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.stakeholders','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='emergency_contacts') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.emergency_contacts TO authenticated;
    CREATE POLICY pyroguard_owner ON public.emergency_contacts FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.emergency_contacts FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.emergency_contacts','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='safety_setups') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.safety_setups TO authenticated;
    CREATE POLICY pyroguard_owner ON public.safety_setups FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.safety_setups FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.safety_setups','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='user_preferences') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.user_preferences TO authenticated;
    CREATE POLICY pyroguard_owner ON public.user_preferences FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.user_preferences FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.user_preferences','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='devices') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.devices TO authenticated;
    CREATE POLICY pyroguard_owner ON public.devices FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = devices.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = devices.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.devices FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.devices','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='device_current_state') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.device_current_state TO authenticated;
    CREATE POLICY pyroguard_owner ON public.device_current_state FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = device_current_state.device_id AND d.user_id = (SELECT auth.uid()))) WITH CHECK (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = device_current_state.device_id AND d.user_id = (SELECT auth.uid())));
    CREATE POLICY pyroguard_admin_read ON public.device_current_state FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.device_current_state','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='device_heartbeats') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.device_heartbeats TO authenticated;
    CREATE POLICY pyroguard_owner ON public.device_heartbeats FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = device_heartbeats.device_id AND d.user_id = (SELECT auth.uid()))) WITH CHECK (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = device_heartbeats.device_id AND d.user_id = (SELECT auth.uid())));
    CREATE POLICY pyroguard_admin_read ON public.device_heartbeats FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.device_heartbeats','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='pyroguard_camera_telemetry') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.pyroguard_camera_telemetry TO authenticated;
    CREATE POLICY pyroguard_owner ON public.pyroguard_camera_telemetry FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = pyroguard_camera_telemetry.device_id AND d.user_id = (SELECT auth.uid()))) WITH CHECK (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = pyroguard_camera_telemetry.device_id AND d.user_id = (SELECT auth.uid())));
    CREATE POLICY pyroguard_admin_read ON public.pyroguard_camera_telemetry FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.pyroguard_camera_telemetry','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='system_state') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.system_state TO authenticated;
    CREATE POLICY pyroguard_owner ON public.system_state FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = system_state.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = system_state.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.system_state FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.system_state','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='device_commands') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.device_commands TO authenticated;
    CREATE POLICY pyroguard_owner ON public.device_commands FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.device_commands FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.device_commands','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='ptz_state') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.ptz_state TO authenticated;
    CREATE POLICY pyroguard_owner ON public.ptz_state FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = ptz_state.device_id AND d.user_id = (SELECT auth.uid()))) WITH CHECK (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = ptz_state.device_id AND d.user_id = (SELECT auth.uid())));
    CREATE POLICY pyroguard_admin_read ON public.ptz_state FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.ptz_state','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='ptz_commands') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.ptz_commands TO authenticated;
    CREATE POLICY pyroguard_owner ON public.ptz_commands FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = ptz_commands.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = ptz_commands.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.ptz_commands FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.ptz_commands','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='sensor_history') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.sensor_history TO authenticated;
    CREATE POLICY pyroguard_owner ON public.sensor_history FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = sensor_history.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = sensor_history.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.sensor_history FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.sensor_history','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='event_history') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.event_history TO authenticated;
    CREATE POLICY pyroguard_owner ON public.event_history FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = event_history.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = event_history.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.event_history FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.event_history','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='camera_history') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.camera_history TO authenticated;
    CREATE POLICY pyroguard_owner ON public.camera_history FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = camera_history.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = camera_history.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.camera_history FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.camera_history','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='camera_events') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.camera_events TO authenticated;
    CREATE POLICY pyroguard_owner ON public.camera_events FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = camera_events.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = camera_events.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.camera_events FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.camera_events','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='audio_sessions') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.audio_sessions TO authenticated;
    CREATE POLICY pyroguard_owner ON public.audio_sessions FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = audio_sessions.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = audio_sessions.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.audio_sessions FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.audio_sessions','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='mirror_records') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.mirror_records TO authenticated;
    CREATE POLICY pyroguard_owner ON public.mirror_records FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.mirror_records FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.mirror_records','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='dual_record_ledger') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.dual_record_ledger TO authenticated;
    CREATE POLICY pyroguard_owner ON public.dual_record_ledger FOR ALL TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
    CREATE POLICY pyroguard_admin_read ON public.dual_record_ledger FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.dual_record_ledger','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='emergency_action_logs') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.emergency_action_logs TO authenticated;
    CREATE POLICY pyroguard_owner ON public.emergency_action_logs FOR ALL TO authenticated USING ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = emergency_action_logs.device_id AND d.user_id = (SELECT auth.uid()))))) WITH CHECK ((user_id = (SELECT auth.uid()) OR (user_id IS NULL AND EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = emergency_action_logs.device_id AND d.user_id = (SELECT auth.uid())))));
    CREATE POLICY pyroguard_admin_read ON public.emergency_action_logs FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.emergency_action_logs','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

DO $new_permissions$
DECLARE seq text;
BEGIN
  IF EXISTS (SELECT 1 FROM pyroguard_new_tables WHERE name='sensor_readings') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON public.sensor_readings TO authenticated;
    CREATE POLICY pyroguard_owner ON public.sensor_readings FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = sensor_readings.device_id AND d.user_id = (SELECT auth.uid()))) WITH CHECK (EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = sensor_readings.device_id AND d.user_id = (SELECT auth.uid())));
    CREATE POLICY pyroguard_admin_read ON public.sensor_readings FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = (SELECT auth.uid()) AND a.active = true AND a.admin_role IN ('administrator','head_developer')));
    seq := pg_get_serial_sequence('public.sensor_readings','id');
    IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated,service_role',seq); END IF;
  END IF;
END;
$new_permissions$;

ALTER TABLE public.account_identities ADD COLUMN IF NOT EXISTS event text;
ALTER TABLE public.account_identities ADD COLUMN IF NOT EXISTS logged_in_at timestamptz;
ALTER TABLE public.account_identities ADD COLUMN IF NOT EXISTS logged_out_at timestamptz;

CREATE OR REPLACE FUNCTION public.pyroguard_capture_source_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  body jsonb;
  old_body jsonb;
  key_text text;
  device_text text;
  owner_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    body := to_jsonb(OLD);
  ELSE
    body := to_jsonb(NEW);
  END IF;
  old_body := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE NULL END;
  -- Do not enqueue changes to synchronization status fields themselves.
  IF TG_OP = 'UPDATE' AND old_body IS NOT NULL AND
     (body - 'mysql_synced' - 'mysql_synced_at' - 'last_sync_error') =
     (old_body - 'mysql_synced' - 'mysql_synced_at' - 'last_sync_error') THEN
    RETURN NEW;
  END IF;
  key_text := COALESCE(body->>'id', body->>'device_id', body->>'camera_device_id',
                       body->>'user_id', body->>'session_id', body->>'command_id');
  -- Tables without a stable key get unique append-only events.
  IF key_text IS NULL OR key_text = '' THEN
    key_text := pg_catalog.gen_random_uuid()::text;
  END IF;
  device_text := COALESCE(body->>'device_id', body->>'camera_device_id');
  BEGIN
    owner_id := NULLIF(body->>'user_id', '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    owner_id := NULL;
  END;
  INSERT INTO public.dual_record_ledger
    (record_id, user_id, device_id, record_type, record_key, operation, source, payload, mysql_synced)
  VALUES
    (pg_catalog.gen_random_uuid(), owner_id, device_text, TG_TABLE_NAME, key_text,
     TG_OP, 'supabase_table_trigger', body, false);
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION public.pyroguard_capture_source_change() FROM PUBLIC, anon, authenticated;

DO $capture_triggers$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['admin_accounts','profiles','account_identities','homes','stakeholders','emergency_contacts','safety_setups','user_preferences','devices','device_current_state','device_heartbeats','pyroguard_camera_telemetry','system_state','device_commands','ptz_state','ptz_commands','sensor_history','event_history','camera_history','camera_events','audio_sessions','emergency_action_logs','sensor_readings'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS pyroguard_parity_v5 ON public.%I',t);
    EXECUTE format('CREATE TRIGGER pyroguard_parity_v5 AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.pyroguard_capture_source_change()',t);
  END LOOP;
END;
$capture_triggers$;

CREATE TABLE IF NOT EXISTS public.pyroguard_local_sync_status (
  worker_id text PRIMARY KEY CHECK (worker_id = 'local-pc'),
  heartbeat_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  mysql_connected boolean NOT NULL DEFAULT false,
  report jsonb NOT NULL DEFAULT '{}'::jsonb,
  requested_at timestamptz,
  acknowledged_at timestamptz
);
ALTER TABLE public.pyroguard_local_sync_status ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_local_sync_status FROM PUBLIC, anon, authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.pyroguard_local_sync_status TO service_role;

create or replace function public.pyroguard_verified_role(check_uid uuid default auth.uid())
returns text language sql stable security definer set search_path = '' as $$
  select case
    when check_uid is null or check_uid <> auth.uid() or (u.banned_until is not null and u.banned_until > now()) then 'denied'
    when a.user_id is not null and a.active = true
         and lower(a.email) = lower(u.email)
         and p.account_role = a.admin_role and i.account_role = a.admin_role
         and p.account_status = 'active' and i.account_status = 'active' then 'administrator'
    when a.user_id is null and p.account_role = 'homeowner'
         and i.account_role = 'homeowner'
         and p.account_status = 'active' and i.account_status = 'active'
         and not (coalesce(u.raw_app_meta_data ->> 'pyroguard_admin','false')='true'
                  or coalesce(u.raw_app_meta_data ->> 'role','') in ('administrator','head_developer')) then 'homeowner'
    else 'denied' end
  from auth.users u
  left join public.profiles p on p.user_id=u.id and lower(p.email)=lower(u.email)
  left join public.account_identities i on i.user_id=u.id and lower(i.email)=lower(u.email)
  left join public.admin_accounts a on a.user_id=u.id
  where u.id=check_uid;
$$;
revoke all on function public.pyroguard_verified_role(uuid) from public;
grant execute on function public.pyroguard_verified_role(uuid) to authenticated;

create table if not exists public.pyroguard_sync_health (
  component text primary key,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text,
  updated_at timestamptz not null default now()
);
revoke all on public.pyroguard_sync_health from anon, authenticated;
-- Allow members to determine their role via one server-side function only.
-- Caller cannot request another user's role even by supplying a different UUID.
create or replace function public.pyroguard_my_role()
returns text language sql stable security definer set search_path = '' as $$
  select public.pyroguard_verified_role(auth.uid());
$$;
revoke all on function public.pyroguard_my_role() from public, anon;
grant execute on function public.pyroguard_my_role() to authenticated;

-- Server registration/worker access must cover existing tables as well as new ones.
DO $$ DECLARE tab text; seq text; BEGIN
FOREACH tab IN ARRAY ARRAY['admin_accounts','profiles','account_identities','homes','stakeholders','emergency_contacts','safety_setups','user_preferences','devices','device_current_state','device_heartbeats','pyroguard_camera_telemetry','system_state','device_commands','ptz_state','ptz_commands','sensor_history','event_history','camera_history','camera_events','audio_sessions','mirror_records','dual_record_ledger','emergency_action_logs','sensor_readings'] LOOP
  EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.%I TO service_role',tab);
  seq:=pg_get_serial_sequence('public.'||tab,'id');
  IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO service_role',seq); END IF;
END LOOP; END; $$;

-- Session identity repair: the caller supplies only an event, never a role,
-- status, target user or email. Identity comes from the authenticated account.
CREATE OR REPLACE FUNCTION public.pyroguard_save_session(session_event text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  uid uuid := auth.uid();
  u auth.users%ROWTYPE;
  a public.admin_accounts%ROWTYPE;
  role_name text;
  now_at timestamptz := now();
  result jsonb;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF session_event IS NOT NULL AND session_event NOT IN ('homeowner_login','homeowner_logout','admin_login','admin_logout') THEN RAISE EXCEPTION 'Invalid session event'; END IF;
  SELECT * INTO u FROM auth.users WHERE id=uid;
  IF u.id IS NULL OR (u.banned_until IS NOT NULL AND u.banned_until>now_at) THEN RAISE EXCEPTION 'Account unavailable'; END IF;
  SELECT * INTO a FROM public.admin_accounts WHERE user_id=uid;
  IF a.user_id IS NOT NULL THEN
    IF NOT a.active OR lower(a.email)<>lower(u.email) OR a.admin_role NOT IN ('administrator','head_developer') THEN RAISE EXCEPTION 'Administrator registry mismatch'; END IF;
    role_name := a.admin_role;
  ELSE
    IF coalesce(u.raw_app_meta_data->>'role','') IN ('administrator','head_developer') OR coalesce(u.raw_app_meta_data->>'pyroguard_admin','false')='true' THEN RAISE EXCEPTION 'Administrator registry required'; END IF;
    role_name := 'homeowner';
  END IF;
  IF role_name='homeowner' AND (u.email_confirmed_at IS NULL OR (coalesce(u.raw_app_meta_data->>'provider','email')='email' AND u.confirmation_sent_at IS NULL)) THEN RAISE EXCEPTION 'Confirm your email before completing registration'; END IF;
  IF session_event IS NOT NULL AND ((role_name='homeowner' AND session_event LIKE 'admin_%') OR (role_name<>'homeowner' AND session_event LIKE 'homeowner_%')) THEN RAISE EXCEPTION 'Session role mismatch'; END IF;
  IF EXISTS(SELECT 1 FROM public.profiles WHERE user_id=uid AND (account_status<>'active' OR account_role<>role_name)) OR EXISTS(SELECT 1 FROM public.account_identities WHERE user_id=uid AND (account_status<>'active' OR account_role<>role_name)) THEN RAISE EXCEPTION 'Account role/status requires administrator repair'; END IF;
  INSERT INTO public.profiles(id,user_id,email,full_name,phone,account_role,account_status,created_at,updated_at)
  VALUES(uid,uid,u.email,coalesce(a.display_name,u.raw_user_meta_data->>'full_name',u.raw_user_meta_data->>'name'),u.raw_user_meta_data->>'phone_number',role_name,'active',u.created_at,now_at)
  ON CONFLICT(user_id) DO NOTHING;
  INSERT INTO public.account_identities(user_id,email,display_name,phone,account_role,account_status,auth_provider,email_confirmed,event,logged_in_at,logged_out_at,mysql_synced,created_at,updated_at)
  VALUES(uid,u.email,coalesce(a.display_name,u.raw_user_meta_data->>'full_name',u.raw_user_meta_data->>'name'),u.raw_user_meta_data->>'phone_number',role_name,'active',coalesce(u.raw_app_meta_data->>'provider','email'),u.email_confirmed_at IS NOT NULL,session_event,CASE WHEN session_event LIKE '%_login' THEN now_at END,CASE WHEN session_event LIKE '%_logout' THEN now_at END,false,u.created_at,now_at)
  ON CONFLICT(user_id) DO UPDATE SET
    email=EXCLUDED.email,email_confirmed=EXCLUDED.email_confirmed,
    event=coalesce(EXCLUDED.event,public.account_identities.event),
    logged_in_at=coalesce(EXCLUDED.logged_in_at,public.account_identities.logged_in_at),
    logged_out_at=coalesce(EXCLUDED.logged_out_at,public.account_identities.logged_out_at),
    mysql_synced=false,updated_at=now_at;
  SELECT to_jsonb(i) INTO result FROM public.account_identities i WHERE i.user_id=uid;
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.pyroguard_save_session(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pyroguard_save_session(text) TO authenticated;

-- Add narrowly scoped compatibility policies to existing schemas. Existing
-- policies are retained; no global grants to auth.users or RLS disabling.
GRANT SELECT,INSERT,UPDATE ON public.profiles,public.account_identities,public.mirror_records,public.dual_record_ledger TO authenticated;
DROP POLICY IF EXISTS pyroguard_profile_compat ON public.profiles;
CREATE POLICY pyroguard_profile_compat ON public.profiles FOR ALL TO authenticated
USING(user_id=auth.uid() AND public.pyroguard_verified_role()='homeowner')
WITH CHECK(user_id=auth.uid() AND public.pyroguard_verified_role()='homeowner' AND account_role='homeowner' AND account_status='active');
DROP POLICY IF EXISTS pyroguard_identity_read_compat ON public.account_identities;
CREATE POLICY pyroguard_identity_read_compat ON public.account_identities FOR SELECT TO authenticated USING(user_id=auth.uid());
DROP POLICY IF EXISTS pyroguard_mirror_compat ON public.mirror_records;
CREATE POLICY pyroguard_mirror_compat ON public.mirror_records FOR ALL TO authenticated
USING(user_id=auth.uid() AND public.pyroguard_verified_role() IN ('homeowner','administrator'))
WITH CHECK(user_id=auth.uid() AND public.pyroguard_verified_role() IN ('homeowner','administrator'));
DROP POLICY IF EXISTS pyroguard_ledger_compat ON public.dual_record_ledger;
CREATE POLICY pyroguard_ledger_compat ON public.dual_record_ledger FOR ALL TO authenticated
USING(user_id=auth.uid() AND public.pyroguard_verified_role() IN ('homeowner','administrator'))
WITH CHECK(user_id=auth.uid() AND public.pyroguard_verified_role() IN ('homeowner','administrator'));
DO $$ DECLARE tab text; seq text; BEGIN
FOREACH tab IN ARRAY ARRAY['mirror_records','dual_record_ledger'] LOOP
  seq:=pg_get_serial_sequence('public.'||tab,'id');
  IF seq IS NOT NULL THEN EXECUTE format('GRANT USAGE,SELECT ON SEQUENCE %s TO authenticated',seq); END IF;
END LOOP; END; $$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- READ-ONLY: verify required source-table presence.

SELECT required.name AS table_name,CASE WHEN to_regclass('public.'||required.name) IS NULL THEN 'MISSING' ELSE 'EXISTS' END AS status
FROM unnest(ARRAY['admin_accounts','profiles','account_identities','homes','stakeholders','emergency_contacts','safety_setups','user_preferences','devices','device_current_state','device_heartbeats','pyroguard_camera_telemetry','system_state','device_commands','ptz_state','ptz_commands','sensor_history','event_history','camera_history','camera_events','audio_sessions','mirror_records','dual_record_ledger','emergency_action_logs','sensor_readings']) AS required(name) ORDER BY required.name;

SELECT heartbeat_at,started_at,completed_at,mysql_connected,requested_at,acknowledged_at,report
FROM public.pyroguard_local_sync_status WHERE worker_id='local-pc';

-- ==================== SECTION 1: SUPABASE / POSTGRESQL END ====================

-- ==================== SECTION 2: MYSQL BEGIN ====================
-- PYROGUARD CURRENT MYSQL SETUP — 2026-10-10

-- Run in MySQL Workbench. For an existing main-laptop DB, restore your real backup first.

-- No reset, seeded administrators or fake records. Existing tables are not replaced.

-- If your schema has another name, change the TWO pyroguard_db references below.

CREATE DATABASE IF NOT EXISTS pyroguard_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE pyroguard_db;

CREATE TABLE IF NOT EXISTS pyroguard_admin_accounts (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  admin_order SMALLINT NOT NULL,
  user_id CHAR(36),
  email VARCHAR(255) NOT NULL,
  display_name VARCHAR(180) NOT NULL,
  admin_role VARCHAR(40) NOT NULL,
  admin_reference_code VARCHAR(40) NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_order(admin_order),
  UNIQUE KEY uq_email(email),
  UNIQUE KEY uq_ref(admin_reference_code),
  UNIQUE KEY uq_user(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_profiles (
  id CHAR(36) NOT NULL PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  full_name TEXT,
  email VARCHAR(255),
  phone VARCHAR(80),
  account_role VARCHAR(40) NOT NULL DEFAULT 'homeowner',
  account_status VARCHAR(30) NOT NULL DEFAULT 'active',
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_user(user_id)

) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_account_identities (
  user_id CHAR(36) NOT NULL PRIMARY KEY,
  email VARCHAR(255),
  display_name VARCHAR(255),
  phone VARCHAR(80),
  account_role VARCHAR(40) NOT NULL DEFAULT 'homeowner',
  auth_provider VARCHAR(60) NOT NULL DEFAULT 'email',
  email_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
  account_status VARCHAR(30) NOT NULL DEFAULT 'active',
  last_login_at DATETIME(3),
  last_logout_at DATETIME(3),
  mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_account_email(email),
  INDEX idx_account_role(account_role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_homes (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  home_name VARCHAR(255) NOT NULL DEFAULT 'My Home',
  address TEXT,
  barangay VARCHAR(255),
  city VARCHAR(255),
  latitude DOUBLE,
  longitude DOUBLE,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_user(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_stakeholders (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  full_name VARCHAR(255) NOT NULL,
  relationship VARCHAR(100),
  phone VARCHAR(80),
  is_primary BOOLEAN NOT NULL DEFAULT FALSE,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  INDEX idx_user(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_emergency_contacts (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  contact_type VARCHAR(80) NOT NULL DEFAULT 'BFP',
  name VARCHAR(255),
  station_name VARCHAR(255),
  personnel_name VARCHAR(255),
  rank_position VARCHAR(255),
  phone VARCHAR(80),
  address TEXT,
  is_primary BOOLEAN NOT NULL DEFAULT FALSE,
  is_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  INDEX idx_user(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_safety_setups (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  safety_acknowledged BOOLEAN NOT NULL DEFAULT FALSE,
  entry_delay_seconds INT NOT NULL DEFAULT 30,
  siren_duration_seconds INT NOT NULL DEFAULT 120,
  ai_assist_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  notes TEXT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_user(user_id),
  CHECK (entry_delay_seconds BETWEEN 0 AND 600),
  CHECK (siren_duration_seconds BETWEEN 10 AND 3600)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_user_preferences (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  push_notifications BOOLEAN NOT NULL DEFAULT TRUE,
  email_alerts BOOLEAN NOT NULL DEFAULT TRUE,
  sms_alerts BOOLEAN NOT NULL DEFAULT FALSE,
  dark_mode BOOLEAN NOT NULL DEFAULT FALSE,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_user(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_devices (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  device_id VARCHAR(100) NOT NULL,
  device_name VARCHAR(255) NOT NULL DEFAULT 'Main PyroGuard Controller',
  device_type VARCHAR(100) NOT NULL DEFAULT 'ESP32_MAIN',
  status VARCHAR(60) NOT NULL DEFAULT 'registered',
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_device(device_id),
  INDEX idx_user(user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_device_current_state (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id VARCHAR(100) NOT NULL,
  temperature DECIMAL(12,4),
  humidity DECIMAL(12,4),
  smoke_raw INT,
  smoke_level DECIMAL(12,4),
  smoke_status VARCHAR(60),
  flame_detected BOOLEAN DEFAULT FALSE,
  alert_status VARCHAR(80),
  incident_type VARCHAR(120),
  severity_level INT DEFAULT 0,
  location TEXT,
  device_lat DECIMAL(12,8),
  device_lng DECIMAL(12,8),
  door_status VARCHAR(60),
  window_status VARCHAR(60),
  motion_detected BOOLEAN,
  system_armed BOOLEAN DEFAULT FALSE,
  system_mode VARCHAR(40) DEFAULT 'DISARMED',
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_device(device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_device_heartbeats (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id VARCHAR(100) NOT NULL,
  wifi_ok BOOLEAN DEFAULT FALSE,
  supabase_ok BOOLEAN DEFAULT FALSE,
  camera_ok BOOLEAN DEFAULT FALSE,
  ptz_ok BOOLEAN DEFAULT FALSE,
  mic_ok BOOLEAN DEFAULT FALSE,
  speaker_ok BOOLEAN DEFAULT FALSE,
  pir_ok BOOLEAN DEFAULT FALSE,
  door_ok BOOLEAN DEFAULT FALSE,
  window_ok BOOLEAN DEFAULT FALSE,
  ultrasonic_ok BOOLEAN DEFAULT FALSE,
  mq2_ok BOOLEAN DEFAULT FALSE,
  flame_ok BOOLEAN DEFAULT FALSE,
  dht22_ok BOOLEAN DEFAULT FALSE,
  gps_ok BOOLEAN DEFAULT FALSE,
  gsm_ok BOOLEAN DEFAULT FALSE,
  siren_ok BOOLEAN DEFAULT FALSE,
  uptime_secs BIGINT,
  battery_pct DECIMAL(6,2),
  local_ip VARCHAR(64),
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_device(device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_pyroguard_camera_telemetry (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id VARCHAR(100) NOT NULL,
  camera_device_id VARCHAR(100) NOT NULL DEFAULT 'pyroguard_camera_001',
  camera_ip VARCHAR(64),
  status VARCHAR(60) NOT NULL DEFAULT 'offline',
  motion_detected BOOLEAN DEFAULT FALSE,
  motion_pixels INT DEFAULT 0,
  pan_angle INT DEFAULT 90,
  tilt_angle INT DEFAULT 90,
  wifi_rssi INT,
  uptime_ms BIGINT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_camera(camera_device_id),
  INDEX idx_device(device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_system_state (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  device_id VARCHAR(100) NOT NULL,
  arm_mode VARCHAR(20) NOT NULL DEFAULT 'DISARMED',
  door_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  window_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  motion_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  acting_user CHAR(36),
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_device(device_id),
  CHECK (arm_mode IN ('DISARMED','ARM_HOME','ARM_AWAY'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_device_commands (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  target_device_id VARCHAR(100) NOT NULL,
  command VARCHAR(120) NOT NULL,
  payload JSON,
  requested_by CHAR(36),
  status VARCHAR(30) NOT NULL DEFAULT 'pending',
  result_message TEXT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  applied_at DATETIME(3),
  INDEX idx_pending(target_device_id,status,created_at),
  CHECK (status IN ('pending','processing','applied','failed','expired'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_ptz_state (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  device_id VARCHAR(100) NOT NULL,
  pan_position DECIMAL(9,3) NOT NULL DEFAULT 90,
  tilt_position DECIMAL(9,3) NOT NULL DEFAULT 90,
  moving BOOLEAN NOT NULL DEFAULT FALSE,
  auto_tracking BOOLEAN NOT NULL DEFAULT FALSE,
  pan_angle INT NOT NULL DEFAULT 90,
  tilt_angle INT NOT NULL DEFAULT 90,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_device(device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_ptz_commands (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100) NOT NULL,
  pan DECIMAL(9,3) NOT NULL DEFAULT 0,
  tilt DECIMAL(9,3) NOT NULL DEFAULT 0,
  speed DECIMAL(9,3) NOT NULL DEFAULT 0,
  mode VARCHAR(40) NOT NULL DEFAULT 'manual',
  preset_name VARCHAR(150),
  command VARCHAR(120),
  value INT,
  status VARCHAR(30) NOT NULL DEFAULT 'created',
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  applied_at DATETIME(3),
  INDEX idx_device_time(device_id,created_at),
  CHECK (status IN ('created','processing','executed','failed','expired'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_sensor_history (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100) NOT NULL,
  temperature DECIMAL(12,4),
  humidity DECIMAL(12,4),
  smoke_raw INT,
  smoke_level DECIMAL(12,4),
  smoke_status VARCHAR(60),
  flame_detected BOOLEAN,
  door_status VARCHAR(60),
  window_status VARCHAR(60),
  motion_detected BOOLEAN,
  system_armed BOOLEAN,
  system_mode VARCHAR(40),
  incident_type VARCHAR(120),
  severity_level INT DEFAULT 0,
  alert_status VARCHAR(80),
  location TEXT,
  device_lat DECIMAL(12,8),
  device_lng DECIMAL(12,8),
  payload_json JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_user_time(user_id,created_at),
  INDEX idx_device_time(device_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_event_history (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100),
  event_type VARCHAR(120) NOT NULL,
  sensor_name VARCHAR(120),
  location TEXT,
  event_status VARCHAR(60),
  image_url TEXT,
  acting_user_name VARCHAR(180),
  message TEXT,
  severity INT DEFAULT 0,
  payload_json JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_user_time(user_id,created_at),
  INDEX idx_device_time(device_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_camera_history (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100),
  event_type VARCHAR(120) NOT NULL,
  image_url TEXT,
  metadata_json JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_user_time(user_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_camera_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100) NOT NULL,
  record_key VARCHAR(190) NOT NULL,
  event_type VARCHAR(120) NOT NULL DEFAULT 'camera_event',
  snapshot_url TEXT,
  pan_at_capture DECIMAL(12,4),
  tilt_at_capture DECIMAL(12,4),
  payload_json JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_camera_record_key(record_key),
  INDEX idx_camera_event_user_time(user_id,created_at),
  INDEX idx_camera_event_device_time(device_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_audio_sessions (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100) NOT NULL,
  record_key VARCHAR(190) NOT NULL,
  direction VARCHAR(40) NOT NULL DEFAULT 'from_device',
  clip_url TEXT,
  metadata_json JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_audio_record_key(record_key),
  INDEX idx_audio_user_time(user_id,created_at),
  INDEX idx_audio_device_time(device_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_mirror_records (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36) NOT NULL,
  device_id VARCHAR(100),
  record_type VARCHAR(100) NOT NULL,
  record_key VARCHAR(190) NOT NULL,
  payload JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_user_type_key(user_id,record_type,record_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_dual_record_ledger (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  record_id CHAR(36) NOT NULL,
  user_id CHAR(36),
  device_id VARCHAR(100),
  record_type VARCHAR(100) NOT NULL,
  record_key VARCHAR(190) NOT NULL,
  operation VARCHAR(20) NOT NULL DEFAULT 'UPSERT',
  source VARCHAR(60) NOT NULL DEFAULT 'flutter',
  payload JSON,
  mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
  mysql_synced_at DATETIME(3),
  last_sync_error TEXT,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_dual_record_id(record_id),
  INDEX idx_dual_user_time(user_id,created_at),
  INDEX idx_dual_type_time(record_type,created_at),
  INDEX idx_dual_device_time(device_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_emergency_action_logs (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id CHAR(36),
  device_id VARCHAR(100),
  event_type VARCHAR(120) NOT NULL,
  severity VARCHAR(80),
  message TEXT,
  bfp_station VARCHAR(255),-- ============================================================================

-- PYROGUARD MYSQL INSTALL + COMPLETE 25-TABLE SUPABASE MIRROR (MySQL 8+)

-- Version: 2026-10-09 STRICT SUPABASE <-> MYSQL PARITY

--

-- NON-DESTRUCTIVE: creates missing tables, seeds four administrators, and
-- retains existing data. Supabase Auth passwords/tokens are not copied.
-- Run on MySQL Workbench ONLY.

-- ============================================================================

CREATE DATABASE IF NOT EXISTS pyroguard_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE pyroguard_db;

SET NAMES utf8mb4;

SET time_zone = '+00:00';

-- Non-destructive installation: preserve existing data and tables.
-- No DROP TABLE or reset statements are executed.


-- Supabase public.admin_accounts => MySQL pyroguard_admin_accounts

CREATE TABLE IF NOT EXISTS pyroguard_admin_accounts (

  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

  admin_order SMALLINT NOT NULL,

  user_id CHAR(36),

  email VARCHAR(255) NOT NULL,

  display_name VARCHAR(180) NOT NULL,

  admin_role VARCHAR(40) NOT NULL,

  admin_reference_code VARCHAR(40) NOT NULL,

  active BOOLEAN NOT NULL DEFAULT TRUE,

  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

  UNIQUE KEY uq_order(admin_order),

  UNIQUE KEY uq_email(email),

  UNIQUE KEY uq_ref(admin_reference_code),

  UNIQUE KEY uq_user(user_id)

) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_sensor_readings (

  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

  device_id VARCHAR(100) NOT NULL,

  temperature DECIMAL(12,4),

  humidity DECIMAL(12,4),

  smoke_raw INT,

  smoke_level DECIMAL(12,4),

  smoke_status VARCHAR(60),

  flame_detected BOOLEAN DEFAULT FALSE,

  alert_status VARCHAR(80),

  incident_type VARCHAR(120),

  severity_level INT DEFAULT 0,

  location TEXT,

  device_lat DECIMAL(12,8),

  device_lng DECIMAL(12,8),

  door_status VARCHAR(60),

  window_status VARCHAR(60),

  motion_detected BOOLEAN,

  system_armed BOOLEAN,

  created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),

  INDEX idx_device_time(device_id,created_at)

) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Run AFTER existing MySQL communication migrations. Preserve existing records.
-- Exact application/hardware payloads are stored as JSON, independent of source table columns.
CREATE TABLE IF NOT EXISTS pyroguard_source_records (
  source_table VARCHAR(100) NOT NULL,
  source_key VARCHAR(255) NOT NULL,
  payload JSON NOT NULL,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  source_record_id CHAR(36) NOT NULL,
  last_operation VARCHAR(12) NOT NULL,
  synced_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY(source_table, source_key),
  KEY ix_source_record_id (source_record_id),
  KEY ix_source_synced_at (synced_at)
);


CREATE TABLE IF NOT EXISTS pyroguard_local_source_records (
  source_table VARCHAR(100) NOT NULL,
  source_key VARCHAR(255) NOT NULL,
  payload JSON NOT NULL,
  payload_hash CHAR(64) NOT NULL,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  synced_at DATETIME(3) NOT NULL,
  PRIMARY KEY(source_table,source_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- READ-ONLY: table presence does not prove row equality.

SELECT COUNT(*) AS application_tables_found FROM information_schema.tables
WHERE table_schema=DATABASE() AND table_name IN ('pyroguard_admin_accounts','pyroguard_profiles','pyroguard_account_identities','pyroguard_homes','pyroguard_stakeholders','pyroguard_emergency_contacts','pyroguard_safety_setups','pyroguard_user_preferences','pyroguard_devices','pyroguard_device_current_state','pyroguard_device_heartbeats','pyroguard_pyroguard_camera_telemetry','pyroguard_system_state','pyroguard_device_commands','pyroguard_ptz_state','pyroguard_ptz_commands','pyroguard_sensor_history','pyroguard_event_history','pyroguard_camera_history','pyroguard_camera_events','pyroguard_audio_sessions','pyroguard_mirror_records','pyroguard_dual_record_ledger','pyroguard_emergency_action_logs','pyroguard_sensor_readings');

SELECT user_id,email,full_name,phone,account_role,account_status FROM pyroguard_profiles ORDER BY created_at DESC LIMIT 20;

SELECT user_id,email,display_name,email_confirmed,account_role,account_status FROM pyroguard_account_identities ORDER BY created_at DESC LIMIT 20;

SELECT source_table,COUNT(*) AS archived_rows,SUM(is_deleted) AS tombstones,MAX(synced_at) AS last_copy FROM pyroguard_local_source_records GROUP BY source_table ORDER BY source_table;

-- ==================== SECTION 2: MYSQL END ====================
