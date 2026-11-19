-- ============================================================================
-- PYROGUARD - SUPABASE FINAL SYNC FIX                         2026-11-19
-- Run ONCE in the Supabase SQL Editor (role: postgres) AFTER the original core
-- schema (PYROGUARD_ALL_QUERIES_SUPABASE.sql sections 1-38). Back up first.
--
-- This ONE file replaces all of these (do not run them again):
--   20261031_admin_ticket_integrity.sql        20261031_admin_assignment_visibility.sql
--   20261031_ticket_analytics_actual_schema.sql 20261031_verified_admin_record_metrics.sql
--   20261101_room_sensor_groups_supabase.sql   20261104_contact_state.sql
--   20261104_shared_read_only_home1.sql        20261104_verified_sensor_incidents.sql
--   20261104_home1_shared_access_supabase.sql  20261104b_false_fire_and_rooms_supabase.sql
--
-- Safe to run more than once. No existing row is deleted.
--
-- BUGS FIXED (compared with the separate scripts):
--  1. pg_ticket_guard rejected EVERY update made without a signed-in user, so the
--     MySQL sync worker (service role) could never mark a ticket mysql_synced and
--     every acknowledgement also bumped updated_at -> endless re-sync. Bookkeeping
--     updates (mysql_synced / mysql_synced_at / last_sync_error) now pass through
--     untouched, and server-side roles (service_role/postgres) are allowed.
--  2. The assignment and archive guards also blocked the service role.
--  3. The "no delete" trigger had no escape hatch (it also blocked deleting a user
--     whose tickets cascade). A deliberate, per-transaction bypass is added.
--  4. 20261104_shared_read_only_home1.sql made hardware data readable by ANY
--     signed-in account, which silently overrode the Home 1 membership rules.
--     Those broad policies are removed; Home 1 members + active admins can read.
--  5. 20261104_verified_sensor_incidents.sql (old) and 20261104b (new) defined the
--     same trigger function; whichever ran last won. Only the false-fire-guarded
--     version (fire_confirmed in two consecutive readings) is installed now.
--  6. 20261101 created room_key CHECK ('sala','bedroom') which rejected entrance and
--     kitchen. Replaced by the four real rooms (NOT VALID keeps old rows).
--  7. pyroguard_contact_current_state had no single key column, so the MySQL worker
--     could not mirror it. A stable id column is added.
--  8. Admins were excluded from Home 1 enrollment AND had no read policy on most
--     hardware tables. Active admins now get read access.
--  9. The Home 1 verify query labelled ESP32-001/sala as "Entrance" (legacy map).
--     Fixed in 03_VERIFY_SUPABASE.sql.
-- 10. Storage buckets used by the app (incident-media) and by the email template
--     logo (assets) are created with policies.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. PRECONDITIONS
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE missing text;
BEGIN
    SELECT string_agg(t, ', ') INTO missing
      FROM unnest(ARRAY['admin_accounts','profiles','account_identities','homes','devices',
                        'device_current_state','device_heartbeats','pyroguard_camera_telemetry',
                        'system_state','device_commands','ptz_state','ptz_commands',
                        'sensor_history','event_history','camera_events','user_preferences',
                        'support_tickets','support_ticket_messages','support_ticket_events']) t
     WHERE to_regclass('public.' || t) IS NULL;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing core tables: %. Run PYROGUARD_ALL_QUERIES_SUPABASE.sql first.', missing;
    END IF;
    IF to_regprocedure('public.pg_ticket_admin()') IS NULL THEN
        RAISE EXCEPTION 'pg_ticket_admin() missing. Run PYROGUARD_ALL_QUERIES_SUPABASE.sql first.';
    END IF;
END;
$pre$;

-- event_history.record_key must be unique for ON CONFLICT (record_key).
ALTER TABLE public.event_history ADD COLUMN IF NOT EXISTS record_key text;
CREATE UNIQUE INDEX IF NOT EXISTS event_history_record_key_unique ON public.event_history(record_key);

-- ============================================================================
-- 1. SUPPORT TICKETS: status, archive, head-controlled assignment, analytics
-- ============================================================================
ALTER TABLE public.support_tickets ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE public.support_tickets ADD COLUMN IF NOT EXISTS archived_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

DO $st$
DECLARE c text;
BEGIN
    FOR c IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'public.support_tickets'::regclass AND contype = 'c'
                AND pg_get_constraintdef(oid) ILIKE '%status%IN%'
    LOOP
        EXECUTE format('ALTER TABLE public.support_tickets DROP CONSTRAINT %I', c);
    END LOOP;
END;
$st$;
ALTER TABLE public.support_tickets ADD CONSTRAINT support_tickets_status_check
    CHECK (status IN ('open','in_progress','waiting_for_user','resolved','closed','ignored'));
CREATE INDEX IF NOT EXISTS support_tickets_active_queue_idx
    ON public.support_tickets(created_at DESC) WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS support_tickets_assigned_idx ON public.support_tickets(assigned_to);

-- True for requests made by the database itself or an Edge Function / worker
-- using the service role (no signed-in user).
CREATE OR REPLACE FUNCTION public.pyroguard_is_server_role()
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
    -- session_user (not current_user) so the answer is the same inside
    -- SECURITY DEFINER triggers. PostgREST connects as "authenticator".
    SELECT auth.uid() IS NULL
       AND (coalesce(auth.role(), '') = 'service_role'
            OR session_user IN ('postgres', 'supabase_admin'));
$$;

-- Only mysql_synced / mysql_synced_at / last_sync_error changed?
CREATE OR REPLACE FUNCTION public.pyroguard_only_sync_columns_changed(new_row jsonb, old_row jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
    SELECT (new_row - 'mysql_synced' - 'mysql_synced_at' - 'last_sync_error')
         = (old_row - 'mysql_synced' - 'mysql_synced_at' - 'last_sync_error');
$$;

CREATE OR REPLACE FUNCTION public.pg_ticket_head()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT EXISTS (SELECT 1 FROM public.admin_accounts
                    WHERE user_id = auth.uid() AND active IS TRUE AND admin_role = 'head_developer');
$$;
REVOKE ALL ON FUNCTION public.pg_ticket_head() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pg_ticket_head() TO authenticated, service_role;

-- Main ticket guard (replaces the version in PYROGUARD_ALL_QUERIES_SUPABASE.sql).
CREATE OR REPLACE FUNCTION public.pg_ticket_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND public.pyroguard_only_sync_columns_changed(to_jsonb(NEW), to_jsonb(OLD)) THEN
        RETURN NEW;                        -- sync bookkeeping: keep updated_at as is
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NOT public.pyroguard_is_server_role() AND (
               auth.uid() IS NULL
            OR (NOT public.pg_ticket_admin() AND NEW.user_id IS DISTINCT FROM auth.uid())) THEN
            RAISE EXCEPTION 'Only the owner can file a ticket';
        END IF;
        IF NOT public.pg_ticket_admin() AND NOT public.pyroguard_is_server_role() THEN
            NEW.severity := 'normal';
            NEW.status := 'open';
            NEW.assigned_to := NULL;
            NEW.resolution_notes := NULL;
            NEW.resolved_at := NULL;
        END IF;
    ELSE
        IF NOT public.pg_ticket_admin() AND NOT public.pyroguard_is_server_role() THEN
            RAISE EXCEPTION 'Only administrators may update ticket fields';
        END IF;
        IF NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.created_at IS DISTINCT FROM OLD.created_at
           OR NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION 'Ticket identity is immutable';
        END IF;
    END IF;

    IF NEW.status IN ('resolved', 'closed') AND NEW.resolved_at IS NULL THEN
        NEW.resolved_at := now();
    ELSIF NEW.status NOT IN ('resolved', 'closed') THEN
        NEW.resolved_at := NULL;
    END IF;
    NEW.updated_at := now();
    NEW.mysql_synced := false;             -- business change -> copy to MySQL again
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS support_tickets_guard ON public.support_tickets;
CREATE TRIGGER support_tickets_guard BEFORE INSERT OR UPDATE ON public.support_tickets
    FOR EACH ROW EXECUTE FUNCTION public.pg_ticket_guard();

-- Only the head developer assigns; targets must be active administrators.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_assignment_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
        IF NOT public.pg_ticket_head() AND NOT public.pyroguard_is_server_role() THEN
            RAISE EXCEPTION 'Only the head developer can assign or reassign tickets';
        END IF;
        IF NEW.assigned_to IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.admin_accounts
             WHERE user_id = NEW.assigned_to AND active IS TRUE
               AND admin_role IN ('administrator', 'head_developer')) THEN
            RAISE EXCEPTION 'Assign tickets only to active administrators';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_ticket_assignment_guard ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_assignment_guard BEFORE UPDATE ON public.support_tickets
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_assignment_guard();

-- Archive (instead of delete): head developer only, one-way.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_archive_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NEW.archived_at IS DISTINCT FROM OLD.archived_at OR NEW.archived_by IS DISTINCT FROM OLD.archived_by THEN
        IF NOT public.pg_ticket_head() AND NOT public.pyroguard_is_server_role() THEN
            RAISE EXCEPTION 'Only active head developers may archive tickets';
        END IF;
        IF OLD.archived_at IS NOT NULL THEN RAISE EXCEPTION 'Archived ticket cannot be changed using this action'; END IF;
        IF NEW.archived_at IS NULL THEN RAISE EXCEPTION 'Archive timestamp required'; END IF;
        NEW.archived_by := coalesce(auth.uid(), NEW.archived_by);
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_ticket_archive_guard ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_archive_guard BEFORE UPDATE ON public.support_tickets
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_archive_guard();

CREATE OR REPLACE FUNCTION public.pyroguard_ticket_archive_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
        INSERT INTO public.support_ticket_events(ticket_id, actor_id, action, changes)
        VALUES (NEW.id, auth.uid(), 'archived', jsonb_build_object('archived_at', NEW.archived_at));
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_ticket_archive_audit ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_archive_audit AFTER UPDATE ON public.support_tickets
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_archive_audit();

-- Deleting tickets is blocked. To delete on purpose (e.g. clearing test data),
-- run inside ONE transaction:   SET LOCAL pyroguard.allow_ticket_delete = 'on';
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_no_delete()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF current_setting('pyroguard.allow_ticket_delete', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Ticket deletion is disabled; archive the ticket instead';
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_ticket_no_delete ON public.support_tickets;
CREATE TRIGGER pyroguard_ticket_no_delete BEFORE DELETE ON public.support_tickets
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_ticket_no_delete();

-- Visibility enforced by Postgres: owner, head developer, or the assigned admin.
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_ticket_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_ticket_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ticket_read ON public.support_tickets;
CREATE POLICY ticket_read ON public.support_tickets FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()) OR public.pg_ticket_head()
           OR (public.pg_ticket_admin() AND assigned_to = (SELECT auth.uid())));

DROP POLICY IF EXISTS ticket_admin_update ON public.support_tickets;
CREATE POLICY ticket_admin_update ON public.support_tickets FOR UPDATE TO authenticated
    USING (public.pg_ticket_head() OR (public.pg_ticket_admin() AND assigned_to = (SELECT auth.uid())))
    WITH CHECK (public.pg_ticket_head() OR (public.pg_ticket_admin() AND assigned_to = (SELECT auth.uid())));

-- The ticket sub-query below is itself filtered by ticket_read.
DROP POLICY IF EXISTS ticket_message_read ON public.support_ticket_messages;
CREATE POLICY ticket_message_read ON public.support_ticket_messages FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id)
           AND (NOT internal OR public.pg_ticket_head()
                OR (public.pg_ticket_admin() AND EXISTS (
                        SELECT 1 FROM public.support_tickets t
                         WHERE t.id = ticket_id AND t.assigned_to = (SELECT auth.uid())))));

DROP POLICY IF EXISTS ticket_message_insert ON public.support_ticket_messages;
CREATE POLICY ticket_message_insert ON public.support_ticket_messages FOR INSERT TO authenticated
    WITH CHECK (author_id = (SELECT auth.uid())
                AND EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id)
                AND (NOT internal OR public.pg_ticket_head()
                     OR (public.pg_ticket_admin() AND EXISTS (
                             SELECT 1 FROM public.support_tickets t
                              WHERE t.id = ticket_id AND t.assigned_to = (SELECT auth.uid())))));

DROP POLICY IF EXISTS ticket_events_read ON public.support_ticket_events;
CREATE POLICY ticket_events_read ON public.support_ticket_events FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.support_tickets t WHERE t.id = ticket_id));

-- Read-only analytics; SECURITY INVOKER so RLS above still applies.
CREATE OR REPLACE FUNCTION public.pyroguard_ticket_analytics()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
    SELECT jsonb_build_object(
        'visible_total', count(*),
        'open', count(*) FILTER (WHERE status = 'open'),
        'in_progress', count(*) FILTER (WHERE status = 'in_progress'),
        'resolved', count(*) FILTER (WHERE status IN ('resolved','closed')),
        'ignored', count(*) FILTER (WHERE status = 'ignored'),
        'critical_active', count(*) FILTER (WHERE severity = 'critical' AND status NOT IN ('resolved','closed','ignored')),
        'major_active', count(*) FILTER (WHERE severity = 'major' AND status NOT IN ('resolved','closed','ignored')),
        'unassigned_active', count(*) FILTER (WHERE assigned_to IS NULL AND status NOT IN ('resolved','closed','ignored')),
        'generated_at', now())
      FROM public.support_tickets WHERE archived_at IS NULL;
$$;
REVOKE ALL ON FUNCTION public.pyroguard_ticket_analytics() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pyroguard_ticket_analytics() TO authenticated;

CREATE OR REPLACE FUNCTION public.pyroguard_ticket_daily_actual(days_back integer DEFAULT 14)
RETURNS TABLE(day date, ticket_total bigint, critical_total bigint, resolved_total bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
    SELECT created_at::date, count(*)::bigint,
           count(*) FILTER (WHERE severity = 'critical')::bigint,
           count(*) FILTER (WHERE status IN ('resolved','closed'))::bigint
      FROM public.support_tickets
     WHERE created_at >= now() - make_interval(days => least(greatest(days_back, 1), 366))
       AND archived_at IS NULL
     GROUP BY created_at::date ORDER BY 1;
$$;
REVOKE ALL ON FUNCTION public.pyroguard_ticket_daily_actual(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pyroguard_ticket_daily_actual(integer) TO authenticated;

-- ============================================================================
-- 2. ROOM SENSOR READINGS (ESP32-001: entrance+sala, ESP32-002: kitchen+bedroom)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.pyroguard_room_sensor_readings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    controller_device_id text NOT NULL,
    room_key text NOT NULL,
    temperature numeric,
    humidity numeric,
    smoke_raw numeric,
    smoke_status text,
    flame_detected boolean,
    buzzer_active boolean,
    sampled_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS fire_confirmed boolean;
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS flame_fault boolean;
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS smoke_fault boolean;

DO $rk$
DECLARE c text;
BEGIN
    FOR c IN SELECT con.conname
               FROM pg_constraint con
               JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
              WHERE con.conrelid = 'public.pyroguard_room_sensor_readings'::regclass
                AND con.contype = 'c' AND att.attname IN ('room_key', 'controller_device_id')
    LOOP
        EXECUTE format('ALTER TABLE public.pyroguard_room_sensor_readings DROP CONSTRAINT IF EXISTS %I', c);
    END LOOP;
END;
$rk$;
ALTER TABLE public.pyroguard_room_sensor_readings
    ADD CONSTRAINT pyroguard_room_sensor_readings_room_key_check
    CHECK (room_key IN ('entrance', 'sala', 'kitchen', 'bedroom')) NOT VALID;
ALTER TABLE public.pyroguard_room_sensor_readings
    ADD CONSTRAINT pg_room_controller_check
    CHECK (controller_device_id IN ('ESP32-001', 'ESP32-002')) NOT VALID;

CREATE INDEX IF NOT EXISTS pg_room_sensor_latest_idx
    ON public.pyroguard_room_sensor_readings(controller_device_id, room_key, sampled_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_owner_idx
    ON public.pyroguard_room_sensor_readings(user_id, sampled_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_received_idx
    ON public.pyroguard_room_sensor_readings(controller_device_id, room_key, received_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_received_all_idx
    ON public.pyroguard_room_sensor_readings(received_at);

ALTER TABLE public.pyroguard_room_sensor_readings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pg_room_sensor_read ON public.pyroguard_room_sensor_readings;
CREATE POLICY pg_room_sensor_read ON public.pyroguard_room_sensor_readings
    FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()) OR public.pg_ticket_admin());
GRANT SELECT ON public.pyroguard_room_sensor_readings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.pyroguard_room_sensor_readings TO service_role;

-- Archive tables used by 05_OPTIONAL_ARCHIVE_FALSE_FIRE_SUPABASE.sql. Created
-- (empty) here so the MySQL worker always finds them.
CREATE TABLE IF NOT EXISTS public.pyroguard_room_sensor_readings_archive
    (LIKE public.pyroguard_room_sensor_readings INCLUDING DEFAULTS);
ALTER TABLE public.pyroguard_room_sensor_readings_archive ADD COLUMN IF NOT EXISTS fire_confirmed boolean;
ALTER TABLE public.pyroguard_room_sensor_readings_archive ADD COLUMN IF NOT EXISTS flame_fault boolean;
ALTER TABLE public.pyroguard_room_sensor_readings_archive ADD COLUMN IF NOT EXISTS smoke_fault boolean;
ALTER TABLE public.pyroguard_room_sensor_readings_archive ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now();
CREATE TABLE IF NOT EXISTS public.event_history_archive (LIKE public.event_history INCLUDING DEFAULTS);
ALTER TABLE public.event_history_archive ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.pyroguard_room_sensor_readings_archive ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_history_archive ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_room_sensor_readings_archive, public.event_history_archive FROM anon, authenticated;
GRANT ALL ON public.pyroguard_room_sensor_readings_archive, public.event_history_archive TO service_role;

-- ============================================================================
-- 3. DOOR / WINDOW CURRENT STATE (+ id so the MySQL worker can mirror it)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.pyroguard_contact_current_state (
    device_id text NOT NULL,
    room_key text NOT NULL,
    contact_type text NOT NULL CHECK (contact_type IN ('door', 'window')),
    is_open boolean NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, contact_type),
    CONSTRAINT contact_room_key_valid CHECK (room_key IN ('entrance', 'sala', 'kitchen', 'bedroom'))
);
ALTER TABLE public.pyroguard_contact_current_state ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.pyroguard_contact_current_state ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS pyroguard_contact_current_state_id_key ON public.pyroguard_contact_current_state(id);
CREATE INDEX IF NOT EXISTS pyroguard_contact_current_state_received_idx
    ON public.pyroguard_contact_current_state(received_at DESC);
ALTER TABLE public.pyroguard_contact_current_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_contact_current_state FROM anon;
GRANT SELECT ON public.pyroguard_contact_current_state TO authenticated;
GRANT ALL ON public.pyroguard_contact_current_state TO service_role;
-- (read policy is created in section 4, after the Home 1 helpers exist)
DROP POLICY IF EXISTS pyroguard_contact_authenticated_read ON public.pyroguard_contact_current_state;

-- ============================================================================
-- 4. HOME 1 SHARED ACCESS (verified accounts auto-enrolled; admins can read)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.pyroguard_home_members (
    id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    home_id bigint NOT NULL,
    user_id uuid NOT NULL,
    member_role text NOT NULL DEFAULT 'member',
    membership_status text NOT NULL DEFAULT 'approved',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pyroguard_home_members ADD COLUMN IF NOT EXISTS member_role text;
ALTER TABLE public.pyroguard_home_members ADD COLUMN IF NOT EXISTS membership_status text;
ALTER TABLE public.pyroguard_home_members ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE INDEX IF NOT EXISTS pyroguard_home_members_home_user_idx ON public.pyroguard_home_members(home_id, user_id);
CREATE INDEX IF NOT EXISTS pyroguard_home_members_user_idx ON public.pyroguard_home_members(user_id);
ALTER TABLE public.pyroguard_home_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pyroguard_home_members_read_own ON public.pyroguard_home_members;
CREATE POLICY pyroguard_home_members_read_own ON public.pyroguard_home_members
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()) OR public.pg_ticket_admin());
GRANT SELECT ON public.pyroguard_home_members TO authenticated;
GRANT ALL ON public.pyroguard_home_members TO service_role;

CREATE TABLE IF NOT EXISTS public.pyroguard_shared_home (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    home_id bigint NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pyroguard_shared_home ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_shared_home FROM anon, authenticated;
GRANT ALL ON public.pyroguard_shared_home TO service_role;

DO $home$
DECLARE v_home bigint; v_has_home_col boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM public.pyroguard_shared_home) THEN
        RAISE NOTICE 'Home 1 already configured: homes.id = %', (SELECT home_id FROM public.pyroguard_shared_home);
        RETURN;
    END IF;
    SELECT h.id INTO v_home FROM public.homes h WHERE h.id = 1;
    IF v_home IS NULL THEN
        SELECT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'public' AND table_name = 'devices' AND column_name = 'home_id')
          INTO v_has_home_col;
        IF v_has_home_col THEN
            EXECUTE $q$SELECT home_id FROM public.devices WHERE device_id = 'ESP32-001'$q$ INTO v_home;
        END IF;
    END IF;
    IF v_home IS NULL THEN
        SELECT h.id INTO v_home FROM public.homes h JOIN public.devices d ON d.user_id = h.user_id
         WHERE d.device_id = 'ESP32-001' ORDER BY h.id LIMIT 1;
    END IF;
    IF v_home IS NULL THEN
        RAISE NOTICE 'Home 1 not found yet (no homes.id = 1 and no home for the owner of ESP32-001). '
                     'Create the owner''s home in the app, then run this script again.';
        RETURN;
    END IF;
    INSERT INTO public.pyroguard_shared_home(singleton, home_id) VALUES (true, v_home);
    RAISE NOTICE 'Home 1 = homes.id %', v_home;
END;
$home$;

CREATE OR REPLACE FUNCTION public.pyroguard_shared_home_id()
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT home_id FROM public.pyroguard_shared_home LIMIT 1 $$;

CREATE OR REPLACE FUNCTION public.pyroguard_is_admin_account(p_user uuid, p_email text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF lower(coalesce(p_email, '')) IN (
        'nowel@pyroguard.local', 'sean@pyroguard.local', 'danaya@pyroguard.local',
        'dave@pyroguard.local', 'benedict@pyroguard.local', 'christian@pyroguard.local',
        'danahia@pyroguard.local') THEN
        RETURN true;
    END IF;
    RETURN EXISTS (SELECT 1 FROM public.admin_accounts a
                    WHERE a.user_id = p_user OR lower(a.email) = lower(coalesce(p_email, '#')));
END;
$$;

CREATE OR REPLACE FUNCTION public.pyroguard_enroll_shared_home_member(p_user uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_home bigint := public.pyroguard_shared_home_id();
    v_email text; v_confirmed timestamptz; v_row record; v_role text;
BEGIN
    IF v_home IS NULL THEN RETURN 'no_shared_home'; END IF;
    SELECT u.email, u.email_confirmed_at INTO v_email, v_confirmed FROM auth.users u WHERE u.id = p_user;
    IF NOT FOUND THEN RETURN 'no_user'; END IF;
    IF v_confirmed IS NULL THEN RETURN 'not_verified'; END IF;
    IF public.pyroguard_is_admin_account(p_user, v_email) THEN RETURN 'admin_unchanged'; END IF;

    SELECT m.member_role, m.membership_status INTO v_row
      FROM public.pyroguard_home_members m
     WHERE m.home_id = v_home AND m.user_id = p_user
     ORDER BY (m.membership_status = 'approved') DESC LIMIT 1;
    IF FOUND THEN
        IF v_row.membership_status IS NULL OR lower(v_row.membership_status) IN ('pending','requested','invited') THEN
            UPDATE public.pyroguard_home_members SET membership_status = 'approved', updated_at = now()
             WHERE home_id = v_home AND user_id = p_user
               AND (membership_status IS NULL OR lower(membership_status) IN ('pending','requested','invited'));
            RETURN 'approved_existing';
        END IF;
        RETURN 'kept_' || coalesce(lower(v_row.membership_status), 'unknown');
    END IF;

    FOREACH v_role IN ARRAY
        CASE WHEN EXISTS (SELECT 1 FROM public.homes h WHERE h.id = v_home AND h.user_id = p_user)
             THEN ARRAY['owner'] ELSE ARRAY['member','viewer','family','resident','guest'] END
    LOOP
        BEGIN
            INSERT INTO public.pyroguard_home_members(home_id, user_id, member_role, membership_status)
            VALUES (v_home, p_user, v_role, 'approved');
            RETURN 'enrolled_' || v_role;
        EXCEPTION WHEN check_violation THEN NULL;
        END;
    END LOOP;
    RAISE EXCEPTION 'pyroguard_home_members rejected every member role name; check its CHECK constraint.';
END;
$$;

CREATE OR REPLACE FUNCTION public.pyroguard_has_shared_access()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM public.pyroguard_home_members m
                    WHERE m.user_id = (SELECT auth.uid())
                      AND m.home_id = public.pyroguard_shared_home_id()
                      AND lower(coalesce(m.membership_status, '')) = 'approved');
$$;

CREATE OR REPLACE FUNCTION public.pyroguard_is_shared_device(p_device text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT p_device IN ('ESP32-001','ESP32-002','pyroguard_camera_001')
        OR EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = p_device);
$$;

-- Members OR active admins.
CREATE OR REPLACE FUNCTION public.pyroguard_can_view_hardware()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT public.pyroguard_has_shared_access() OR public.pg_ticket_admin();
$$;

REVOKE ALL ON FUNCTION public.pyroguard_enroll_shared_home_member(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pyroguard_is_admin_account(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pyroguard_shared_home_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_has_shared_access() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_is_shared_device(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_can_view_hardware() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_is_admin_account(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_enroll_shared_home_member(uuid) TO service_role;

-- Enroll every verified account now (Google/Facebook sign-ins are verified too).
DO $backfill$
DECLARE r record; v text; counts jsonb := '{}'::jsonb;
BEGIN
    FOR r IN SELECT u.id FROM auth.users u
              WHERE u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL ORDER BY u.created_at
    LOOP
        v := public.pyroguard_enroll_shared_home_member(r.id);
        counts := jsonb_set(counts, ARRAY[v], to_jsonb(coalesce((counts ->> v)::int, 0) + 1));
    END LOOP;
    RAISE NOTICE 'Home 1 enrollment results: %', counts;
END;
$backfill$;

CREATE OR REPLACE FUNCTION public.pyroguard_auto_enroll_shared_home()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.email_confirmed_at IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.email_confirmed_at IS NULL) THEN
        BEGIN
            PERFORM public.pyroguard_enroll_shared_home_member(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'PyroGuard Home 1 auto-enrollment failed for %: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_auto_enroll_shared_home ON auth.users;
CREATE TRIGGER pyroguard_auto_enroll_shared_home
    AFTER INSERT OR UPDATE OF email_confirmed_at ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_auto_enroll_shared_home();

-- Register ESP32-002 under the Home 1 hardware owner if missing.
DO $esp2$
DECLARE v_owner uuid; v_has_home_col boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM public.devices WHERE device_id = 'ESP32-002') THEN
        RAISE NOTICE 'ESP32-002 already registered (unchanged).'; RETURN;
    END IF;
    SELECT user_id INTO v_owner FROM public.devices WHERE device_id = 'ESP32-001';
    IF v_owner IS NULL THEN
        SELECT user_id INTO v_owner FROM public.homes WHERE id = public.pyroguard_shared_home_id();
    END IF;
    IF v_owner IS NULL THEN RAISE NOTICE 'ESP32-002 not registered: Home 1 owner unknown.'; RETURN; END IF;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'devices' AND column_name = 'home_id')
      INTO v_has_home_col;
    BEGIN
        IF v_has_home_col THEN
            EXECUTE $q$INSERT INTO public.devices (user_id, device_id, device_name, device_type, status, home_id)
                       VALUES ($1, 'ESP32-002', 'Batch 2 Controller (Kitchen & Bedroom)', 'ESP32_MAIN', 'registered', $2)$q$
              USING v_owner, public.pyroguard_shared_home_id();
        ELSE
            INSERT INTO public.devices (user_id, device_id, device_name, device_type, status)
            VALUES (v_owner, 'ESP32-002', 'Batch 2 Controller (Kitchen & Bedroom)', 'ESP32_MAIN', 'registered');
        END IF;
        RAISE NOTICE 'ESP32-002 registered for Home 1.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'ESP32-002 could not be registered automatically (%). Register it manually.', SQLERRM;
    END;
END;
$esp2$;

-- Remove the broad "any signed-in user" policies from 20261104_shared_read_only_home1.sql
-- and add member/admin read policies on every hardware table that exists.
DO $read$
DECLARE t text; v_col text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'devices','device_current_state','device_heartbeats','pyroguard_camera_telemetry',
        'system_state','device_commands','ptz_state','ptz_commands','sensor_history','event_history',
        'sensor_readings','pyroguard_room_sensor_readings','pyroguard_contact_current_state',
        'camera_history','camera_events','audio_sessions','pyroguard_camera_registry',
        'pyroguard_camera_health','pyroguard_camera_audio_devices','pyroguard_camera_commands',
        'pyroguard_incidents'
    ] LOOP
        IF to_regclass(format('public.%I', t)) IS NULL THEN CONTINUE; END IF;
        EXECUTE format('DROP POLICY IF EXISTS pyroguard_shared_authenticated_read ON public.%I', t);

        SELECT c.column_name INTO v_col FROM information_schema.columns c
         WHERE c.table_schema = 'public' AND c.table_name = t
           AND c.column_name IN ('controller_device_id','target_device_id','device_id','camera_device_id')
         ORDER BY array_position(ARRAY['controller_device_id','target_device_id','device_id','camera_device_id'], c.column_name::text)
         LIMIT 1;
        IF v_col IS NULL THEN RAISE NOTICE 'Skipped %: no device column.', t; CONTINUE; END IF;

        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS pyroguard_shared_home_read ON public.%I', t);
        EXECUTE format('CREATE POLICY pyroguard_shared_home_read ON public.%I FOR SELECT TO authenticated '
                       'USING (public.pyroguard_can_view_hardware() AND public.pyroguard_is_shared_device(%I))', t, v_col);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
        EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    END LOOP;
END;
$read$;

DROP POLICY IF EXISTS pyroguard_shared_home_read ON public.homes;
CREATE POLICY pyroguard_shared_home_read ON public.homes FOR SELECT TO authenticated
    USING (id = public.pyroguard_shared_home_id() AND public.pyroguard_can_view_hardware());
GRANT SELECT ON public.homes TO authenticated;

DO $safety$
BEGIN
    IF to_regclass('public.safety_setups') IS NOT NULL THEN
        DROP POLICY IF EXISTS pyroguard_shared_home_read ON public.safety_setups;
        CREATE POLICY pyroguard_shared_home_read ON public.safety_setups FOR SELECT TO authenticated
            USING (public.pyroguard_can_view_hardware()
                   AND user_id IN (SELECT d.user_id FROM public.devices d WHERE d.device_id = 'ESP32-001'));
    END IF;
END;
$safety$;

-- Members can SEND arm/disarm, buzzer and PTZ commands (never mark them applied).
DROP POLICY IF EXISTS pyroguard_shared_home_command ON public.device_commands;
CREATE POLICY pyroguard_shared_home_command ON public.device_commands FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT auth.uid())
                AND coalesce(requested_by, (SELECT auth.uid())) = (SELECT auth.uid())
                AND status = 'pending'
                AND public.pyroguard_has_shared_access()
                AND public.pyroguard_is_shared_device(target_device_id));
GRANT SELECT, INSERT ON public.device_commands TO authenticated;

DROP POLICY IF EXISTS pyroguard_shared_home_command ON public.ptz_commands;
CREATE POLICY pyroguard_shared_home_command ON public.ptz_commands FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT auth.uid()) AND status = 'created'
                AND public.pyroguard_has_shared_access()
                AND public.pyroguard_is_shared_device(device_id));
GRANT SELECT, INSERT ON public.ptz_commands TO authenticated;

DO $seq$
DECLARE s record;
BEGIN
    FOR s IN SELECT pg_get_serial_sequence(format('public.%I', t), 'id') AS seq
               FROM unnest(ARRAY['device_commands','ptz_commands','camera_events','camera_history','event_history']) t
              WHERE to_regclass(format('public.%I', t)) IS NOT NULL
    LOOP
        IF s.seq IS NOT NULL THEN
            EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO authenticated, service_role', s.seq);
        END IF;
    END LOOP;
END;
$seq$;

-- ============================================================================
-- 5. CRITICAL_FIRE INCIDENTS - only from firmware-confirmed fire, two readings
-- ============================================================================
CREATE OR REPLACE FUNCTION public.pyroguard_record_multisensor_room_alert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    previous public.pyroguard_room_sensor_readings%ROWTYPE;
    event_key text; label text;
BEGIN
    IF NEW.controller_device_id NOT IN ('ESP32-001','ESP32-002')
       OR NEW.received_at IS NULL
       OR NEW.received_at < now() - interval '30 seconds'
       OR NEW.received_at > now() + interval '10 seconds' THEN
        RETURN NEW;
    END IF;
    IF NOT (coalesce(NEW.flame_fault, false) = false AND coalesce(NEW.smoke_fault, false) = false
            AND NEW.fire_confirmed IS TRUE) THEN
        RETURN NEW;
    END IF;
    SELECT * INTO previous FROM public.pyroguard_room_sensor_readings p
     WHERE p.controller_device_id = NEW.controller_device_id AND p.room_key = NEW.room_key
       AND p.id <> NEW.id AND p.received_at < NEW.received_at
       AND p.received_at >= NEW.received_at - interval '30 seconds'
     ORDER BY p.received_at DESC LIMIT 1;
    IF NOT FOUND THEN RETURN NEW; END IF;
    IF NOT (coalesce(previous.flame_fault, false) = false AND coalesce(previous.smoke_fault, false) = false
            AND previous.fire_confirmed IS TRUE) THEN
        RETURN NEW;
    END IF;
    label := CASE NEW.room_key WHEN 'entrance' THEN 'Entrance' WHEN 'sala' THEN 'Sala'
                               WHEN 'kitchen' THEN 'Kitchen' WHEN 'bedroom' THEN 'Bedroom'
                               ELSE NEW.room_key END;
    event_key := NEW.controller_device_id || ':FIRE:' || NEW.room_key || ':' ||
                 floor(extract(epoch FROM NEW.received_at) / 300)::bigint::text;
    INSERT INTO public.event_history
        (user_id, device_id, event_type, record_key, message, severity, payload_json, mysql_synced, created_at)
    VALUES
        (NEW.user_id, NEW.controller_device_id, 'CRITICAL_FIRE', event_key,
         'Fire confirmed by smoke + flame sensors in ' || label ||
         ' (two consecutive readings). Verify and call BFP if needed.', 2,
         jsonb_build_object('room_key', NEW.room_key, 'room_label', label,
                            'source', 'pyroguard_room_sensor_readings',
                            'first_received_at', previous.received_at, 'last_received_at', NEW.received_at,
                            'smoke_status', NEW.smoke_status, 'flame_detected', NEW.flame_detected,
                            'fire_confirmed', NEW.fire_confirmed, 'temperature', NEW.temperature),
         false, NEW.received_at)
    ON CONFLICT (record_key) DO NOTHING;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_multisensor_incident_on_room_insert ON public.pyroguard_room_sensor_readings;
CREATE TRIGGER pyroguard_multisensor_incident_on_room_insert
    AFTER INSERT ON public.pyroguard_room_sensor_readings
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_record_multisensor_room_alert();

-- ============================================================================
-- 6. STORAGE BUCKETS
--    incident-media : camera photos (app snapshots + camera-ingest uploads).
--                     Public read because the app shows them with getPublicUrl().
--    assets         : email-template logo (assets/logo.png), public read.
-- ============================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('incident-media', 'incident-media', true, 5242880, ARRAY['image/jpeg','image/png','image/webp']),
       ('assets', 'assets', true, 2097152, ARRAY['image/png','image/jpeg','image/svg+xml','image/webp'])
ON CONFLICT (id) DO UPDATE
   SET public = EXCLUDED.public,
       file_size_limit = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS pyroguard_incident_media_read ON storage.objects;
CREATE POLICY pyroguard_incident_media_read ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'incident-media' AND public.pyroguard_can_view_hardware());

-- App uploads go into the camera folder: pyroguard_camera_001/<timestamp>.jpg
DROP POLICY IF EXISTS pyroguard_incident_media_insert ON storage.objects;
CREATE POLICY pyroguard_incident_media_insert ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'incident-media'
                AND (storage.foldername(name))[1] = 'pyroguard_camera_001'
                AND public.pyroguard_can_view_hardware());

DROP POLICY IF EXISTS pyroguard_incident_media_admin_delete ON storage.objects;
CREATE POLICY pyroguard_incident_media_admin_delete ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'incident-media' AND public.pg_ticket_head());

DROP POLICY IF EXISTS pyroguard_assets_admin_write ON storage.objects;
CREATE POLICY pyroguard_assets_admin_write ON storage.objects FOR ALL TO authenticated
    USING (bucket_id = 'assets' AND public.pg_ticket_admin())
    WITH CHECK (bucket_id = 'assets' AND public.pg_ticket_admin());

-- ============================================================================
-- 7. INCIDENT EMAILS (sent by the incident-email Edge Function)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.pyroguard_incident_emails (
    id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    event_record_key text NOT NULL UNIQUE,
    device_id text,
    event_type text NOT NULL,
    recipients text[] NOT NULL DEFAULT '{}',
    photo_path text,
    provider text,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','skipped','failed')),
    error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    mysql_synced boolean NOT NULL DEFAULT false,
    mysql_synced_at timestamptz,
    last_sync_error text
);
ALTER TABLE public.pyroguard_incident_emails ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_incident_emails FROM anon, authenticated;
GRANT SELECT ON public.pyroguard_incident_emails TO authenticated;
DROP POLICY IF EXISTS pyroguard_incident_emails_admin_read ON public.pyroguard_incident_emails;
CREATE POLICY pyroguard_incident_emails_admin_read ON public.pyroguard_incident_emails
    FOR SELECT TO authenticated USING (public.pg_ticket_admin());
GRANT ALL ON public.pyroguard_incident_emails TO service_role;

-- Camera photos are looked up by camera + time when the email is built.
CREATE INDEX IF NOT EXISTS camera_events_device_time_idx ON public.camera_events(device_id, created_at DESC);


-- ============================================================================
-- 7b. SINGLE CAMERA (Camera 1, two-way audio) - Camera 2 monitoring removed
-- ============================================================================
-- Remove leftovers of the old Camera 2 / Camera 2 audio board (registry rows,
-- telemetry). Photos and history rows are kept as evidence.
DO $cam2$
BEGIN
    IF to_regclass('public.pyroguard_camera_registry') IS NOT NULL THEN
        DELETE FROM public.pyroguard_camera_registry WHERE device_id IN ('pyroguard_camera_002','pyroguard_audio_002');
    END IF;
    DELETE FROM public.pyroguard_camera_telemetry WHERE camera_device_id IN ('pyroguard_camera_002','pyroguard_audio_002');
    IF to_regclass('public.pyroguard_camera_audio_devices') IS NOT NULL THEN
        DROP TABLE public.pyroguard_camera_audio_devices;   -- only Camera 2 used it
    END IF;
END;
$cam2$;

-- The app's camera card shows ONLINE from pyroguard_camera_registry.last_seen_at,
-- but nothing wrote that column. Every camera heartbeat (camera-ingest, or
-- ESP32-001 relaying Camera 1 status through device-command) now updates it.
DO $reg$
BEGIN
    IF to_regclass('public.pyroguard_camera_registry') IS NULL THEN
        CREATE TABLE public.pyroguard_camera_registry (
            device_id text PRIMARY KEY, display_name text NOT NULL, model text, ip_address text,
            controller_device_id text, enabled boolean NOT NULL DEFAULT true,
            ptz_enabled boolean NOT NULL DEFAULT false, audio_enabled boolean NOT NULL DEFAULT false,
            last_seen_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now());
        ALTER TABLE public.pyroguard_camera_registry ENABLE ROW LEVEL SECURITY;
        CREATE POLICY pyroguard_signed_in_read ON public.pyroguard_camera_registry FOR SELECT TO authenticated USING (true);
        GRANT SELECT ON public.pyroguard_camera_registry TO authenticated;
        GRANT ALL ON public.pyroguard_camera_registry TO service_role;
    END IF;
END;
$reg$;
INSERT INTO public.pyroguard_camera_registry (device_id, display_name, model, ip_address, controller_device_id, enabled, ptz_enabled, audio_enabled)
VALUES ('pyroguard_camera_001', 'Camera 1 - Entrance & Sala (two-way audio)', 'DFRobot DFR1154', '192.168.8.99', 'ESP32-001', true, true, true)
ON CONFLICT (device_id) DO UPDATE SET ptz_enabled = true, audio_enabled = true, enabled = true;

CREATE OR REPLACE FUNCTION public.pyroguard_camera_seen()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF lower(coalesce(NEW.status, '')) = 'online' THEN
        UPDATE public.pyroguard_camera_registry
           SET last_seen_at = now(),
               ip_address = CASE WHEN NEW.camera_ip ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN NEW.camera_ip ELSE ip_address END,
               updated_at = now()
         WHERE device_id = NEW.camera_device_id;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pyroguard_camera_seen ON public.pyroguard_camera_telemetry;
CREATE TRIGGER pyroguard_camera_seen AFTER INSERT OR UPDATE ON public.pyroguard_camera_telemetry
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_camera_seen();

-- ============================================================================
-- 8. REALTIME (live updates in the app)
-- ============================================================================
DO $realtime$
DECLARE t text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH t IN ARRAY ARRAY['device_current_state','device_heartbeats','pyroguard_camera_telemetry',
                                 'system_state','device_commands','ptz_state','event_history',
                                 'pyroguard_room_sensor_readings','pyroguard_contact_current_state',
                                 'camera_events','pyroguard_camera_registry','support_tickets','support_ticket_messages']
        LOOP
            IF to_regclass(format('public.%I', t)) IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
            END IF;
        END LOOP;
    END IF;
END;
$realtime$;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- (pyroguard_contact_current_state gets its member/admin read policy from the loop in section 4.)

-- Next: run 03_VERIFY_SUPABASE.sql (read-only).
