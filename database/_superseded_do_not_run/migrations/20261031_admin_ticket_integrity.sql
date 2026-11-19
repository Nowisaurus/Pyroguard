-- Run in Supabase SQL Editor after the existing support-ticket schema is installed.
-- Keeps deleted tickets as archived records, preserving their messages and audit trail.
BEGIN;
ALTER TABLE public.support_tickets ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE public.support_tickets ADD COLUMN IF NOT EXISTS archived_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;
-- Existing status CHECK from the initial schema excludes ignored.
DO $$
DECLARE constraint_name text;
BEGIN
  FOR constraint_name IN
    SELECT conname FROM pg_constraint
    WHERE conrelid='public.support_tickets'::regclass AND contype='c'
      AND pg_get_constraintdef(oid) LIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.support_tickets DROP CONSTRAINT %I',constraint_name);
  END LOOP;
END $$;
ALTER TABLE public.support_tickets ADD CONSTRAINT support_tickets_status_check
 CHECK (status IN ('open','in_progress','waiting_for_user','resolved','closed','ignored'));
CREATE INDEX IF NOT EXISTS support_tickets_active_queue_idx
 ON public.support_tickets(created_at DESC) WHERE archived_at IS NULL;
-- Existing guard trigger is retained; add a strict archive guard to run before it.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_archive_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE head_ok boolean;
BEGIN
  IF NEW.archived_at IS DISTINCT FROM OLD.archived_at OR NEW.archived_by IS DISTINCT FROM OLD.archived_by THEN
    SELECT EXISTS(SELECT 1 FROM public.admin_accounts
       WHERE user_id=auth.uid() AND active IS TRUE AND admin_role='head_developer') INTO head_ok;
    IF NOT head_ok THEN RAISE EXCEPTION 'Only active head developers may archive tickets'; END IF;
    IF OLD.archived_at IS NOT NULL THEN RAISE EXCEPTION 'Archived ticket cannot be changed using this action'; END IF;
    IF NEW.archived_at IS NULL THEN RAISE EXCEPTION 'Archive timestamp required'; END IF;
    NEW.archived_by := auth.uid();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pyroguard_ticket_archive_guard ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_archive_guard BEFORE UPDATE ON public.support_tickets
 FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_archive_guard();
-- Original ticket audit trigger does not record archive changes; separate durable event.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_archive_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
    INSERT INTO public.support_ticket_events(ticket_id,actor_id,action,changes)
    VALUES(NEW.id, auth.uid(), 'archived', jsonb_build_object('archived_at',NEW.archived_at));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pyroguard_ticket_archive_audit ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_archive_audit AFTER UPDATE ON public.support_tickets
 FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_archive_audit();
-- Prevent destructive deletions, including cascading loss of ticket history.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_no_delete()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN RAISE EXCEPTION 'Ticket deletion is disabled; archive the ticket instead'; END $$;
DROP TRIGGER IF EXISTS pyroguard_ticket_no_delete ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_no_delete BEFORE DELETE ON public.support_tickets
 FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_no_delete();
COMMIT;
