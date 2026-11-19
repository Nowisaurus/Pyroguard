-- ============================================================================
-- PYROGUARD APPLICATION SYSTEM
-- CONSOLIDATED SUPABASE POSTGRESQL UPDATE
-- DATE: 2026-10-22
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. VERIFY REQUIRED CORE TABLES
-- ============================================================================

DO $$
DECLARE
    missing_tables TEXT;
BEGIN
    SELECT string_agg(required.name, ', ' ORDER BY required.name)
    INTO missing_tables
    FROM unnest(ARRAY[
        'admin_accounts',
        'profiles',
        'account_identities',
        'homes',
        'stakeholders',
        'emergency_contacts',
        'safety_setups',
        'user_preferences',
        'devices',
        'device_current_state',
        'device_heartbeats',
        'pyroguard_camera_telemetry',
        'system_state',
        'device_commands',
        'ptz_state',
        'ptz_commands',
        'sensor_history',
        'event_history',
        'camera_history',
        'camera_events',
        'audio_sessions',
        'mirror_records',
        'dual_record_ledger',
        'emergency_action_logs',
        'sensor_readings'
    ]) AS required(name)
    WHERE to_regclass(format('public.%I', required.name)) IS NULL;

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing core tables: %. Apply the original complete Supabase SECTION 1 first.',
            missing_tables;
    END IF;
END;
$$;


-- ============================================================================
-- 2. VERIFY REQUIRED ROLE FUNCTION
-- ============================================================================

DO $$
BEGIN
    IF to_regprocedure(
        'public.pyroguard_verified_role(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Missing pyroguard_verified_role(uuid). Apply the original compiled Supabase schema first.';
    END IF;
END;
$$;


-- ============================================================================
-- 3. ACCOUNT AND DEVICE COMPATIBILITY
-- ============================================================================

ALTER TABLE public.account_identities
ADD COLUMN IF NOT EXISTS event TEXT;

ALTER TABLE public.account_identities
ADD COLUMN IF NOT EXISTS logged_in_at TIMESTAMPTZ;

ALTER TABLE public.account_identities
ADD COLUMN IF NOT EXISTS logged_out_at TIMESTAMPTZ;

ALTER TABLE public.ptz_state
ADD COLUMN IF NOT EXISTS last_device_at TIMESTAMPTZ;

ALTER TABLE public.event_history
ADD COLUMN IF NOT EXISTS record_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS
event_history_record_key_unique
ON public.event_history(record_key);


-- ============================================================================
-- 4. ADMINISTRATOR REGISTRY PROTECTION
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_admin_accounts_user_id
ON public.admin_accounts(user_id);

ALTER TABLE public.admin_accounts
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.profiles
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.account_identities
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.admin_accounts
FROM anon, authenticated;

GRANT SELECT ON public.admin_accounts
TO authenticated;

DROP POLICY IF EXISTS admin_read_own_account
ON public.admin_accounts;

CREATE POLICY admin_read_own_account
ON public.admin_accounts
FOR SELECT
TO authenticated
USING (
    user_id = (SELECT auth.uid())
);


DROP POLICY IF EXISTS profiles_read_own
ON public.profiles;

CREATE POLICY profiles_read_own
ON public.profiles
FOR SELECT
TO authenticated
USING (
    user_id = (SELECT auth.uid())
);


DROP POLICY IF EXISTS identities_read_own
ON public.account_identities;

CREATE POLICY identities_read_own
ON public.account_identities
FOR SELECT
TO authenticated
USING (
    user_id = (SELECT auth.uid())
);


-- ============================================================================
-- 5. VERIFY THE FOUR EXPECTED ADMIN AUTH ACCOUNTS
-- NO ACCOUNTS ARE CREATED OR REASSIGNED.
-- ============================================================================

DO $$
DECLARE
    missing_count INTEGER;
    conflict_count INTEGER;
BEGIN

    WITH expected(admin_order, email, user_id) AS (
        VALUES
        (
            1,
            'nowel@pyroguard.local',
            'b146fbd3-6ee6-44b5-aae9-f296005ca38b'::UUID
        ),
        (
            2,
            'danaya@pyroguard.local',
            'f1882d25-7567-4b81-8e37-202ec276c23b'::UUID
        ),
        (
            3,
            'sean@pyroguard.local',
            '6fd0f1ca-1bac-4814-b9f0-6eb8ba394acf'::UUID
        ),
        (
            4,
            'dave@pyroguard.local',
            'fa2cb844-9e43-4aa3-b3de-989fccb7c64d'::UUID
        )
    )
    SELECT COUNT(*)
    INTO missing_count
    FROM expected e
    LEFT JOIN auth.users u
        ON u.id = e.user_id
       AND LOWER(u.email) = e.email
    WHERE u.id IS NULL;

    IF missing_count > 0 THEN
        RAISE EXCEPTION
            'Missing/mismatched administrator Auth accounts: %. Check Authentication > Users.',
            missing_count;
    END IF;


    WITH expected(admin_order, email, user_id) AS (
        VALUES
        (
            1,
            'nowel@pyroguard.local',
            'b146fbd3-6ee6-44b5-aae9-f296005ca38b'::UUID
        ),
        (
            2,
            'danaya@pyroguard.local',
            'f1882d25-7567-4b81-8e37-202ec276c23b'::UUID
        ),
        (
            3,
            'sean@pyroguard.local',
            '6fd0f1ca-1bac-4814-b9f0-6eb8ba394acf'::UUID
        ),
        (
            4,
            'dave@pyroguard.local',
            'fa2cb844-9e43-4aa3-b3de-989fccb7c64d'::UUID
        )
    )
    SELECT COUNT(*)
    INTO conflict_count
    FROM public.admin_accounts a
    WHERE NOT EXISTS (
        SELECT 1
        FROM expected e
        WHERE a.admin_order = e.admin_order
          AND a.user_id = e.user_id
          AND LOWER(a.email) = e.email
    );

    IF conflict_count > 0 THEN
        RAISE EXCEPTION
            'Existing administrator registry differs from expected identities. Manual review required.';
    END IF;

END;
$$;


-- ============================================================================
-- 6. REGISTER ONLY VERIFIED, NONCONFLICTING ADMINISTRATORS
-- EXISTING DISABLED ACCOUNTS ARE NOT REACTIVATED.
-- ============================================================================

INSERT INTO public.admin_accounts (
    admin_order,
    user_id,
    email,
    display_name,
    admin_role,
    admin_reference_code,
    active
)
VALUES
(
    1,
    'b146fbd3-6ee6-44b5-aae9-f296005ca38b',
    'nowel@pyroguard.local',
    'Nowel',
    'head_developer',
    'PG-ADMIN-001',
    TRUE
),
(
    2,
    'f1882d25-7567-4b81-8e37-202ec276c23b',
    'danaya@pyroguard.local',
    'Danaya',
    'administrator',
    'PG-ADMIN-002',
    TRUE
),
(
    3,
    '6fd0f1ca-1bac-4814-b9f0-6eb8ba394acf',
    'sean@pyroguard.local',
    'Sean',
    'administrator',
    'PG-ADMIN-003',
    TRUE
),
(
    4,
    'fa2cb844-9e43-4aa3-b3de-989fccb7c64d',
    'dave@pyroguard.local',
    'Dave',
    'administrator',
    'PG-ADMIN-004',
    TRUE
)
ON CONFLICT (admin_order)
DO NOTHING;


-- ============================================================================
-- 7. CREATE MISSING APPLICATION RECORDS FOR VERIFIED ADMINS
-- EXISTING ROLES AND STATUSES ARE PRESERVED.
-- ============================================================================

INSERT INTO public.profiles (
    id,
    user_id,
    full_name,
    email,
    account_role,
    account_status,
    created_at,
    updated_at
)
SELECT
    u.id,
    u.id,
    a.display_name,
    u.email,
    a.admin_role,
    'active',
    u.created_at,
    NOW()
FROM public.admin_accounts a
JOIN auth.users u
    ON u.id = a.user_id
WHERE a.active = TRUE
ON CONFLICT (user_id)
DO NOTHING;


INSERT INTO public.account_identities (
    user_id,
    email,
    display_name,
    account_role,
    auth_provider,
    email_confirmed,
    account_status,
    mysql_synced,
    created_at,
    updated_at
)
SELECT
    u.id,
    u.email,
    a.display_name,
    a.admin_role,
    COALESCE(u.raw_app_meta_data ->> 'provider', 'email'),
    u.email_confirmed_at IS NOT NULL,
    'active',
    FALSE,
    u.created_at,
    NOW()
FROM public.admin_accounts a
JOIN auth.users u
    ON u.id = a.user_id
WHERE a.active = TRUE
ON CONFLICT (user_id)
DO NOTHING;


-- ============================================================================
-- 8. VERIFIED USER ROLE RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pyroguard_my_role()
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.pyroguard_verified_role(auth.uid());
$$;

REVOKE ALL
ON FUNCTION public.pyroguard_my_role()
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.pyroguard_my_role()
TO authenticated;


-- ============================================================================
-- 9. SESSION IDENTITY REPAIR
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pyroguard_save_session(
    session_event TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    uid UUID := auth.uid();
    u auth.users%ROWTYPE;
    a public.admin_accounts%ROWTYPE;
    role_name TEXT;
    now_at TIMESTAMPTZ := NOW();
    result JSONB;
BEGIN

    IF uid IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF session_event IS NOT NULL
       AND session_event NOT IN (
           'homeowner_login',
           'homeowner_logout',
           'admin_login',
           'admin_logout'
       )
    THEN
        RAISE EXCEPTION 'Invalid session event';
    END IF;

    SELECT *
    INTO u
    FROM auth.users
    WHERE id = uid;

    IF u.id IS NULL
       OR (
           u.banned_until IS NOT NULL
           AND u.banned_until > now_at
       )
    THEN
        RAISE EXCEPTION 'Account unavailable';
    END IF;

    SELECT *
    INTO a
    FROM public.admin_accounts
    WHERE user_id = uid;

    IF a.user_id IS NOT NULL THEN

        IF NOT a.active
           OR LOWER(a.email) <> LOWER(u.email)
           OR a.admin_role NOT IN (
               'administrator',
               'head_developer'
           )
        THEN
            RAISE EXCEPTION
                'Administrator registry mismatch';
        END IF;

        role_name := a.admin_role;

    ELSE

        IF COALESCE(
            u.raw_app_meta_data ->> 'role',
            ''
        ) IN (
            'administrator',
            'head_developer'
        )
        OR COALESCE(
            u.raw_app_meta_data ->> 'pyroguard_admin',
            'false'
        ) = 'true'
        THEN
            RAISE EXCEPTION
                'Administrator registry required';
        END IF;

        role_name := 'homeowner';

    END IF;

    IF role_name = 'homeowner'
       AND u.email_confirmed_at IS NULL
    THEN
        RAISE EXCEPTION
            'Confirm your email before completing registration';
    END IF;

    IF session_event IS NOT NULL
       AND (
           (
               role_name = 'homeowner'
               AND session_event LIKE 'admin_%'
           )
           OR
           (
               role_name <> 'homeowner'
               AND session_event LIKE 'homeowner_%'
           )
       )
    THEN
        RAISE EXCEPTION 'Session role mismatch';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE user_id = uid
          AND (
              account_status <> 'active'
              OR account_role <> role_name
          )
    )
    OR EXISTS (
        SELECT 1
        FROM public.account_identities
        WHERE user_id = uid
          AND (
              account_status <> 'active'
              OR account_role <> role_name
          )
    )
    THEN
        RAISE EXCEPTION
            'Account role/status requires administrator repair';
    END IF;

    INSERT INTO public.profiles (
        id,
        user_id,
        email,
        full_name,
        phone,
        account_role,
        account_status,
        created_at,
        updated_at
    )
    VALUES (
        uid,
        uid,
        u.email,
        COALESCE(
            a.display_name,
            u.raw_user_meta_data ->> 'full_name',
            u.raw_user_meta_data ->> 'name'
        ),
        u.raw_user_meta_data ->> 'phone_number',
        role_name,
        'active',
        u.created_at,
        now_at
    )
    ON CONFLICT (user_id)
    DO NOTHING;

    INSERT INTO public.account_identities (
        user_id,
        email,
        display_name,
        phone,
        account_role,
        account_status,
        auth_provider,
        email_confirmed,
        event,
        logged_in_at,
        logged_out_at,
        mysql_synced,
        created_at,
        updated_at
    )
    VALUES (
        uid,
        u.email,
        COALESCE(
            a.display_name,
            u.raw_user_meta_data ->> 'full_name',
            u.raw_user_meta_data ->> 'name'
        ),
        u.raw_user_meta_data ->> 'phone_number',
        role_name,
        'active',
        COALESCE(
            u.raw_app_meta_data ->> 'provider',
            'email'
        ),
        u.email_confirmed_at IS NOT NULL,
        session_event,
        CASE
            WHEN session_event LIKE '%_login'
            THEN now_at
        END,
        CASE
            WHEN session_event LIKE '%_logout'
            THEN now_at
        END,
        FALSE,
        u.created_at,
        now_at
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
        email = EXCLUDED.email,
        email_confirmed = EXCLUDED.email_confirmed,
        event = COALESCE(
            EXCLUDED.event,
            public.account_identities.event
        ),
        logged_in_at = COALESCE(
            EXCLUDED.logged_in_at,
            public.account_identities.logged_in_at
        ),
        logged_out_at = COALESCE(
            EXCLUDED.logged_out_at,
            public.account_identities.logged_out_at
        ),
        mysql_synced = FALSE,
        updated_at = now_at;

    SELECT TO_JSONB(i)
    INTO result
    FROM public.account_identities i
    WHERE i.user_id = uid;

    RETURN result;

END;
$$;

REVOKE ALL
ON FUNCTION public.pyroguard_save_session(TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.pyroguard_save_session(TEXT)
TO authenticated;


-- ============================================================================
-- 10. SERVICE ROLE ACCESS TO EXISTING APPLICATION TABLES
-- ============================================================================

DO $$
DECLARE
    tab TEXT;
    seq TEXT;
BEGIN

    FOREACH tab IN ARRAY ARRAY[
        'admin_accounts',
        'profiles',
        'account_identities',
        'homes',
        'stakeholders',
        'emergency_contacts',
        'safety_setups',
        'user_preferences',
        'devices',
        'device_current_state',
        'device_heartbeats',
        'pyroguard_camera_telemetry',
        'system_state',
        'device_commands',
        'ptz_state',
        'ptz_commands',
        'sensor_history',
        'event_history',
        'camera_history',
        'camera_events',
        'audio_sessions',
        'mirror_records',
        'dual_record_ledger',
        'emergency_action_logs',
        'sensor_readings'
    ]
    LOOP

        EXECUTE FORMAT(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO service_role',
            tab
        );

        seq := pg_get_serial_sequence(
            FORMAT('public.%I', tab),
            'id'
        );

        IF seq IS NOT NULL THEN
            EXECUTE FORMAT(
                'GRANT USAGE, SELECT ON SEQUENCE %s TO service_role',
                seq
            );
        END IF;

    END LOOP;

END;
$$;


-- ============================================================================
-- 11. HOMEOWNER PROFILE COMPATIBILITY
-- ============================================================================

GRANT SELECT, INSERT, UPDATE
ON public.profiles,
   public.account_identities,
   public.mirror_records,
   public.dual_record_ledger
TO authenticated;


DROP POLICY IF EXISTS pyroguard_profile_compat
ON public.profiles;

CREATE POLICY pyroguard_profile_compat
ON public.profiles
FOR ALL
TO authenticated
USING (
    user_id = auth.uid()
    AND public.pyroguard_verified_role() = 'homeowner'
)
WITH CHECK (
    user_id = auth.uid()
    AND public.pyroguard_verified_role() = 'homeowner'
    AND account_role = 'homeowner'
    AND account_status = 'active'
);


DROP POLICY IF EXISTS pyroguard_identity_read_compat
ON public.account_identities;

CREATE POLICY pyroguard_identity_read_compat
ON public.account_identities
FOR SELECT
TO authenticated
USING (
    user_id = auth.uid()
);


DROP POLICY IF EXISTS pyroguard_mirror_compat
ON public.mirror_records;

CREATE POLICY pyroguard_mirror_compat
ON public.mirror_records
FOR ALL
TO authenticated
USING (
    user_id = auth.uid()
    AND public.pyroguard_verified_role()
        IN ('homeowner', 'administrator')
)
WITH CHECK (
    user_id = auth.uid()
    AND public.pyroguard_verified_role()
        IN ('homeowner', 'administrator')
);


DROP POLICY IF EXISTS pyroguard_ledger_compat
ON public.dual_record_ledger;

CREATE POLICY pyroguard_ledger_compat
ON public.dual_record_ledger
FOR ALL
TO authenticated
USING (
    user_id = auth.uid()
    AND public.pyroguard_verified_role()
        IN ('homeowner', 'administrator')
)
WITH CHECK (
    user_id = auth.uid()
    AND public.pyroguard_verified_role()
        IN ('homeowner', 'administrator')
);


-- ============================================================================
-- 12. SUPPORT-TICKET AUTHORIZATION FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pg_ticket_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.admin_accounts
        WHERE user_id = auth.uid()
          AND active IS TRUE
          AND admin_role IN (
              'administrator',
              'head_developer'
          )
    );
$$;

REVOKE ALL
ON FUNCTION public.pg_ticket_admin()
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.pg_ticket_admin()
TO authenticated, service_role;


-- ============================================================================
-- 13. SUPPORT TICKETS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.support_tickets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    user_id UUID NOT NULL
        REFERENCES auth.users(id) ON DELETE CASCADE,

    title VARCHAR(160) NOT NULL
        CHECK (LENGTH(TRIM(title)) BETWEEN 5 AND 160),

    description TEXT NOT NULL
        CHECK (LENGTH(TRIM(description)) BETWEEN 10 AND 5000),

    category VARCHAR(32) NOT NULL DEFAULT 'problem'
        CHECK (
            category IN (
                'bug',
                'problem',
                'device',
                'alarm',
                'account',
                'other'
            )
        ),

    severity VARCHAR(16) NOT NULL DEFAULT 'normal'
        CHECK (
            severity IN (
                'low',
                'normal',
                'major',
                'critical'
            )
        ),

    status VARCHAR(24) NOT NULL DEFAULT 'open'
        CHECK (
            status IN (
                'open',
                'in_progress',
                'waiting_for_user',
                'resolved',
                'closed'
            )
        ),

    assigned_to UUID
        REFERENCES auth.users(id) ON DELETE SET NULL,

    resolution_notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,

    mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
    mysql_synced_at TIMESTAMPTZ,
    last_sync_error TEXT
);


CREATE INDEX IF NOT EXISTS support_tickets_user_idx
ON public.support_tickets(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS support_tickets_queue_idx
ON public.support_tickets(status, severity, created_at);


-- ============================================================================
-- 14. SUPPORT-TICKET MESSAGES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.support_ticket_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    ticket_id UUID NOT NULL
        REFERENCES public.support_tickets(id) ON DELETE CASCADE,

    author_id UUID NOT NULL
        REFERENCES auth.users(id) ON DELETE CASCADE,

    message TEXT NOT NULL
        CHECK (LENGTH(TRIM(message)) BETWEEN 1 AND 5000),

    internal BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
    mysql_synced_at TIMESTAMPTZ,
    last_sync_error TEXT
);


CREATE INDEX IF NOT EXISTS support_ticket_messages_ticket_idx
ON public.support_ticket_messages(ticket_id, created_at);


-- ============================================================================
-- 15. SUPPORT-TICKET AUDIT EVENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.support_ticket_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    ticket_id UUID NOT NULL
        REFERENCES public.support_tickets(id) ON DELETE CASCADE,

    actor_id UUID,
    action VARCHAR(48) NOT NULL,

    changes JSONB NOT NULL DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
    mysql_synced_at TIMESTAMPTZ,
    last_sync_error TEXT
);


CREATE INDEX IF NOT EXISTS support_ticket_events_ticket_idx
ON public.support_ticket_events(ticket_id, created_at);


-- ============================================================================
-- 16. SUPPORT-TICKET GUARD
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pg_ticket_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN

    IF TG_OP = 'INSERT' THEN

        IF auth.uid() IS NULL
           OR (
               NOT public.pg_ticket_admin()
               AND NEW.user_id IS DISTINCT FROM auth.uid()
           )
        THEN
            RAISE EXCEPTION 'Only the owner can file a ticket';
        END IF;

        IF NOT public.pg_ticket_admin() THEN
            NEW.severity := 'normal';
            NEW.status := 'open';
            NEW.assigned_to := NULL;
            NEW.resolution_notes := NULL;
            NEW.resolved_at := NULL;
        END IF;

    ELSE

        IF NOT public.pg_ticket_admin() THEN
            RAISE EXCEPTION
                'Only administrators may update ticket fields';
        END IF;

        IF NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.created_at IS DISTINCT FROM OLD.created_at
           OR NEW.id IS DISTINCT FROM OLD.id
        THEN
            RAISE EXCEPTION
                'Ticket identity is immutable';
        END IF;

    END IF;

    IF NEW.status IN ('resolved', 'closed')
       AND NEW.resolved_at IS NULL
    THEN
        NEW.resolved_at := NOW();
    END IF;

    IF NEW.status NOT IN ('resolved', 'closed') THEN
        NEW.resolved_at := NULL;
    END IF;

    NEW.updated_at := NOW();

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS support_tickets_guard
ON public.support_tickets;

CREATE TRIGGER support_tickets_guard
BEFORE INSERT OR UPDATE
ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.pg_ticket_guard();


-- ============================================================================
-- 17. SUPPORT-TICKET MESSAGE GUARD
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pg_ticket_message_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    owner_id UUID;
BEGIN

    SELECT user_id
    INTO owner_id
    FROM public.support_tickets
    WHERE id = NEW.ticket_id;

    IF owner_id IS NULL
       OR auth.uid() IS NULL
       OR (
           auth.uid() <> owner_id
           AND NOT public.pg_ticket_admin()
       )
    THEN
        RAISE EXCEPTION
            'Not authorized for this ticket';
    END IF;

    IF NEW.author_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION
            'Author must match current user';
    END IF;

    IF NEW.internal
       AND NOT public.pg_ticket_admin()
    THEN
        RAISE EXCEPTION
            'Only administrators can create internal notes';
    END IF;

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS support_ticket_message_guard
ON public.support_ticket_messages;

CREATE TRIGGER support_ticket_message_guard
BEFORE INSERT
ON public.support_ticket_messages
FOR EACH ROW
EXECUTE FUNCTION public.pg_ticket_message_guard();


-- ============================================================================
-- 18. SUPPORT-TICKET AUDIT FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pg_ticket_event_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN

    IF TG_OP = 'INSERT' THEN

        INSERT INTO public.support_ticket_events (
            ticket_id,
            actor_id,
            action,
            changes
        )
        VALUES (
            NEW.id,
            auth.uid(),
            'created',
            jsonb_build_object(
                'severity', NEW.severity,
                'category', NEW.category
            )
        );

    ELSIF ROW(
        NEW.status,
        NEW.severity,
        NEW.assigned_to,
        NEW.resolution_notes
    ) IS DISTINCT FROM ROW(
        OLD.status,
        OLD.severity,
        OLD.assigned_to,
        OLD.resolution_notes
    ) THEN

        INSERT INTO public.support_ticket_events (
            ticket_id,
            actor_id,
            action,
            changes
        )
        VALUES (
            NEW.id,
            auth.uid(),
            'updated',
            jsonb_build_object(
                'old_status', OLD.status,
                'new_status', NEW.status,
                'old_severity', OLD.severity,
                'new_severity', NEW.severity,
                'old_assigned_to', OLD.assigned_to,
                'new_assigned_to', NEW.assigned_to,
                'resolution_notes_changed',
                NEW.resolution_notes IS DISTINCT FROM OLD.resolution_notes
            )
        );

    END IF;

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS support_ticket_audit
ON public.support_tickets;

CREATE TRIGGER support_ticket_audit
AFTER INSERT OR UPDATE
ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.pg_ticket_event_audit();


-- ============================================================================
-- 19. ENABLE SUPPORT-TICKET ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE public.support_tickets
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.support_ticket_messages
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.support_ticket_events
ENABLE ROW LEVEL SECURITY;


-- ============================================================================
-- 20. SUPPORT-TICKET POLICIES
-- ============================================================================

DROP POLICY IF EXISTS ticket_read
ON public.support_tickets;

CREATE POLICY ticket_read
ON public.support_tickets
FOR SELECT
TO authenticated
USING (
    user_id = auth.uid()
    OR public.pg_ticket_admin()
);


DROP POLICY IF EXISTS ticket_insert
ON public.support_tickets;

CREATE POLICY ticket_insert
ON public.support_tickets
FOR INSERT
TO authenticated
WITH CHECK (
    user_id = auth.uid()
    OR public.pg_ticket_admin()
);


DROP POLICY IF EXISTS ticket_admin_update
ON public.support_tickets;

CREATE POLICY ticket_admin_update
ON public.support_tickets
FOR UPDATE
TO authenticated
USING (
    public.pg_ticket_admin()
)
WITH CHECK (
    public.pg_ticket_admin()
);


-- ============================================================================
-- 21. SUPPORT-TICKET MESSAGE POLICIES
-- ============================================================================

DROP POLICY IF EXISTS ticket_message_read
ON public.support_ticket_messages;

CREATE POLICY ticket_message_read
ON public.support_ticket_messages
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.support_tickets t
        WHERE t.id = ticket_id
          AND (
              t.user_id = auth.uid()
              OR public.pg_ticket_admin()
          )
    )
    AND (
        NOT internal
        OR public.pg_ticket_admin()
    )
);


DROP POLICY IF EXISTS ticket_message_insert
ON public.support_ticket_messages;

CREATE POLICY ticket_message_insert
ON public.support_ticket_messages
FOR INSERT
TO authenticated
WITH CHECK (
    author_id = auth.uid()
    AND (
        NOT internal
        OR public.pg_ticket_admin()
    )
    AND EXISTS (
        SELECT 1
        FROM public.support_tickets t
        WHERE t.id = ticket_id
          AND (
              t.user_id = auth.uid()
              OR public.pg_ticket_admin()
          )
    )
);


-- ============================================================================
-- 22. SUPPORT-TICKET EVENT POLICIES
-- ============================================================================

DROP POLICY IF EXISTS ticket_events_read
ON public.support_ticket_events;

CREATE POLICY ticket_events_read
ON public.support_ticket_events
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.support_tickets t
        WHERE t.id = ticket_id
          AND (
              t.user_id = auth.uid()
              OR public.pg_ticket_admin()
          )
    )
);


-- ============================================================================
-- 23. SUPPORT-TICKET GRANTS
-- ============================================================================

REVOKE ALL
ON public.support_tickets,
   public.support_ticket_messages,
   public.support_ticket_events
FROM anon;

REVOKE INSERT, UPDATE, DELETE
ON public.support_ticket_events
FROM authenticated;

REVOKE UPDATE, DELETE
ON public.support_ticket_messages
FROM authenticated;

REVOKE DELETE
ON public.support_tickets
FROM authenticated;

GRANT SELECT, INSERT, UPDATE
ON public.support_tickets
TO authenticated;

GRANT SELECT, INSERT
ON public.support_ticket_messages
TO authenticated;

GRANT SELECT
ON public.support_ticket_events
TO authenticated;

GRANT ALL
ON public.support_tickets,
   public.support_ticket_messages,
   public.support_ticket_events
TO service_role;


-- ============================================================================
-- 24. REALTIME PUBLICATION
-- ============================================================================

DO $realtime$
DECLARE
    t TEXT;
BEGIN

    IF EXISTS (
        SELECT 1
        FROM pg_publication
        WHERE pubname = 'supabase_realtime'
    ) THEN

        FOREACH t IN ARRAY ARRAY[
            'device_current_state',
            'device_heartbeats',
            'pyroguard_camera_telemetry',
            'system_state',
            'device_commands',
            'ptz_state',
            'support_tickets',
            'support_ticket_messages'
        ]
        LOOP

            IF to_regclass(FORMAT('public.%I', t)) IS NOT NULL
               AND NOT EXISTS (
                   SELECT 1
                   FROM pg_publication_tables
                   WHERE pubname = 'supabase_realtime'
                     AND schemaname = 'public'
                     AND tablename = t
               )
            THEN

                EXECUTE FORMAT(
                    'ALTER PUBLICATION supabase_realtime ADD TABLE public.%I',
                    t
                );

            END IF;

        END LOOP;

    END IF;

END;
$realtime$;


-- ============================================================================
-- 25. SERVER ACCESS TO SUPPORT-TICKET SEQUENCES
-- ============================================================================

-- UUID-based support tables do not require application-owned
-- serial sequences.


-- ============================================================================
-- 26. REFRESH POSTGREST SCHEMA CACHE
-- ============================================================================

NOTIFY pgrst, 'reload schema';


-- ============================================================================
-- 27. COMMIT ADDITIVE CHANGES
-- ============================================================================

COMMIT;


-- ============================================================================
-- 28. VERIFY CORE AND SUPPORT-TICKET TABLES
-- ============================================================================

SELECT
    required.name AS table_name,
    CASE
        WHEN to_regclass(
            FORMAT('public.%I', required.name)
        ) IS NULL
        THEN 'MISSING'
        ELSE 'EXISTS'
    END AS status
FROM unnest(ARRAY[
    'admin_accounts',
    'profiles',
    'account_identities',
    'homes',
    'stakeholders',
    'emergency_contacts',
    'safety_setups',
    'user_preferences',
    'devices',
    'device_current_state',
    'device_heartbeats',
    'pyroguard_camera_telemetry',
    'system_state',
    'device_commands',
    'ptz_state',
    'ptz_commands',
    'sensor_history',
    'event_history',
    'camera_history',
    'camera_events',
    'audio_sessions',
    'mirror_records',
    'dual_record_ledger',
    'emergency_action_logs',
    'sensor_readings',
    'support_tickets',
    'support_ticket_messages',
    'support_ticket_events'
]) AS required(name)
ORDER BY required.name;


-- ============================================================================
-- 29. VERIFY ADMINISTRATORS
-- ============================================================================

SELECT
    a.admin_order,
    a.email,
    a.display_name,
    a.admin_role,
    a.user_id,
    a.active,

    p.account_role AS profile_role,
    p.account_status AS profile_status,

    ai.account_role AS identity_role,
    ai.account_status AS identity_status,
    ai.email_confirmed,
    ai.mysql_synced,

    CASE
        WHEN a.active = TRUE
         AND p.account_role = a.admin_role
         AND ai.account_role = a.admin_role
         AND p.account_status = 'active'
         AND ai.account_status = 'active'
         AND LOWER(a.email) = LOWER(p.email)
         AND LOWER(a.email) = LOWER(ai.email)
        THEN 'READY'
        ELSE 'CHECK REQUIRED'
    END AS verification_status

FROM public.admin_accounts a

LEFT JOIN public.profiles p
    ON p.user_id = a.user_id

LEFT JOIN public.account_identities ai
    ON ai.user_id = a.user_id

WHERE a.admin_order BETWEEN 1 AND 4

ORDER BY a.admin_order;


-- ============================================================================
-- 30. VERIFY AUTHENTICATION MATCHES
-- ============================================================================

WITH requested(email, expected_uid) AS (
    VALUES
    (
        'nowel@pyroguard.local',
        'b146fbd3-6ee6-44b5-aae9-f296005ca38b'::UUID
    ),
    (
        'danaya@pyroguard.local',
        'f1882d25-7567-4b81-8e37-202ec276c23b'::UUID
    ),
    (
        'sean@pyroguard.local',
        '6fd0f1ca-1bac-4814-b9f0-6eb8ba394acf'::UUID
    ),
    (
        'dave@pyroguard.local',
        'fa2cb844-9e43-4aa3-b3de-989fccb7c64d'::UUID
    )
)
SELECT
    r.email,
    r.expected_uid,

    u.id AS actual_auth_uid,
    u.email_confirmed_at IS NOT NULL AS email_confirmed,

    CASE
        WHEN u.id IS NULL
        THEN 'MISSING AUTH ACCOUNT'

        WHEN u.id IS DISTINCT FROM r.expected_uid
        THEN 'AUTH UUID MISMATCH'

        ELSE 'MATCHED'
    END AS verification_status

FROM requested r
LEFT JOIN auth.users u
    ON LOWER(u.email) = r.email
ORDER BY r.email;


-- ============================================================================
-- 31. VERIFY SUPPORT TICKETS
-- ============================================================================

SELECT
    'support_tickets' AS table_name,
    COUNT(*) AS total_records
FROM public.support_tickets

UNION ALL

SELECT
    'support_ticket_messages',
    COUNT(*)
FROM public.support_ticket_messages

UNION ALL

SELECT
    'support_ticket_events',
    COUNT(*)
FROM public.support_ticket_events;


-- ============================================================================
-- 32. VERIFY REALTIME
-- ============================================================================

SELECT
    t AS table_name,

    CASE
        WHEN EXISTS (
            SELECT 1
            FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND schemaname = 'public'
              AND tablename = t
        )
        THEN 'YES'
        ELSE 'NO'
    END AS realtime_enabled

FROM unnest(ARRAY[
    'device_current_state',
    'device_heartbeats',
    'pyroguard_camera_telemetry',
    'system_state',
    'device_commands',
    'ptz_state',
    'support_tickets',
    'support_ticket_messages'
]) AS t;


-- ============================================================================
-- 33. VERIFY LOCAL MYSQL WORKER STATUS
-- ============================================================================

SELECT
    worker_id,
    heartbeat_at,
    started_at,
    completed_at,
    mysql_connected,
    requested_at,
    acknowledged_at,
    report,

    CASE
        WHEN heartbeat_at > NOW() - INTERVAL '90 seconds'
         AND mysql_connected = TRUE
        THEN 'CONNECTED'
        ELSE 'NOT CONNECTED'
    END AS connection_status

FROM public.pyroguard_local_sync_status
WHERE worker_id = 'local-pc';


-- ============================================================================
-- 34. CHECK DUPLICATE DEVICE IDS
-- ============================================================================

SELECT
    device_id,
    COUNT(*) AS occurrences
FROM public.devices
GROUP BY device_id
HAVING COUNT(*) > 1;


-- ============================================================================
-- 35. CHECK ORPHAN DEVICE RECORDS
-- ============================================================================

SELECT
    'sensor_readings' AS table_name,
    COUNT(*) AS missing_devices
FROM public.sensor_readings s
WHERE NOT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.device_id = s.device_id
)

UNION ALL

SELECT
    'device_heartbeats',
    COUNT(*)
FROM public.device_heartbeats h
WHERE NOT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.device_id = h.device_id
)

UNION ALL

SELECT
    'device_current_state',
    COUNT(*)
FROM public.device_current_state s
WHERE NOT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.device_id = s.device_id
)

UNION ALL

SELECT
    'ptz_state',
    COUNT(*)
FROM public.ptz_state p
WHERE NOT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.device_id = p.device_id
)

UNION ALL

SELECT
    'pyroguard_camera_telemetry',
    COUNT(*)
FROM public.pyroguard_camera_telemetry c
WHERE NOT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.device_id = c.device_id
);


-- ============================================================================
-- 36. VERIFY FOREIGN KEYS
-- ============================================================================

SELECT
    tc.table_name AS source_table,
    kcu.column_name AS source_column,
    ccu.table_name AS referenced_table,
    ccu.column_name AS referenced_column

FROM information_schema.table_constraints tc

JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
   AND tc.constraint_schema = kcu.constraint_schema

JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name
   AND ccu.constraint_schema = tc.constraint_schema

WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'

ORDER BY tc.table_name;


-- ============================================================================
-- 37. VERIFY PRIMARY KEYS AND UNIQUE CONSTRAINTS
-- ============================================================================

SELECT
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type,

    STRING_AGG(
        kcu.column_name,
        ', '
        ORDER BY kcu.ordinal_position
    ) AS columns

FROM information_schema.table_constraints tc

JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
   AND tc.table_schema = kcu.table_schema
   AND tc.table_name = kcu.table_name

WHERE tc.table_schema = 'public'
  AND tc.constraint_type IN (
      'PRIMARY KEY',
      'UNIQUE'
  )

GROUP BY
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type

ORDER BY tc.table_name;


-- ============================================================================
-- 38. FINAL SCHEMA STATUS
-- ============================================================================

SELECT
    COUNT(*) AS existing_application_tables
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
  AND table_name IN (
      'admin_accounts',
      'profiles',
      'account_identities',
      'homes',
      'stakeholders',
      'emergency_contacts',
      'safety_setups',
      'user_preferences',
      'devices',
      'device_current_state',
      'device_heartbeats',
      'pyroguard_camera_telemetry',
      'system_state',
      'device_commands',
      'ptz_state',
      'ptz_commands',
      'sensor_history',
      'event_history',
      'camera_history',
      'camera_events',
      'audio_sessions',
      'mirror_records',
      'dual_record_ledger',
      'emergency_action_logs',
      'sensor_readings',
      'support_tickets',
      'support_ticket_messages',
      'support_ticket_events'
  );


-- ============================================================================
-- >>> 2026-11-04 HOME 1 SHARED ACCESS + HARDWARE SYNC
-- (same as migrations/20261104_home1_shared_access_supabase.sql)
-- ============================================================================

-- ============================================================================
-- PYROGUARD - HOME 1 SHARED ACCESS + HARDWARE SYNC (SUPABASE)
-- DATE: 2026-11-04
--
-- What this does (all additive, safe to run more than once):
--   1. Every existing VERIFIED (email-confirmed) account is enrolled into
--      Home 1 as an approved member. No approval step is needed.
--   2. Every future account is enrolled automatically the moment its email is
--      confirmed (trigger on auth.users).
--   3. Existing owner roles are never changed. Existing memberships are never
--      re-created: a REVOKED (or rejected/removed/suspended) membership stays
--      revoked. Only pending/requested/invited Home 1 rows become approved.
--   4. Administrator accounts and privileges are not touched (admins are not
--      enrolled and admin_accounts is not modified).
--   5. Home 1 members can READ all Home 1 hardware data (controllers, rooms,
--      heartbeats, cameras, PTZ, arm state, commands, sensor/event history)
--      and can SEND arm/disarm, buzzer and PTZ commands.
--   6. ESP32-002 (Batch 2: Kitchen & Bedroom) is registered under the Home 1
--      hardware owner if it is not registered yet, so its readings are stored
--      as soon as that controller transmits. Existing devices are unchanged.
--   7. No existing device, reading or history row is deleted.
--
-- Run in the Supabase SQL Editor (role postgres). Back up first.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. Preconditions
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('public.homes') IS NULL OR to_regclass('public.devices') IS NULL THEN
        RAISE EXCEPTION 'public.homes and public.devices must exist. Apply the core PyroGuard schema first.';
    END IF;
    IF to_regclass('auth.users') IS NULL THEN
        RAISE EXCEPTION 'auth.users not found. Run this in the Supabase SQL Editor.';
    END IF;
END;
$pre$;

-- Room sensor table (Batch 1 Entrance/Sala, Batch 2 Kitchen/Bedroom).
-- Same definition as 20261101_room_sensor_groups_supabase.sql; no-op if present.
CREATE TABLE IF NOT EXISTS public.pyroguard_room_sensor_readings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    controller_device_id text NOT NULL,
    room_key text NOT NULL CHECK (room_key IN ('entrance','sala','kitchen','bedroom')),
    temperature numeric,
    humidity numeric,
    smoke_raw numeric,
    smoke_status text,
    flame_detected boolean,
    buzzer_active boolean,
    sampled_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pg_room_controller_check CHECK (controller_device_id IN ('ESP32-001','ESP32-002'))
);
CREATE INDEX IF NOT EXISTS pg_room_sensor_latest_idx
    ON public.pyroguard_room_sensor_readings(controller_device_id, room_key, sampled_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_owner_idx
    ON public.pyroguard_room_sensor_readings(user_id, sampled_at DESC);
ALTER TABLE public.pyroguard_room_sensor_readings ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.pyroguard_room_sensor_readings TO service_role;

-- Room keys are the real area names: entrance + sala (ESP32-001),
-- kitchen + bedroom (ESP32-002). (An earlier version of this script renamed
-- 'entrance' rows to 'sala'; that step has been removed.)

-- ----------------------------------------------------------------------------
-- 1. Membership table (created only if this project does not have it yet)
-- ----------------------------------------------------------------------------
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
CREATE INDEX IF NOT EXISTS pyroguard_home_members_home_user_idx
    ON public.pyroguard_home_members(home_id, user_id);
CREATE INDEX IF NOT EXISTS pyroguard_home_members_user_idx
    ON public.pyroguard_home_members(user_id);
ALTER TABLE public.pyroguard_home_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pyroguard_home_members_read_own ON public.pyroguard_home_members;
CREATE POLICY pyroguard_home_members_read_own ON public.pyroguard_home_members
    FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));
GRANT SELECT ON public.pyroguard_home_members TO authenticated;
GRANT ALL ON public.pyroguard_home_members TO service_role;

-- ----------------------------------------------------------------------------
-- 2. Which home is "Home 1"
--    homes.id = 1 if it exists; otherwise the home of ESP32-001's owner.
--    Stored once; edit pyroguard_shared_home.home_id to point elsewhere.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pyroguard_shared_home (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    home_id bigint NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pyroguard_shared_home ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_shared_home FROM anon, authenticated;
GRANT ALL ON public.pyroguard_shared_home TO service_role;

DO $home$
DECLARE
    v_home bigint;
    v_has_home_col boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM public.pyroguard_shared_home) THEN
        SELECT home_id INTO v_home FROM public.pyroguard_shared_home;
        RAISE NOTICE 'Home 1 already configured: homes.id = %', v_home;
        RETURN;
    END IF;

    SELECT h.id INTO v_home FROM public.homes h WHERE h.id = 1;

    IF v_home IS NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'devices' AND column_name = 'home_id'
        ) INTO v_has_home_col;
        IF v_has_home_col THEN
            EXECUTE $q$SELECT home_id FROM public.devices WHERE device_id = 'ESP32-001'$q$ INTO v_home;
        END IF;
    END IF;

    IF v_home IS NULL THEN
        SELECT h.id INTO v_home
          FROM public.homes h
          JOIN public.devices d ON d.user_id = h.user_id
         WHERE d.device_id = 'ESP32-001'
         ORDER BY h.id
         LIMIT 1;
    END IF;

    IF v_home IS NULL THEN
        RAISE EXCEPTION 'Home 1 not found: no homes.id = 1 and no home for the owner of ESP32-001.';
    END IF;

    INSERT INTO public.pyroguard_shared_home(singleton, home_id) VALUES (true, v_home);
    RAISE NOTICE 'Home 1 = homes.id %', v_home;
END;
$home$;

-- ----------------------------------------------------------------------------
-- 3. Helper functions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pyroguard_shared_home_id()
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT home_id FROM public.pyroguard_shared_home LIMIT 1 $$;

-- Accounts that are administrators are never enrolled (privileges unchanged).
CREATE OR REPLACE FUNCTION public.pyroguard_is_admin_account(p_user uuid, p_email text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF lower(coalesce(p_email, '')) IN (
        'nowel@pyroguard.local', 'sean@pyroguard.local', 'danaya@pyroguard.local',
        'dave@pyroguard.local', 'benedict@pyroguard.local', 'christian@pyroguard.local',
        'danahia@pyroguard.local'
    ) THEN
        RETURN true;
    END IF;
    IF to_regclass('public.admin_accounts') IS NOT NULL THEN
        RETURN EXISTS (
            SELECT 1 FROM public.admin_accounts a
             WHERE a.user_id = p_user
                OR lower(a.email) = lower(coalesce(p_email, '#'))
        );
    END IF;
    RETURN false;
END;
$$;

-- Enrolls one account into Home 1. Returns what happened.
CREATE OR REPLACE FUNCTION public.pyroguard_enroll_shared_home_member(p_user uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_home bigint := public.pyroguard_shared_home_id();
    v_email text;
    v_confirmed timestamptz;
    v_row record;
    v_role text;
BEGIN
    IF v_home IS NULL THEN
        RETURN 'no_shared_home';
    END IF;

    SELECT u.email, u.email_confirmed_at INTO v_email, v_confirmed
      FROM auth.users u WHERE u.id = p_user;
    IF NOT FOUND THEN
        RETURN 'no_user';
    END IF;
    IF v_confirmed IS NULL THEN
        RETURN 'not_verified';
    END IF;
    IF public.pyroguard_is_admin_account(p_user, v_email) THEN
        RETURN 'admin_unchanged';
    END IF;

    SELECT m.member_role, m.membership_status INTO v_row
      FROM public.pyroguard_home_members m
     WHERE m.home_id = v_home AND m.user_id = p_user
     ORDER BY (m.membership_status = 'approved') DESC
     LIMIT 1;

    IF FOUND THEN
        -- Never restore revoked/rejected rows; never change any role.
        IF v_row.membership_status IS NULL
           OR lower(v_row.membership_status) IN ('pending', 'requested', 'invited') THEN
            UPDATE public.pyroguard_home_members
               SET membership_status = 'approved'
             WHERE home_id = v_home AND user_id = p_user
               AND (membership_status IS NULL
                    OR lower(membership_status) IN ('pending', 'requested', 'invited'));
            RETURN 'approved_existing';
        END IF;
        RETURN 'kept_' || coalesce(lower(v_row.membership_status), 'unknown');
    END IF;

    -- New member. 'member' is preferred; other role names are tried only if a
    -- CHECK constraint in this project does not allow 'member'.
    -- The Home 1 owner (homes.user_id) is enrolled as 'owner' if no row exists.
    FOREACH v_role IN ARRAY
        CASE WHEN EXISTS (SELECT 1 FROM public.homes h WHERE h.id = v_home AND h.user_id = p_user)
             THEN ARRAY['owner'] ELSE ARRAY['member', 'viewer', 'family', 'resident', 'guest'] END
    LOOP
        BEGIN
            INSERT INTO public.pyroguard_home_members(home_id, user_id, member_role, membership_status)
            VALUES (v_home, p_user, v_role, 'approved');
            RETURN 'enrolled_' || v_role;
        EXCEPTION WHEN check_violation THEN
            -- try the next role name
        END;
    END LOOP;
    RAISE EXCEPTION 'pyroguard_home_members rejected every member role name; check its CHECK constraint.';
END;
$$;

-- True when the signed-in account is an approved Home 1 member.
CREATE OR REPLACE FUNCTION public.pyroguard_has_shared_access()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.pyroguard_home_members m
         WHERE m.user_id = (SELECT auth.uid())
           AND m.home_id = public.pyroguard_shared_home_id()
           AND lower(coalesce(m.membership_status, '')) = 'approved'
    )
$$;

-- Hardware that belongs to the shared installation.
CREATE OR REPLACE FUNCTION public.pyroguard_is_shared_device(p_device text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT p_device IN ('ESP32-001', 'ESP32-002', 'pyroguard_camera_001',
                        'pyroguard_camera_002', 'pyroguard_audio_002')
        OR EXISTS (SELECT 1 FROM public.devices d WHERE d.device_id = p_device)
$$;

REVOKE ALL ON FUNCTION public.pyroguard_enroll_shared_home_member(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pyroguard_is_admin_account(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pyroguard_shared_home_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_has_shared_access() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_is_shared_device(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_is_admin_account(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pyroguard_enroll_shared_home_member(uuid) TO service_role;

-- ----------------------------------------------------------------------------
-- 4. Enroll every existing verified account now
-- ----------------------------------------------------------------------------
DO $backfill$
DECLARE
    r record;
    v_result text;
    v_counts jsonb := '{}'::jsonb;
BEGIN
    FOR r IN
        SELECT u.id FROM auth.users u
         WHERE u.email_confirmed_at IS NOT NULL
           AND u.deleted_at IS NULL
         ORDER BY u.created_at
    LOOP
        v_result := public.pyroguard_enroll_shared_home_member(r.id);
        v_counts := jsonb_set(v_counts, ARRAY[v_result],
                              to_jsonb(coalesce((v_counts ->> v_result)::int, 0) + 1));
    END LOOP;
    RAISE NOTICE 'Home 1 enrollment results: %', v_counts;
END;
$backfill$;

-- ----------------------------------------------------------------------------
-- 5. Enroll future accounts automatically when their email is confirmed
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pyroguard_auto_enroll_shared_home()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.email_confirmed_at IS NOT NULL
       AND (TG_OP = 'INSERT' OR OLD.email_confirmed_at IS NULL) THEN
        BEGIN
            PERFORM public.pyroguard_enroll_shared_home_member(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            -- Never block sign-up or email confirmation.
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

-- ----------------------------------------------------------------------------
-- 6. Register ESP32-002 (Batch 2) under the Home 1 hardware owner if missing
-- ----------------------------------------------------------------------------
DO $esp2$
DECLARE
    v_owner uuid;
    v_has_home_col boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM public.devices WHERE device_id = 'ESP32-002') THEN
        RAISE NOTICE 'ESP32-002 already registered (unchanged).';
        RETURN;
    END IF;
    SELECT user_id INTO v_owner FROM public.devices WHERE device_id = 'ESP32-001';
    IF v_owner IS NULL THEN
        SELECT user_id INTO v_owner FROM public.homes WHERE id = public.pyroguard_shared_home_id();
    END IF;
    IF v_owner IS NULL THEN
        RAISE NOTICE 'ESP32-002 not registered: Home 1 owner unknown.';
        RETURN;
    END IF;
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'devices' AND column_name = 'home_id'
    ) INTO v_has_home_col;
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

-- ----------------------------------------------------------------------------
-- 7. Home 1 members can READ all shared hardware data
--    (additive policies; existing owner/admin policies stay as they are)
-- ----------------------------------------------------------------------------
DO $read$
DECLARE
    t text;
    v_col text;
    v_rls boolean;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'devices', 'device_current_state', 'device_heartbeats', 'pyroguard_camera_telemetry',
        'system_state', 'device_commands', 'ptz_state', 'ptz_commands',
        'sensor_history', 'event_history', 'sensor_readings', 'pyroguard_room_sensor_readings',
        'camera_history', 'camera_events', 'audio_sessions',
        'pyroguard_camera_registry', 'pyroguard_camera_health', 'pyroguard_camera_audio_devices',
        'pyroguard_camera_commands', 'pyroguard_incidents'
    ] LOOP
        IF to_regclass(format('public.%I', t)) IS NULL THEN
            CONTINUE;
        END IF;

        SELECT c.column_name INTO v_col
          FROM information_schema.columns c
         WHERE c.table_schema = 'public' AND c.table_name = t
           AND c.column_name IN ('controller_device_id', 'target_device_id', 'device_id', 'camera_device_id')
         ORDER BY array_position(ARRAY['controller_device_id', 'target_device_id', 'device_id', 'camera_device_id'],
                                 c.column_name::text)
         LIMIT 1;
        IF v_col IS NULL THEN
            RAISE NOTICE 'Skipped %: no device column.', t;
            CONTINUE;
        END IF;

        SELECT relrowsecurity INTO v_rls FROM pg_class WHERE oid = format('public.%I', t)::regclass;
        IF NOT v_rls THEN
            RAISE NOTICE 'Skipped %: row level security is OFF (table already readable as configured).', t;
            CONTINUE;
        END IF;

        EXECUTE format('DROP POLICY IF EXISTS pyroguard_shared_home_read ON public.%I', t);
        EXECUTE format(
            'CREATE POLICY pyroguard_shared_home_read ON public.%I FOR SELECT TO authenticated '
            'USING (public.pyroguard_has_shared_access() AND public.pyroguard_is_shared_device(%I))',
            t, v_col);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END LOOP;
END;
$read$;

-- Home 1 itself (name, address, map pin)
DROP POLICY IF EXISTS pyroguard_shared_home_read ON public.homes;
CREATE POLICY pyroguard_shared_home_read ON public.homes
    FOR SELECT TO authenticated
    USING (id = public.pyroguard_shared_home_id() AND public.pyroguard_has_shared_access());
GRANT SELECT ON public.homes TO authenticated;

-- Members may read the owner's alarm timing used by the controller.
DO $safety$
BEGIN
    IF to_regclass('public.safety_setups') IS NOT NULL THEN
        DROP POLICY IF EXISTS pyroguard_shared_home_read ON public.safety_setups;
        CREATE POLICY pyroguard_shared_home_read ON public.safety_setups
            FOR SELECT TO authenticated
            USING (public.pyroguard_has_shared_access()
                   AND user_id IN (SELECT d.user_id FROM public.devices d WHERE d.device_id = 'ESP32-001'));
    END IF;
END;
$safety$;

-- ----------------------------------------------------------------------------
-- 8. Home 1 members can SEND commands (arm/disarm, buzzer, PTZ)
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS pyroguard_shared_home_command ON public.device_commands;
CREATE POLICY pyroguard_shared_home_command ON public.device_commands
    FOR INSERT TO authenticated
    WITH CHECK (
        user_id = (SELECT auth.uid())
        AND coalesce(requested_by, (SELECT auth.uid())) = (SELECT auth.uid())
        AND status = 'pending'
        AND public.pyroguard_has_shared_access()
        AND public.pyroguard_is_shared_device(target_device_id)
    );
GRANT SELECT, INSERT ON public.device_commands TO authenticated;

DROP POLICY IF EXISTS pyroguard_shared_home_command ON public.ptz_commands;
CREATE POLICY pyroguard_shared_home_command ON public.ptz_commands
    FOR INSERT TO authenticated
    WITH CHECK (
        user_id = (SELECT auth.uid())
        AND status = 'created'
        AND public.pyroguard_has_shared_access()
        AND public.pyroguard_is_shared_device(device_id)
    );
GRANT SELECT, INSERT ON public.ptz_commands TO authenticated;

-- Sequences used by the command tables (identity/serial columns).
DO $seq$
DECLARE s record;
BEGIN
    FOR s IN
        SELECT pg_get_serial_sequence(format('public.%I', t), 'id') AS seq
          FROM unnest(ARRAY['device_commands', 'ptz_commands']) t
    LOOP
        IF s.seq IS NOT NULL THEN
            EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO authenticated', s.seq);
        END IF;
    END LOOP;
END;
$seq$;

-- ----------------------------------------------------------------------------
-- 9. Realtime: live updates for every hardware table the app watches
-- ----------------------------------------------------------------------------
DO $realtime$
DECLARE t text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH t IN ARRAY ARRAY[
            'device_current_state', 'device_heartbeats', 'pyroguard_camera_telemetry',
            'system_state', 'device_commands', 'ptz_state', 'event_history',
            'pyroguard_room_sensor_readings'
        ] LOOP
            IF to_regclass(format('public.%I', t)) IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
            ) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
            END IF;
        END LOOP;
    END IF;
END;
$realtime$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================================
-- VERIFY (read-only)
-- ============================================================================

-- Home 1
SELECT s.home_id AS home_1_id, h.home_name, h.user_id AS home_owner
  FROM public.pyroguard_shared_home s
  LEFT JOIN public.homes h ON h.id = s.home_id;

-- Membership status of every verified account in Home 1
SELECT u.email,
       CASE WHEN public.pyroguard_is_admin_account(u.id, u.email) THEN 'administrator (unchanged)'
            ELSE coalesce(m.member_role || ' / ' || m.membership_status, 'NOT ENROLLED') END AS home_1_access
  FROM auth.users u
  LEFT JOIN public.pyroguard_home_members m
         ON m.user_id = u.id AND m.home_id = public.pyroguard_shared_home_id()
 WHERE u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL
 ORDER BY u.created_at;

-- Registered controllers
SELECT device_id, user_id, device_type, status FROM public.devices
 WHERE device_id IN ('ESP32-001', 'ESP32-002') ORDER BY device_id;

-- Latest reading per controller room (fresh = within 2 minutes)
SELECT DISTINCT ON (controller_device_id, room_key)
       controller_device_id,
       CASE controller_device_id || '/' || room_key
            WHEN 'ESP32-001/sala' THEN 'Entrance' WHEN 'ESP32-001/bedroom' THEN 'Sala'
            WHEN 'ESP32-002/sala' THEN 'Kitchen'  WHEN 'ESP32-002/bedroom' THEN 'Bedroom'
       END AS room,
       temperature, humidity, smoke_raw, smoke_status, flame_detected, buzzer_active, sampled_at,
       (now() - sampled_at) <= interval '2 minutes' AS fresh
  FROM public.pyroguard_room_sensor_readings
 ORDER BY controller_device_id, room_key, sampled_at DESC;

-- Shared-access policies now in place
SELECT tablename, policyname, cmd
  FROM pg_policies
 WHERE schemaname = 'public' AND policyname LIKE 'pyroguard_shared_home%'
 ORDER BY tablename, policyname;


-- ============================================================================
-- >>> 2026-11-04b FALSE-FIRE GUARD + FOUR ROOMS + DOOR/WINDOW
-- (same as migrations/20261104b_false_fire_and_rooms_supabase.sql)
-- ============================================================================

-- ============================================================================
-- PYROGUARD - FALSE-FIRE GUARD + FOUR ROOMS + DOOR/WINDOW (SUPABASE)
-- DATE: 2026-11-04 (b)            Run in Supabase SQL Editor. Back up first.
--
--  1. Room keys: entrance, sala (ESP32-001) and kitchen, bedroom (ESP32-002).
--     Old rows are kept as they are (NOT VALID check).
--  2. New safety columns on pyroguard_room_sensor_readings:
--       fire_confirmed  firmware confirmed smoke AND flame in that room
--       flame_fault     flame input stuck/chattering (ignored as fire)
--       smoke_fault     smoke input stuck (ignored as fire)
--  3. The CRITICAL_FIRE incident trigger now needs fire_confirmed = true in two
--     consecutive readings of the same room. Old-firmware readings, flame + high
--     temperature or smoke + high temperature never create a "fire" record.
--  4. Door/window current state table (if missing) + live updates.
-- Safe to run more than once. No rows are deleted.
-- ============================================================================

BEGIN;

-- 1. Room keys ---------------------------------------------------------------
DO $rk$
DECLARE c record;
BEGIN
    FOR c IN
        SELECT con.conname
          FROM pg_constraint con
          JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
         WHERE con.conrelid = 'public.pyroguard_room_sensor_readings'::regclass
           AND con.contype = 'c' AND att.attname = 'room_key'
    LOOP
        EXECUTE format('ALTER TABLE public.pyroguard_room_sensor_readings DROP CONSTRAINT %I', c.conname);
    END LOOP;
END;
$rk$;
ALTER TABLE public.pyroguard_room_sensor_readings
    ADD CONSTRAINT pyroguard_room_sensor_readings_room_key_check
    CHECK (room_key IN ('entrance', 'sala', 'kitchen', 'bedroom')) NOT VALID;

-- 2. Safety columns ----------------------------------------------------------
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS fire_confirmed boolean;
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS flame_fault boolean;
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS smoke_fault boolean;
CREATE INDEX IF NOT EXISTS pg_room_sensor_received_idx
    ON public.pyroguard_room_sensor_readings(controller_device_id, room_key, received_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_received_all_idx
    ON public.pyroguard_room_sensor_readings(received_at);

-- 3. CRITICAL_FIRE incidents only from confirmed fire ------------------------
CREATE OR REPLACE FUNCTION public.pyroguard_record_multisensor_room_alert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    previous public.pyroguard_room_sensor_readings%ROWTYPE;
    event_key text;
    label text;
BEGIN
    IF NEW.controller_device_id NOT IN ('ESP32-001', 'ESP32-002')
       OR NEW.received_at IS NULL
       OR NEW.received_at < now() - interval '30 seconds'
       OR NEW.received_at > now() + interval '10 seconds' THEN
        RETURN NEW;
    END IF;

    -- Confirmed fire in THIS sample: only the guarded firmware's fire_confirmed
    -- counts (never a faulty sensor, never temperature-only, never old firmware).
    IF NOT (coalesce(NEW.flame_fault, false) = false AND coalesce(NEW.smoke_fault, false) = false AND
            NEW.fire_confirmed IS TRUE) THEN
        RETURN NEW;
    END IF;

    SELECT * INTO previous
      FROM public.pyroguard_room_sensor_readings p
     WHERE p.controller_device_id = NEW.controller_device_id
       AND p.room_key = NEW.room_key
       AND p.id <> NEW.id
       AND p.received_at < NEW.received_at
       AND p.received_at >= NEW.received_at - interval '30 seconds'
     ORDER BY p.received_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;
    IF NOT (coalesce(previous.flame_fault, false) = false AND coalesce(previous.smoke_fault, false) = false AND
            previous.fire_confirmed IS TRUE) THEN
        RETURN NEW;
    END IF;

    label := CASE NEW.room_key WHEN 'entrance' THEN 'Entrance' WHEN 'sala' THEN 'Sala'
                               WHEN 'kitchen' THEN 'Kitchen' WHEN 'bedroom' THEN 'Bedroom'
                               ELSE NEW.room_key END;
    -- At most one record per room per five minutes.
    event_key := NEW.controller_device_id || ':FIRE:' || NEW.room_key || ':' ||
                 floor(extract(epoch FROM NEW.received_at) / 300)::bigint::text;
    INSERT INTO public.event_history
        (user_id, device_id, event_type, record_key, message, severity, payload_json, mysql_synced, created_at)
    VALUES
        (NEW.user_id, NEW.controller_device_id, 'CRITICAL_FIRE', event_key,
         'Fire confirmed by smoke + flame sensors in ' || label || ' (two consecutive readings). Verify and call BFP if needed.',
         2,
         jsonb_build_object('room_key', NEW.room_key, 'source', 'pyroguard_room_sensor_readings',
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

-- 4. Door / window current state ---------------------------------------------
CREATE TABLE IF NOT EXISTS public.pyroguard_contact_current_state (
    device_id text NOT NULL,
    room_key text NOT NULL,
    contact_type text NOT NULL CHECK (contact_type IN ('door', 'window')),
    is_open boolean NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, contact_type),
    CONSTRAINT contact_room_key_valid CHECK (room_key IN ('entrance', 'sala', 'kitchen', 'bedroom'))
);
ALTER TABLE public.pyroguard_contact_current_state ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pyroguard_contact_authenticated_read ON public.pyroguard_contact_current_state;
CREATE POLICY pyroguard_contact_authenticated_read ON public.pyroguard_contact_current_state
    FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.pyroguard_contact_current_state FROM anon;
GRANT SELECT ON public.pyroguard_contact_current_state TO authenticated;
GRANT ALL ON public.pyroguard_contact_current_state TO service_role;

-- Live updates
DO $rt$
DECLARE t text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH t IN ARRAY ARRAY['pyroguard_room_sensor_readings', 'pyroguard_contact_current_state',
                                 'device_current_state', 'event_history'] LOOP
            IF to_regclass(format('public.%I', t)) IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
            END IF;
        END LOOP;
    END IF;
END;
$rt$;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ============================================================================
-- VERIFY
-- ============================================================================
-- Newest reading per room (fresh = last 2 minutes)
SELECT DISTINCT ON (controller_device_id, room_key)
       controller_device_id, room_key, temperature, humidity, smoke_status, flame_detected,
       fire_confirmed, flame_fault, smoke_fault, received_at,
       now() - received_at <= interval '2 minutes' AS fresh
  FROM public.pyroguard_room_sensor_readings
 WHERE room_key IN ('entrance', 'sala', 'kitchen', 'bedroom')
 ORDER BY controller_device_id, room_key, received_at DESC;

-- Door / window
SELECT device_id, contact_type, room_key, is_open, received_at,
       now() - received_at <= interval '2 minutes' AS fresh
  FROM public.pyroguard_contact_current_state ORDER BY device_id, contact_type;
