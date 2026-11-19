-- PyroGuard: read-only, caller-scoped recorded analytics. No dummy rows are inserted.
-- Back up before applying. SECURITY INVOKER means RLS still controls visible tickets.
-- The function uses the project's current ticket columns (title/status/severity).
create or replace function public.pyroguard_ticket_daily_actual(days_back integer default 14)
returns table(day date, ticket_total bigint, critical_total bigint, resolved_total bigint)
language sql stable security invoker set search_path = public
as $$
  select created_at::date as day,
    count(*)::bigint as ticket_total,
    count(*) filter (where severity='critical')::bigint as critical_total,
    count(*) filter (where status in ('resolved','closed'))::bigint as resolved_total
  from public.support_tickets
  where created_at >= now() - make_interval(days => least(greatest(days_back,1),366))
    and archived_at is null
  group by created_at::date order by day;
$$;
revoke all on function public.pyroguard_ticket_daily_actual(integer) from public;
grant execute on function public.pyroguard_ticket_daily_actual(integer) to authenticated;
-- IMPORTANT: This only provides authorized ticket aggregates; admin-console
-- separately returns exact Supabase event/device/sync-queue counts.
-- MySQL replication requires the independently running sync-outbox or local PC worker.
