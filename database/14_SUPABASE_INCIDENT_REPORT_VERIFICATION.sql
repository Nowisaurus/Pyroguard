-- PyroGuard v17 (2026-11-23): proof that an incident report PDF is real.
-- Every generated PDF is registered here with a SHA-256 fingerprint of its
-- sensor readings and camera photos. The PDF carries a verification code + QR
-- code; the BFP opens the verify-incident-report page to check it against the
-- readings and photos stored on the PyroGuard server.

create table if not exists public.pyroguard_incident_reports (
  id              bigint generated always as identity primary key,
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  report_number   text not null,
  controller_id   text not null,
  room_key        text not null,
  incident_type   text not null,
  first_detected  timestamptz not null,
  last_detected   timestamptz not null,
  reading_count   integer not null default 0,
  photo_urls      jsonb not null default '[]'::jsonb,
  data_sha256     text not null check (data_sha256 ~ '^[0-9a-f]{64}$'),
  verify_code     text not null check (verify_code ~ '^[0-9A-F]{16}$'),
  area_label      text,
  generated_at    timestamptz not null default now(),
  unique (user_id, report_number)
);
create index if not exists pyroguard_incident_reports_lookup_idx
  on public.pyroguard_incident_reports (report_number, verify_code);

alter table public.pyroguard_incident_reports enable row level security;
drop policy if exists incident_reports_own_select on public.pyroguard_incident_reports;
create policy incident_reports_own_select on public.pyroguard_incident_reports
  for select to authenticated using (user_id = auth.uid());
drop policy if exists incident_reports_own_insert on public.pyroguard_incident_reports;
create policy incident_reports_own_insert on public.pyroguard_incident_reports
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists incident_reports_own_update on public.pyroguard_incident_reports;
create policy incident_reports_own_update on public.pyroguard_incident_reports
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.pyroguard_incident_reports to authenticated;
