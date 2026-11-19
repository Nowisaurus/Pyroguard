-- Apply AFTER 20261031_admin_ticket_integrity.sql.
-- Assignment is head-controlled. Standard admins see ONLY assigned tickets.
-- Homeowners continue seeing their own tickets, excluding internal messages.
BEGIN;

CREATE OR REPLACE FUNCTION public.pg_ticket_head()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT EXISTS (SELECT 1 FROM public.admin_accounts
   WHERE user_id=auth.uid() AND active IS TRUE AND admin_role='head_developer');
$$;
REVOKE ALL ON FUNCTION public.pg_ticket_head() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pg_ticket_head() TO authenticated;

-- Do not rely on Flutter filtering: make visibility enforceable by Postgres.
DROP POLICY IF EXISTS ticket_read ON public.support_tickets;
CREATE POLICY ticket_read ON public.support_tickets FOR SELECT TO authenticated
 USING (
   user_id=auth.uid() OR public.pg_ticket_head() OR
   (public.pg_ticket_admin() AND assigned_to=auth.uid())
 );
DROP POLICY IF EXISTS ticket_admin_update ON public.support_tickets;
CREATE POLICY ticket_admin_update ON public.support_tickets FOR UPDATE TO authenticated
 USING (public.pg_ticket_head() OR (public.pg_ticket_admin() AND assigned_to=auth.uid()))
 WITH CHECK (public.pg_ticket_head() OR (public.pg_ticket_admin() AND assigned_to=auth.uid()));

-- Existing policies for messages and events may contain broad pg_ticket_admin()
-- and must be restricted too, including authoring internal notes.
DROP POLICY IF EXISTS ticket_message_read ON public.support_ticket_messages;
CREATE POLICY ticket_message_read ON public.support_ticket_messages FOR SELECT TO authenticated
 USING (EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id=ticket_id)
  AND (NOT internal OR public.pg_ticket_head() OR public.pg_ticket_admin()
    AND EXISTS (SELECT 1 FROM public.support_tickets t
      WHERE t.id=ticket_id AND t.assigned_to=auth.uid())));
DROP POLICY IF EXISTS ticket_message_insert ON public.support_ticket_messages;
CREATE POLICY ticket_message_insert ON public.support_ticket_messages FOR INSERT TO authenticated
 WITH CHECK (author_id=auth.uid() AND
   EXISTS(SELECT 1 FROM public.support_tickets t WHERE t.id=ticket_id)
   AND (NOT internal OR public.pg_ticket_head() OR
       public.pg_ticket_admin() AND EXISTS(SELECT 1 FROM public.support_tickets t
         WHERE t.id=ticket_id AND t.assigned_to=auth.uid())));
DROP POLICY IF EXISTS ticket_events_read ON public.support_ticket_events;
CREATE POLICY ticket_events_read ON public.support_ticket_events FOR SELECT TO authenticated
 USING (EXISTS(SELECT 1 FROM public.support_tickets t WHERE t.id=ticket_id));

-- Validate assignment target at the database, not merely dropdown filtering.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_assignment_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
   IF NOT public.pg_ticket_head() THEN
      RAISE EXCEPTION 'Only the head developer can assign or reassign tickets';
   END IF;
   IF NEW.assigned_to IS NOT NULL AND NOT EXISTS(
      SELECT 1 FROM public.admin_accounts
        WHERE user_id=NEW.assigned_to AND active IS TRUE
          AND admin_role IN ('administrator','head_developer')) THEN
      RAISE EXCEPTION 'Assign tickets only to active administrators';
   END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pyroguard_ticket_assignment_guard ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_assignment_guard
 BEFORE UPDATE ON public.support_tickets FOR EACH ROW
 EXECUTE FUNCTION public.pyroguard_ticket_assignment_guard();
COMMIT;

-- IMPORTANT: This migration assumes the three named base SELECT/UPDATE policies
-- from PYROGUARD_ALL_QUERIES_SUPABASE.sql. Review any OTHER permissive policies
-- before deployment, as PostgreSQL combines permissive policies with OR.
-- Head developer can see full aggregate analytics; other admins see their own queue.
