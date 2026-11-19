-- Apply using Supabase SQL Editor after reviewing a database backup.
-- No existing records, roles, memberships or device registrations are modified.
create table if not exists public.pyroguard_contact_current_state (
  device_id text not null,
  room_key text not null,
  contact_type text not null check (contact_type in ('door','window')),
  is_open boolean not null,
  received_at timestamptz not null default now(),
  primary key (device_id, contact_type),
  constraint contact_room_key_valid check (room_key in ('entrance','sala','kitchen','bedroom'))
);
create index if not exists pyroguard_contact_current_state_received_idx
  on public.pyroguard_contact_current_state(received_at desc);
alter table public.pyroguard_contact_current_state enable row level security;
-- Read-only monitoring for signed-in accounts, as requested.
-- Does NOT grant write, command, ownership or admin permissions.
drop policy if exists pyroguard_contact_authenticated_read on public.pyroguard_contact_current_state;
create policy pyroguard_contact_authenticated_read
  on public.pyroguard_contact_current_state
  for select to authenticated using (true);
revoke all on public.pyroguard_contact_current_state from anon;
grant select on public.pyroguard_contact_current_state to authenticated;
-- Only the Edge Function service role writes these states.
