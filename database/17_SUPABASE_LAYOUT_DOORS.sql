-- PyroGuard v17 (2026-11-23): doorway point of walled rooms (bedroom, bathroom)
-- so evacuation routes leave through the door instead of through a wall.
alter table public.pyroguard_home_layout
  add column if not exists door_x_m numeric(6,2) check (door_x_m is null or door_x_m between 0 and 200),
  add column if not exists door_y_m numeric(6,2) check (door_y_m is null or door_y_m between 0 and 200);
