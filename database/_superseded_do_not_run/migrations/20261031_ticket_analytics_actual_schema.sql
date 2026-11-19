-- PyroGuard ticket analytics: additive, read-only, respects caller's RLS.
-- The current Flutter schema uses support_tickets.title (NOT subject).
-- Run after reviewing existing ticket RLS policies and taking a database backup.
-- Do not use SECURITY DEFINER here: regular admins must see only their authorized tickets.
create or replace function public.pyroguard_ticket_analytics()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'visible_total', count(*),
    'open', count(*) filter (where status = 'open'),
    'in_progress', count(*) filter (where status = 'in_progress'),
    'resolved', count(*) filter (where status in ('resolved','closed')),
    'ignored', count(*) filter (where status = 'ignored'),
    'critical_active', count(*) filter (where severity = 'critical' and status not in ('resolved','closed','ignored')),
    'major_active', count(*) filter (where severity = 'major' and status not in ('resolved','closed','ignored')),
    'unassigned_active', count(*) filter (where assigned_to is null and status not in ('resolved','closed','ignored')),
    'generated_at', now()
  )
  from public.support_tickets
  where archived_at is null;
$$;
revoke all on function public.pyroguard_ticket_analytics() from public;
grant execute on function public.pyroguard_ticket_analytics() to authenticated;

-- Diagnostic query (run separately in SQL editor if needed):
-- select column_name, data_type from information_schema.columns
-- where table_schema='public' and table_name='support_tickets' order by ordinal_position;
