-- ============================================================================
-- PYROGUARD - CONNECT THE HARDWARE TO THE NEW SUPABASE PROJECT      2026-11-19
-- Run in the SUPABASE SQL Editor (NOT MySQL Workbench), AFTER
-- 00_SUPABASE_BASE_SCHEMA_NEW_PROJECT.sql and 01_SUPABASE_FINAL_SYNC_FIX.sql,
-- and after at least ONE homeowner has signed up and confirmed their email.
--
-- No editing needed. Safe to run more than once. It:
--   1. picks the Home 1 owner (existing Home 1 -> first homeowner with a home
--      -> first confirmed non-admin account) and creates their home if missing
--   2. registers ESP32-001 and ESP32-002 under that owner
--   3. sets Home 1 (pyroguard_shared_home) so every member sees the hardware
--   4. registers Camera 1 (pyroguard_camera_001)
-- ============================================================================

DO $hw$
DECLARE
    v_owner uuid;
    v_email text;
    v_home  bigint;
    v_has_home_col boolean;
BEGIN
    -- 1a. Existing Home 1?
    SELECT h.user_id, h.id INTO v_owner, v_home
      FROM public.pyroguard_shared_home s JOIN public.homes h ON h.id = s.home_id
     LIMIT 1;

    -- 1b. First homeowner who already has a home
    IF v_owner IS NULL THEN
        SELECT h.user_id, h.id INTO v_owner, v_home
          FROM public.homes h
          JOIN public.profiles p ON p.user_id = h.user_id
         WHERE p.account_role = 'homeowner' AND p.account_status = 'active'
         ORDER BY h.id LIMIT 1;
    END IF;

    -- 1c. First confirmed non-admin account (homeowner without a home row yet)
    IF v_owner IS NULL THEN
        SELECT u.id INTO v_owner
          FROM auth.users u
         WHERE u.email_confirmed_at IS NOT NULL
           AND lower(u.email) NOT LIKE '%@pyroguard.local'
           AND NOT EXISTS (SELECT 1 FROM public.admin_accounts a WHERE a.user_id = u.id)
         ORDER BY u.created_at LIMIT 1;
    END IF;

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'No homeowner yet. Sign up ONE homeowner in the app, confirm the email code, log in once, then run this again.';
    END IF;

    SELECT email INTO v_email FROM auth.users WHERE id = v_owner;

    -- 1d. Create the owner's home if it does not exist
    IF v_home IS NULL THEN
        SELECT id INTO v_home FROM public.homes WHERE user_id = v_owner;
    END IF;
    IF v_home IS NULL THEN
        INSERT INTO public.homes (user_id, home_name) VALUES (v_owner, 'Home 1')
        RETURNING id INTO v_home;
        RAISE NOTICE 'Created Home 1 (homes.id %) for %', v_home, v_email;
    END IF;

    -- 2. Register both sensor controllers
    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'devices' AND column_name = 'home_id')
      INTO v_has_home_col;

    IF v_has_home_col THEN
        EXECUTE $q$
            INSERT INTO public.devices (user_id, device_id, device_name, device_type, status, home_id) VALUES
              ($1, 'ESP32-001', 'Batch 1 Controller (Entrance & Sala)',  'ESP32_MAIN', 'registered', $2),
              ($1, 'ESP32-002', 'Batch 2 Controller (Kitchen & Bedroom)', 'ESP32_MAIN', 'registered', $2)
            ON CONFLICT (device_id) DO UPDATE SET user_id = EXCLUDED.user_id, home_id = EXCLUDED.home_id, updated_at = now()
        $q$ USING v_owner, v_home;
    ELSE
        INSERT INTO public.devices (user_id, device_id, device_name, device_type, status) VALUES
          (v_owner, 'ESP32-001', 'Batch 1 Controller (Entrance & Sala)',  'ESP32_MAIN', 'registered'),
          (v_owner, 'ESP32-002', 'Batch 2 Controller (Kitchen & Bedroom)', 'ESP32_MAIN', 'registered')
        ON CONFLICT (device_id) DO UPDATE SET user_id = EXCLUDED.user_id, updated_at = now();
    END IF;

    -- 3. Home 1 shared by all members
    INSERT INTO public.pyroguard_shared_home (singleton, home_id) VALUES (true, v_home)
    ON CONFLICT (singleton) DO NOTHING;

    -- 4. Camera 1
    INSERT INTO public.pyroguard_camera_registry
        (device_id, display_name, model, ip_address, controller_device_id, enabled, ptz_enabled, audio_enabled)
    VALUES ('pyroguard_camera_001', 'Camera 1 - Entrance & Sala (two-way audio)', 'DFRobot DFR1154',
            '192.168.8.99', 'ESP32-001', true, true, true)
    ON CONFLICT (device_id) DO UPDATE SET enabled = true, ptz_enabled = true, audio_enabled = true,
                                          controller_device_id = 'ESP32-001';

    RAISE NOTICE 'Hardware connected: owner %, Home 1 = homes.id %', v_email, v_home;
END
$hw$;

-- Result: expect ESP32-001, ESP32-002 and pyroguard_camera_001, all with an owner.
SELECT d.device_id, u.email AS owner, d.status, (SELECT home_id FROM public.pyroguard_shared_home) AS home_1
  FROM public.devices d LEFT JOIN auth.users u ON u.id = d.user_id
UNION ALL
SELECT c.device_id, 'camera on ' || c.controller_device_id, CASE WHEN c.enabled THEN 'enabled' ELSE 'disabled' END, NULL
  FROM public.pyroguard_camera_registry c
ORDER BY 1;
