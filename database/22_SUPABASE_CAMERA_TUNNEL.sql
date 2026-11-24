-- PyroGuard (2026-11-24): HTTPS addresses for Camera 1 so the Vercel website
-- can show live video. Written by deployment/camera-tunnel/start-camera-tunnel.ps1
-- (Cloudflare quick tunnels on the PC that is on the Pyroguard_Team Wi-Fi).
-- Run in Supabase -> SQL Editor. Safe to run more than once.
create table if not exists public.pyroguard_camera_tunnel (
  camera_device_id text primary key,
  http_url   text,          -- https address for the camera's port 80 (capture, motion)
  stream_url text,          -- https address for the camera's port 81 (live MJPEG)
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.pyroguard_camera_tunnel enable row level security;
drop policy if exists camera_tunnel_read on public.pyroguard_camera_tunnel;
create policy camera_tunnel_read on public.pyroguard_camera_tunnel for select to authenticated using (true);
grant select on public.pyroguard_camera_tunnel to authenticated;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime'
                 and schemaname='public' and tablename='pyroguard_camera_tunnel') then
    alter publication supabase_realtime add table public.pyroguard_camera_tunnel;
  end if;
end $$;
