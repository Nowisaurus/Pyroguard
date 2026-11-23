-- PyroGuard v18 (2026-11-24): test records removed (real readings only);
-- live updates for the price list, health history and change log.
drop table if exists public.pyroguard_test_records;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pyroguard_cost_catalog') then
    alter publication supabase_realtime add table public.pyroguard_cost_catalog;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pyroguard_sensor_health_log') then
    alter publication supabase_realtime add table public.pyroguard_sensor_health_log;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pyroguard_change_log') then
    alter publication supabase_realtime add table public.pyroguard_change_log;
  end if;
end $$;
