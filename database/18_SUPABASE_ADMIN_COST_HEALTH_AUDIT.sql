-- PyroGuard v17 (2026-11-24): admin-managed hardware cost, sensor health
-- history, and a log of user changes for the admin console.

-- ── 1. Hardware + labor cost catalog (one list for everyone, admin edits) ──
create table if not exists public.pyroguard_cost_catalog (
  id               bigint generated always as identity primary key,
  category         text not null default 'Hardware' check (category in ('Hardware','Labor','Other')),
  item             text not null check (char_length(item) <= 160),
  quantity         numeric(8,2) not null default 1 check (quantity >= 0),
  unit             text not null default 'pc' check (char_length(unit) <= 20),
  unit_price       numeric(10,2) not null default 0 check (unit_price >= 0),
  supplier         text not null default 'Makerlab Electronics PH',
  source_url       text,
  price_checked_on date not null default current_date,
  notes            text check (notes is null or char_length(notes) <= 300),
  sort_order       integer not null default 0,
  updated_at       timestamptz not null default now(),
  updated_by       uuid default auth.uid()
);
alter table public.pyroguard_cost_catalog enable row level security;
drop policy if exists cost_catalog_read on public.pyroguard_cost_catalog;
create policy cost_catalog_read on public.pyroguard_cost_catalog for select to authenticated using (true);
drop policy if exists cost_catalog_admin_write on public.pyroguard_cost_catalog;
create policy cost_catalog_admin_write on public.pyroguard_cost_catalog for all to authenticated
  using (public.pg_ticket_admin()) with check (public.pg_ticket_admin());
grant select, insert, update, delete on public.pyroguard_cost_catalog to authenticated;

-- Seed: Makerlab Electronics PH prices (checked 2026-11-24) + NCR minimum wage
-- (Wage Order NCR-28: PHP 755/day non-agriculture, effective 2026-09-26).
insert into public.pyroguard_cost_catalog (category,item,quantity,unit,unit_price,source_url,notes,sort_order)
select * from (values
 ('Hardware','30 pins ESP32 WiFi IoT Development Board (Batch 1 and 2)',2::numeric,'pc',350::numeric,'https://makerlab.ph/products/30-pins-and-38-pins-esp32-wifi-iot-development-board',null,1),
 ('Hardware','DFRobot ESP32-S3 AI Camera Module DFR1154 (Camera 1)',1,'pc',1649,'https://makerlab.ph/products/esp32-s3-ai-camera-module-edge-image-recognition-night-vision-chatgpt-voice-interaction-dfr1154',null,2),
 ('Hardware','DHT22 Temperature and Humidity Sensor Module',4,'pc',200,'https://makerlab.ph/products/dht22-temperature-humidity-sensor-module',null,3),
 ('Hardware','MQ-2 Smoke Gas Sensor',4,'pc',75,'https://makerlab.ph/products/mq2-smoke-gas-sensor',null,4),
 ('Hardware','Flame Sensor Module',4,'pc',50,'https://makerlab.ph/products/flame-sensor-module',null,5),
 ('Hardware','10pcs Active Buzzer (4 used)',1,'pack',109,'https://makerlab.ph/products/10pcs-active-buzzer',null,6),
 ('Hardware','Magnetic Door Reed Switch Set with Wire',4,'set',150,'https://makerlab.ph/products/magnetic-door-switch-set',null,7),
 ('Hardware','SG90 Micro 9g Servo (camera pan/tilt)',2,'pc',90,'https://makerlab.ph/products/sg92r-sg90-micro-9g-servo-nylon-carbon-fiber-gears-for-rc-model-aero-modelling-helicopter-parts',null,8),
 ('Hardware','Pan Tilt Plastic Bracket for Servo SG90',1,'pc',75,'https://makerlab.ph/products/pan-tilt-plastic-bracket-for-servo-sg90-sg90s-mg90s-sg92r','Sale price',9),
 ('Hardware','120pcs Metal Film Resistor Kit 1/4W 1% (MQ-2 voltage divider)',1,'kit',69,'https://makerlab.ph/products/120pcs-taping-metal-film-resistor-kit-1-4w-1-100-ohm-330-ohm-470-ohm-1k-4-7k-10k',null,10),
 ('Hardware','Solderless Breadboard MB102 830 Tie Points',2,'pc',65,'https://makerlab.ph/products/solder-less-pcb-breadboard-syb-mb102-830-800-400-170-tie-points-circuit-solderless-half-full-size',null,11),
 ('Hardware','120pcs 20cm Dupont Jumper Wire Cables (M-M, M-F, F-F)',1,'set',195,'https://makerlab.ph/products/120pcs-20cm-2-54mm-dupont-jumper-wire-cables-m-m-m-f-f-f',null,12),
 ('Hardware','PVC Type 1007 Tinned Copper Stranded Wire (room sensor runs)',1,'spool',350,'https://makerlab.ph/products/model-1007-18awg-20awg-22-awg-24awg-tinned-copper-stranded-hook-up-wire-5-color-spool','Starting price',13),
 ('Hardware','PKCell Lithium-ion 18650 Battery 3.7V 2200mAh (backup power)',4,'pc',100,'https://makerlab.ph/products/pkcell-lithium-ion-18650-21700-battery-3-7v-true-rated-18650-2200mah-3000mah-3350mah-4500mah-rechargeable-battery-for-power-bank-flashlight-mini-fan',null,14),
 ('Hardware','2 x 18650 Lithium Battery Shield V8 5V/3A',2,'pc',300,'https://makerlab.ph/products/dual-18650-lithium-battery-shield-v8-mobile-power-expansion-board-module',null,15),
 ('Hardware','5V 3A DC Power Adapter US Plug',3,'pc',129,'https://makerlab.ph/products/9448',null,16),
 ('Hardware','Twinbox Weatherproof Enclosure 158x90x46mm IP65',3,'pc',199,'https://makerlab.ph/products/weatherproof-enclosure-157x90x47mm-ip65-nema-4-abs',null,17),
 ('Labor','Assembly and soldering',8,'hr',94.38,'https://www.sunstar.com.ph/manila/p60-minimum-wage-hike-takes-effect-in-metro-manila','NCR-28 minimum wage PHP 755 / 8 h',18),
 ('Labor','Installation and wiring in the house',8,'hr',94.38,'https://www.sunstar.com.ph/manila/p60-minimum-wage-hike-takes-effect-in-metro-manila','NCR-28 minimum wage PHP 755 / 8 h',19),
 ('Labor','Configuration and testing',4,'hr',94.38,'https://www.sunstar.com.ph/manila/p60-minimum-wage-hike-takes-effect-in-metro-manila','NCR-28 minimum wage PHP 755 / 8 h',20),
 ('Other','Supabase cloud database and Vercel hosting (free tiers)',1,'month',0,null,null,21)
) v(category,item,quantity,unit,unit_price,source_url,notes,sort_order)
where not exists (select 1 from public.pyroguard_cost_catalog);

-- The old per-user cost list is no longer used.
drop table if exists public.pyroguard_cost_items;

-- ── 2. Change log (what users and admins changed) ──
create table if not exists public.pyroguard_change_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  record_id   text,
  action      text not null,
  changed_by  uuid,
  actor_email text,
  old_data    jsonb,
  new_data    jsonb,
  changed_at  timestamptz not null default now()
);
create index if not exists pyroguard_change_log_time_idx on public.pyroguard_change_log (changed_at desc);
alter table public.pyroguard_change_log enable row level security;
drop policy if exists change_log_admin_read on public.pyroguard_change_log;
create policy change_log_admin_read on public.pyroguard_change_log for select to authenticated using (public.pg_ticket_admin());
grant select on public.pyroguard_change_log to authenticated;

create or replace function public.pyroguard_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.pyroguard_change_log (table_name, record_id, action, changed_by, actor_email, old_data, new_data)
  values (tg_table_name, coalesce(rec->>'id', rec->>'user_id'), tg_op, auth.uid(),
          (select email from auth.users where id = auth.uid()),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return null;
end $$;

-- (change-log triggers are attached at the end of this file)

-- Admins can see and correct every home's maintenance records.
drop policy if exists sensor_maintenance_admin on public.pyroguard_sensor_maintenance;
create policy sensor_maintenance_admin on public.pyroguard_sensor_maintenance for all to authenticated
  using (public.pg_ticket_admin()) with check (public.pg_ticket_admin());

-- ── 3. Sensor health history (recorded automatically from the readings) ──
create table if not exists public.pyroguard_sensor_health_log (
  id                   bigint generated always as identity primary key,
  user_id              uuid,
  controller_device_id text not null,
  room_key             text not null,
  sensor_kind          text not null check (sensor_kind in ('DHT22','MQ2','FLAME')),
  status               text not null check (status in ('OK','WARMING_UP','FAULT','NO_SIGNAL')),
  detail               text,
  observed_at          timestamptz not null,
  admin_note           text check (admin_note is null or char_length(admin_note) <= 500),
  resolved_at          timestamptz,
  resolved_by          uuid
);
create index if not exists pyroguard_sensor_health_log_idx
  on public.pyroguard_sensor_health_log (controller_device_id, room_key, sensor_kind, observed_at desc);

create table if not exists public.pyroguard_sensor_health_state (
  controller_device_id text not null,
  room_key             text not null,
  sensor_kind          text not null,
  status               text not null,
  since                timestamptz not null,
  last_seen            timestamptz not null,
  primary key (controller_device_id, room_key, sensor_kind)
);

alter table public.pyroguard_sensor_health_log enable row level security;
alter table public.pyroguard_sensor_health_state enable row level security;
drop policy if exists health_log_read on public.pyroguard_sensor_health_log;
create policy health_log_read on public.pyroguard_sensor_health_log for select to authenticated using (
  user_id = auth.uid() or public.pg_ticket_admin()
  or (public.pyroguard_can_view_hardware() and public.pyroguard_is_shared_device(controller_device_id)));
drop policy if exists health_log_admin_edit on public.pyroguard_sensor_health_log;
create policy health_log_admin_edit on public.pyroguard_sensor_health_log for update to authenticated
  using (public.pg_ticket_admin()) with check (public.pg_ticket_admin());
drop policy if exists health_state_read on public.pyroguard_sensor_health_state;
create policy health_state_read on public.pyroguard_sensor_health_state for select to authenticated using (true);
grant select, update on public.pyroguard_sensor_health_log to authenticated;
grant select on public.pyroguard_sensor_health_state to authenticated;

-- Same rules as the app's Sensor Health panel.
create or replace function public.pyroguard_sensor_status(kind text, r public.pyroguard_room_sensor_readings)
returns table(status text, detail text) language sql immutable as $$
  select case
    when kind = 'DHT22' then case when r.temperature is null or r.humidity is null then 'FAULT' else 'OK' end
    when kind = 'MQ2' then case
      when upper(coalesce(r.smoke_status,'')) = 'WARMUP' then 'WARMING_UP'
      when upper(coalesce(r.smoke_status,'')) = 'FAULT' and r.smoke_raw < 155 then 'NO_SIGNAL'
      when upper(coalesce(r.smoke_status,'')) = 'FAULT' or r.smoke_fault is true then 'FAULT'
      else 'OK' end
    else case when r.flame_fault is true then 'FAULT' else 'OK' end
  end,
  case
    when kind = 'DHT22' then format('%s °C, %s %% RH', coalesce(r.temperature::text,'none'), coalesce(r.humidity::text,'none'))
    when kind = 'MQ2' then format('%s mV, %s', coalesce(r.smoke_raw::text,'none'), coalesce(r.smoke_status,'none'))
    else format('flame %s, fault %s', coalesce(r.flame_detected::text,'none'), coalesce(r.flame_fault::text,'false'))
  end;
$$;

create or replace function public.pyroguard_track_sensor_health() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; s record; cur record;
begin
  foreach k in array array['DHT22','MQ2','FLAME'] loop
    select * into s from public.pyroguard_sensor_status(k, new);
    select * into cur from public.pyroguard_sensor_health_state
      where controller_device_id = new.controller_device_id and room_key = new.room_key and sensor_kind = k;
    if not found then
      insert into public.pyroguard_sensor_health_state values (new.controller_device_id, new.room_key, k, s.status, new.received_at, new.received_at);
      insert into public.pyroguard_sensor_health_log (user_id, controller_device_id, room_key, sensor_kind, status, detail, observed_at)
        values (new.user_id, new.controller_device_id, new.room_key, k, s.status, s.detail, new.received_at);
    elsif cur.status <> s.status then
      update public.pyroguard_sensor_health_state set status = s.status, since = new.received_at, last_seen = new.received_at
        where controller_device_id = new.controller_device_id and room_key = new.room_key and sensor_kind = k;
      insert into public.pyroguard_sensor_health_log (user_id, controller_device_id, room_key, sensor_kind, status, detail, observed_at)
        values (new.user_id, new.controller_device_id, new.room_key, k, s.status, s.detail, new.received_at);
    else
      update public.pyroguard_sensor_health_state set last_seen = new.received_at
        where controller_device_id = new.controller_device_id and room_key = new.room_key and sensor_kind = k;
    end if;
  end loop;
  return null;
end $$;

drop trigger if exists pyroguard_sensor_health_trg on public.pyroguard_room_sensor_readings;
create trigger pyroguard_sensor_health_trg after insert on public.pyroguard_room_sensor_readings
  for each row execute function public.pyroguard_track_sensor_health();


-- Attach the change-log trigger to the tables admins need to watch.
do $$
declare t text;
begin
  foreach t in array array['pyroguard_cost_catalog','homes','emergency_contacts','pyroguard_home_layout',
                           'pyroguard_sensor_maintenance','pyroguard_area_incidents','pyroguard_incident_reports',
                           'pyroguard_bfp_report_emails']
  loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists pyroguard_change_log_trg on public.%I', t);
      execute format('create trigger pyroguard_change_log_trg after insert or update or delete on public.%I
                      for each row execute function public.pyroguard_log_change()', t);
    end if;
  end loop;
end $$;
