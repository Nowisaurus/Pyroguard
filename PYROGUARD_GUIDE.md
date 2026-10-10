IMPORTANT: There is ONE compiled SQL file: database/PYROGUARD_ALL_QUERIES.sql. Execute only SECTION 1 in Supabase and only SECTION 2 in MySQL Workbench. Never execute both sections in either editor.

# PyroGuard capstone guide

Updated 10 October 2026. This is the single current Markdown guide. PYROGUARD_REFERENCE.txt contains the same instructions for Notepad. Earlier version-specific guides and reset scripts are excluded from this ZIP.

## Files to use

| File | Purpose | Where it runs |
| --- | --- | --- |
| PYROGUARD_GUIDE.md | Setup, operation, laptop transfer and verification | Read this first |
| PYROGUARD_REFERENCE.txt | Plain-text copy of this guide | Notepad |
| database/PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) | Current additive source schemas, permissions, capture and PC status | Supabase SQL Editor |
| database/PYROGUARD_ALL_QUERIES.sql (SECTION 2: MySQL) | Current additive mirror schemas and diagnostic queries | MySQL Workbench |
| deployment/local-mysql-sync/.env.example | Private worker configuration template | Copy to .env on the MySQL laptop |
| deployment/local-mysql-sync/worker.mjs | Actual Supabase-to-local-MySQL worker | Node.js on the MySQL laptop |

There is one compiled SQL file with two marked sections because Supabase uses PostgreSQL and MySQL uses different syntax. Run only the Supabase section in Supabase and only the MySQL section in Workbench. CMakeLists.txt files in platform folders are Flutter build files, not extra instruction documents; they are retained.

## Your current setup

You repaired missing Supabase tables and progressed from 7/25 to 23/25. The last missing tables were system_state and device_commands. Their definitions and capture triggers are now included in PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) with the other 23 application tables. A successful 25/25 run verifies the inspected records, including empty tables; test real account/settings/device rows too.

MySQL remains installed on your laptop. Supabase stays online in the same project. The PC worker connects locally to MySQL at 127.0.0.1:3306 and makes outbound HTTPS requests to Supabase. No public MySQL hostname or router port forwarding is required. A mobile APK or web app uses Supabase, and the PC worker mirrors its records into MySQL.

Supabase is the source of application data. This is not two-way replication: manual edits made only in MySQL are not imported into Supabase and source-owned rows can be overwritten on the next copy. Writes are not atomic across the two engines. The laptop must be awake, MySQL running, internet working and the worker active. Otherwise, Supabase continues receiving data and MySQL catches up later.

## Current application behavior

- Administrators and homeowners share the login screen, navigation styling and orange/red/maroon palette. Admin routes remain separate; admins do not enter homeowner screens or tutorials and homeowners cannot open the admin console.
- The admin header uses the authenticated registry name. The Users tab reads real Auth registrations newest first, including unconfirmed registrations and missing-profile cases. Its display is limited to the latest 100 non-fixed-admin registrations from an Auth scan capped at 5,000; truncation is shown. This display limit does not limit the PC worker's 25-table scans.
- Admin Database sync shows the PC worker's freshness, last cycle and per-table result. Retry sync requests the next PC cycle; it cannot start or wake a laptop remotely. User rows are compared against content hashes from verified MySQL read-backs, rather than trusting mysql_synced alone.
- Homeowner registration saves a pending Supabase Auth signup; application records are finalized after email confirmation. In local-PC mode the MySQL result remains pending until the worker commits it. Existing roles/status are preserved. Missing application profile/identity rows can be recovered from actual confirmed Auth accounts, and email confirmation is refreshed from Auth. Unconfirmed signups are not bootstrapped into completed application profiles.
- The tutorial has four swipeable pages, transparent drawing frames, original narration and synchronized fade/scale/slide cards. Skip/Get started is available on the fourth page. Play/pause, seeking and mute control the narration/frame clock. Browser audio playback may require tapping Play. A faint edge can remain from background extraction.
- Light/dark themes and responsive desktop/mobile layouts remain. Hardware connection/heartbeat is separate from cloud connectivity. An online database or worker is not proof that ESP32 sensors are connected.
- Manual emergency/BFP actions and incident/media/session audit records remain in the application. Binary media remains in Supabase Storage; stored URLs and metadata are mirrored. Test actual sensor/alert and emergency flows before the capstone demonstration.

The source currently recognizes nowel@pyroguard.local, benedict@pyroguard.local, danahia@pyroguard.local and christian@pyroguard.local as fixed admin emails. The actual active registry, matching authenticated identity and authorized role are still required. This package does not create administrators, assign passwords or replace working registry entries. If an actual admin email differs from the code allowlist, reconcile the app/server allowlist and real registry deliberately; do not seed a replacement account using an old SQL sample.

Client login lockout is per account/device: three failures cause a 60-second lock, cumulative failure 10 causes a 15-minute lock, and successful login clears the count. Client storage can be cleared, so this is not server-wide rate limiting. MFA/provider login requires the project's corresponding real authentication configuration.

## Database queries: what changed and when to run them

PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) contains all 25 source-table definitions, the exact operational capture logic used in your repairs, both final missing tables, protected worker status, role RPCs and read-only diagnostics. New tables receive owner/admin-read policies and service-role grants. Existing tables, their records and their policies are preserved. It also adds nullable event/logged_in_at/logged_out_at columns used by the current identity client. No sample users, fixed UUIDs, passwords, device readings or admin registry seeds are inserted. There is no database reset or Auth account deletion.

Capture triggers are refreshed for the 23 operational source tables; the mirror and ledger tables are excluded from capture to prevent recursion. The script is transactional. Copy the entire SECTION 1 between the Supabase BEGIN/END markers, including BEGIN, COMMIT and its final diagnostic queries. Do not include SECTION 2. Clear selections in SQL Editor before Run: highlighted fragments may execute alone. A truncated dollar-quoted block is not a complete SQL query.

PYROGUARD_ALL_QUERIES.sql (SECTION 2: MySQL) creates missing mirror/support tables with CREATE TABLE IF NOT EXISTS. It does not replace existing tables or insert demonstration accounts. Existing incompatible column definitions are not silently changed; the worker reports them. For a new main laptop, restore the actual training-laptop backup first to preserve its exact schema and records. The MySQL section is an additive reference/fallback, not a substitute for exporting real data.

The default MySQL schema name in the file is pyroguard_db. If yours differs, change the CREATE DATABASE and USE names before running it, and use the same real name in .env. MySQL DDL is not one rollback-safe transaction. Back up before applying schema changes. Table presence alone does not establish row equality.

For this updated package, you can apply PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) once to incorporate the consolidated additive changes. You do not need to rerun old migrations, reset Auth or recreate administrators. Moving MySQL to another laptop while keeping the same Supabase project does not itself require rerunning the Supabase schema.

Newly created tables do not grant anonymous firmware writes. Device producers must use an authorized backend or authenticated owner/device flow. If firmware reports a permission error, fix its authentication/ownership instead of treating zero rows as real telemetry or granting unrestricted public writes. Existing policies are preserved rather than silently reconfigured; review them before making a capstone deployment public.

## Deploy the current functions

From the Flutter project root, confirm the project reference is your actual project. You already logged in; repeat login only if necessary.

```powershell
npx.cmd --yes supabase@latest login
npx.cmd --yes supabase@latest secrets set PYROGUARD_MYSQL_MODE=local-pc --project-ref torzyarstitxsreoqcig
npx.cmd --yes supabase@latest functions deploy admin-console --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy register-account --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy mysql-history --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy sync-outbox --project-ref torzyarstitxsreoqcig --use-api
```

Local mode does not use Supabase MYSQL_HOST=127.0.0.1: that would point at the hosted function's environment. MySQL credentials belong only in the laptop worker's private .env. The cloud outbox worker reports local-PC mode; disable any previously configured hosted MySQL scheduler for this setup. The updated device-command function and existing fire-alert function require their actual device/notification configuration when used.

## Configure and run the PC worker

Install Node.js 22 or newer, MySQL Server and MySQL Workbench. The training machine's Node 24 meets this requirement. Workbench is a client; the MySQL Server service must also be running.

Open PowerShell at the Flutter project root:

```powershell
cd deployment\local-mysql-sync
Copy-Item .env.example .env
notepad .env
```

Copy the template only if .env does not already exist; do not overwrite working settings. Use the same Supabase URL as the app. Set SUPABASE_SERVER_KEY to your private server secret or legacy service_role key, never the anon/publishable key. A key pasted into chat was exposed: replace/revoke it through the appropriate Supabase key-management flow and use its replacement. For a legacy JWT credential, creating a new secret key alone does not revoke the old JWT; follow Supabase's legacy-key/JWT rotation instructions and update affected server configurations before disabling old credentials. Do not paste the replacement into chat or Flutter.

| Setting | What to enter |
| --- | --- |
| SUPABASE_URL | Same online project URL used by the application |
| SUPABASE_SERVER_KEY | Private server credential for that project |
| MYSQL_HOST | 127.0.0.1 when the worker and MySQL run on the same laptop |
| MYSQL_PORT | Actual local MySQL port, usually 3306 |
| MYSQL_USER | Actual local MySQL user |
| MYSQL_PASSWORD | That user's actual password on this laptop |
| MYSQL_DATABASE | Existing schema name, for example pyroguard_db |
| MYSQL_SSL | false for the current local non-TLS setup; configure true and MYSQL_CA_FILE if using verified TLS |
| SYNC_INTERVAL_SECONDS | 15; the next scan waits for the current scan to finish |

Save as .env, not .env.txt. Avoid spaces immediately after equals signs unless intentionally part of a quoted value. Keep the file private and outside backups/ZIPs distributed to others. MySQL database users/passwords are separate from Supabase credentials and PyroGuard admin logins. Prefer a dedicated local MySQL user with the needed schema/row privileges instead of a publicly exposed root account.

```powershell
npm.cmd ci
npm.cmd run once
```

The goal is VERIFIED: 25/25 tables; 0 errors. If a table is pending, inspect its named error. PGRST205 indicates a source table unavailable to the API; check the table-presence diagnostic in PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase). If the table exists, try NOTIFY pgrst, 'reload schema'; in Supabase SQL Editor. Missing tables require the actual schema definitions. MySQL missing-table/nullability/read-back errors require inspecting the installed mirror schema; do not skip that table to claim success.

Keep synchronization active:

```powershell
npm.cmd start
```

Leave the window open. Ctrl+C stops it; allow the process to exit. A heartbeat older than 90 seconds is treated as offline. With large histories a full cycle can take longer than 15 seconds, so SYNC_INTERVAL_SECONDS is not a guaranteed end-to-end latency.

To check configuration without displaying values:

```powershell
node --env-file=.env -e "for (const k of ['SUPABASE_URL','SUPABASE_SERVER_KEY','MYSQL_HOST','MYSQL_PASSWORD','MYSQL_DATABASE']) console.log(k + ': ' + (process.env[k]?.trim() ? 'SET' : 'MISSING'))"
```

An intentionally empty local MySQL password will show MISSING in this convenience check. Do not send .env contents or secrets when troubleshooting.

## Move MySQL from the training PC to the main capstone laptop

The simplest layout is MySQL Server and the worker together on the main laptop. The Flutter app may run there or on another phone/computer; it continues accessing the same online Supabase project. Your ESP32 does not connect directly to this local MySQL instance.

### A. Prepare the main laptop

1. Install MySQL Server/Workbench, Node.js 22+ and Flutter if you will build/run the app there. Prefer the same compatible MySQL major version as the training PC.
2. Extract this application ZIP on the main laptop. It deliberately excludes private .env, installed node_modules and any real database backups.
3. Confirm the MySQL Server Windows service is running. Create a local database login or use the main installation's existing local login. Its password may differ from the training PC's password.

### B. Finish and stop the training PC's worker

1. Wait for a completed VERIFIED cycle. Record the row counts/results and check your latest real account.
2. Press Ctrl+C and let the training worker exit. Disable its scheduled startup task, if configured.
3. Keep it stopped while exporting and after the move. The advisory lock blocks duplicates on one MySQL server, but does not stop two different laptops from writing the same shared local-pc status row.
4. Supabase may keep accepting new records during the move. They will be copied by the main laptop after restart; do not delete the source or old database to stop writes.

### C. Export the actual training database

1. In Workbench, connect to the training PC's real MySQL instance.
2. Open Server > Data Export.
3. Select the entire PyroGuard schema and all its tables, including local-source archive/tombstones and ledger/mirror records. Select Dump Structure and Data, not Structure Only.
4. Choose Export to Self-Contained File and save a private file such as PyroGuard_Training_Backup.sql. Include schema creation if appropriate for a new empty target. Use the export progress/log to confirm success.
5. Copy the backup securely to the main laptop. Keep the original intact until verification is complete. The source backup contains real personal/device data; do not upload it publicly or bundle it with the application ZIP.

Workbench export/import documentation: https://dev.mysql.com/doc/workbench/en/wb-admin-export-import-management.html

### D. Restore on the main laptop

1. Create a NEW Workbench connection to the main laptop's 127.0.0.1, actual port and local MySQL credentials. Test it.
2. Open Server > Data Import and choose Import from Self-Contained File, then select the actual backup.
3. Import into a NEW/EMPTY target PyroGuard schema. A dump can include table-replacement statements, so do not aim it at another populated database or the training source.
4. Check Import Progress for errors. Confirm all expected tables and actual records were restored, including pyroguard_local_source_records.
5. A normal application-schema export does not transfer MySQL server users/passwords. Configure the local login on the main laptop separately. Never copy the raw MySQL data folder between installations as a substitute for a proper export/restore.
6. Use database/PYROGUARD_ALL_QUERIES.sql (SECTION 2: MySQL) only if you need its additive table setup/reference. Do not replace the restored real data with old seeded/reset scripts.

### E. Configure the main worker and catch up

1. Create a new private .env on the main laptop from .env.example.
2. Keep SUPABASE_URL and the authorized server credential for the SAME Supabase project. Set MYSQL_HOST=127.0.0.1 because MySQL now runs on this main laptop.
3. Enter the main laptop's actual MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD and restored MYSQL_DATABASE. Do not blindly reuse the training MySQL password.
4. From deployment/local-mysql-sync on the main laptop, run npm.cmd ci, then npm.cmd run once. Wait for VERIFIED: 25/25 tables; 0 errors.
5. Confirm pending source records created during the move were copied. Then run npm.cmd start and keep it open.
6. Do not start the training worker again. Keep the old database as a backup until you have confirmed the main setup.

There is no need to change the app's Supabase URL, recreate Supabase accounts, redeploy functions merely because MySQL moved, or put the main laptop's IP into Supabase MYSQL_HOST. If the main laptop uses a different network, the boards' Wi-Fi configuration and local camera IPs may need updating; moving MySQL alone does not change the online Supabase project.

If the worker runs on the main laptop but MySQL stays on a different laptop, 127.0.0.1 is incorrect. That arrangement requires the MySQL laptop's reachable LAN address, appropriate bind/firewall settings, a restricted database user and secured connectivity. The recommended capstone layout avoids that extra network dependency by keeping MySQL and the worker on the same main laptop.

### F. Optional automatic startup

After a successful manual run, use Windows Task Scheduler on the MAIN laptop at user logon:

- Program: full node.exe path returned by where.exe node.
- Arguments: --env-file="FULL_WORKER_FOLDER\.env" "FULL_WORKER_FOLDER\worker.mjs"
- Start in: the full local-mysql-sync folder path.
- Configure restart on failure, prevent overlapping runs, and ensure the main laptop remains awake.

Keep credentials inside private .env, not task arguments. Automatic startup does not make synchronization work while the laptop is shut down or offline.

## Run, build and callback configuration

In another terminal at the Flutter project root:

```powershell
flutter pub get
flutter analyze
flutter run -d chrome
```

For an Android release after resolving analysis/build issues:

```powershell
flutter build apk --release
```

The APK still uses Supabase; MySQL copies arrive while the main-laptop worker runs. Never embed server/service-role/MySQL credentials in the APK or browser app. Match the actual Supabase URL and public client key to the project before building.

Set Supabase Authentication Site URL/allowed Redirect URLs and PYROGUARD_SITE_URL to the actual callback URL appropriate to your deployed app. A localhost email link is reachable only on the computer hosting that local site, not another phone/laptop. Moving MySQL does not fix email callbacks or deploy the Flutter web app. Configure OAuth providers and mobile deep links separately when using those flows.

## Prove synchronization with actual records

1. Sign in as administrator. Check the real registry name, navigation at 320/375/430 px and desktop width, both themes and homeowner/admin route separation.
2. Open Database sync. The MAIN worker must be online, the last cycle completed, and table results verified. A 25/25 result may include empty tables; do not call an empty history real sensor evidence.
3. In Users, verify the newest actual account and creation date. Create a real account using your own test email, check its UUID in Supabase Auth, and confirm the same UUID/email/name in MySQL profiles and identities. Confirm its real registration_snapshot and email-confirmation state after verification.
4. Change a real profile/home/preference value through the app, wait for a completed cycle, and compare the actual source and target rows. Inspect archive-only fields if the typed schema is older.
5. Generate an actual device reading, command/ack and event from your hardware. Compare device_id, timestamps and values in both databases. If the source table is empty or permissions fail, fix the producer rather than inserting demonstration readings.
6. Stop only the worker, make a test change in Supabase/app, restart it, and verify catch-up. Check that stopping the worker causes admin status to become offline after the freshness window.
7. On the main laptop, compare these same real account/device rows against your transfer backup and training records. Verify the old worker/task stays stopped.

Useful read-only MySQL queries, replacing only the email with your actual test email:

```sql
SELECT user_id,full_name,email,phone,account_role,account_status
FROM pyroguard_profiles WHERE email='YOUR_ACTUAL_TEST_EMAIL';

SELECT user_id,email,display_name,email_confirmed,account_role,account_status
FROM pyroguard_account_identities WHERE email='YOUR_ACTUAL_TEST_EMAIL';

SELECT user_id,payload FROM pyroguard_mirror_records
WHERE record_type='registration_snapshot'
  AND user_id=(SELECT user_id FROM pyroguard_account_identities
               WHERE email='YOUR_ACTUAL_TEST_EMAIL');
```

## Synchronization coverage and limits

The worker scans these 25 source tables without the admin display's 100-row cap:

| Supabase source | MySQL typed mirror |
| --- | --- |
| admin_accounts | pyroguard_admin_accounts |
| profiles | pyroguard_profiles |
| account_identities | pyroguard_account_identities |
| homes | pyroguard_homes |
| stakeholders | pyroguard_stakeholders |
| emergency_contacts | pyroguard_emergency_contacts |
| safety_setups | pyroguard_safety_setups |
| user_preferences | pyroguard_user_preferences |
| devices | pyroguard_devices |
| device_current_state | pyroguard_device_current_state |
| device_heartbeats | pyroguard_device_heartbeats |
| pyroguard_camera_telemetry | pyroguard_pyroguard_camera_telemetry |
| system_state | pyroguard_system_state |
| device_commands | pyroguard_device_commands |
| ptz_state | pyroguard_ptz_state |
| ptz_commands | pyroguard_ptz_commands |
| sensor_history | pyroguard_sensor_history |
| event_history | pyroguard_event_history |
| camera_history | pyroguard_camera_history |
| camera_events | pyroguard_camera_events |
| audio_sessions | pyroguard_audio_sessions |
| mirror_records | pyroguard_mirror_records |
| dual_record_ledger | pyroguard_dual_record_ledger |
| emergency_action_logs | pyroguard_emergency_action_logs |
| sensor_readings | pyroguard_sensor_readings |

Supporting worker-status tables, private Auth internals, binary media objects and arbitrary extra database tables are outside this 25-table application mirror. Safe identity/registration data is included; Auth passwords, hashes and access/refresh/session tokens are never copied.

Each row uses a MySQL transaction for matching typed columns plus the complete JSON archive in pyroguard_local_source_records. Both copies are read back. Extra source columns remain in the archive and are named in the table report. Target-only unknown nullable values become null; required unknown fields fail instead of inventing defaults. Source precision, length, invalid timestamps and concurrent changes can leave a table pending. Existing source defaults are copied as source data; the worker does not manufacture sensor readings.

Keyset scans use a high-water key and re-read rows to detect content changes while copying. Rows created after inspection are caught on later cycles. Verification is of the inspected version during that cycle, not one global atomic snapshot. mysql_synced is bookkeeping, not proof by itself. Outbox acknowledgments happen only after the required tables/deletions succeed, with version guards.

Captured deletes become archive tombstones. A typed row is deleted only if still absent in Supabase and previously copied by this worker; an old deletion does not delete a recreated source row. Local-only rows are not purged. Historical rows deleted before capture existed are not automatically removed. Copying the archive when moving laptops preserves the worker's ownership/deletion history.

## Validation status

The worker's isolated tests cover typed/JSON read-back, null/extra-field preservation, unknown-default handling, rollback, precision, bounded pagination, full 25-table cycles, partial-failure acknowledgment handling, deletion/recreation and status/hash agreement. Test fixtures do not touch production. npm.cmd test runs the included core tests locally.

This consolidation validates SQL/source syntax, table/file coverage and ZIP integrity. Flutter compilation, actual Windows task execution, MySQL export/restore and live hardware/database round trips are performed on your laptops, not in this editing environment. Your successful live worker output is stronger evidence than static syntax checks, but run the actual-record and transfer tests above before relying on the main laptop for the capstone.

## Current error repairs

The Supabase SQL adds the missing account identity `event`, `logged_in_at` and `logged_out_at` columns, and reloads the PostgREST schema cache. Run the complete Supabase section of `database/PYROGUARD_ALL_QUERIES.sql` in the Supabase SQL Editor; do not paste isolated fragments.

The shared glass panels and highlighted mobile navigation tiles now contain transparent Material layers so ListTile backgrounds and ink effects paint above the panel decoration. Rebuild the Flutter application to receive this UI fix.

“MySQL mirror pending” means Supabase saved the source data and the local worker has not acknowledged its MySQL copy yet. Run the worker on the active MySQL laptop and inspect its cycle result and database records. Pending is not proof of a successful MySQL write.

## Current admin management and automatic tutorial playback

Tutorial pages autoplay with no play, pause, volume or scrub controls. Next, previous, swipe, page indicators and final-page Skip remain. Audible autoplay is attempted; browsers that block it use muted playback so drawings and cards still animate automatically. Browser sound cannot be forced without a permitted user gesture.

The verified administrator can enable/disable homeowner sign-ins and rename registered devices. Fixed administrator accounts cannot be modified through homeowner management. Disabling blocks future sign-ins; an existing access token may remain valid until expiry. Auth and source-profile status updates are separate operations: an incomplete write is reported and must be retried, never presented as fully saved. Source changes are mirrored by the active local MySQL worker.

The device menu queues Arm Home, Arm Away or Disarm for the selected registered device. The administrator sees command ID, pending/applied/failed status and the actual device result. A queued command does not prove physical execution. The admin may manage configuration and inspect sensor telemetry; the application does not fabricate readings or calibrate a physical MQ-2 remotely.

Deploy the updated server functions from the application root:

```powershell
npx.cmd --yes supabase@latest functions deploy admin-console --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy device-command --project-ref torzyarstitxsreoqcig --use-api
```

The device-command function requires PYROGUARD_DEVICE_KEY as its private secret; the main board's HISTORY_DEVICE_KEY must match. Do not put the service-role key in firmware. Configure the gateway/function JWT setting for the actual firmware device-key request; test that invalid device keys are rejected before deployment. The function accepts only explicit applied/failed acknowledgements for a pending command belonging to that device. Local-PC acknowledgements stay MySQL-pending until the worker mirrors them.

The bundled main ESP32-S3 sketch now polls the device-command gateway every two seconds and reports supported/unsupported results. Install ArduinoJson 6.x, fill in actual Wi-Fi credentials, device ID and revocable device key, and enable only the wired modules. Arm Away gates the three-PIR motion action; Arm Home and Disarmed suppress PIR-triggered actions. Fire/smoke sensing remains active. Motion enable/disable is supported only when ENABLE_PIR is on. Door/window hardware handlers are not implemented in this sketch, so those commands return failed instead of pretending to switch a sensor. PTZ uses its separate ptz_commands/ptz_state transport; it requires ENABLE_PTZ, verified servo pins and working firmware polling. The separate camera/audio board requires its own correct configuration and network access.

Hardware acceptance test: queue one control for the actual registered device, inspect its device_commands status/result, observe the physical effect, then confirm the same record in MySQL after a successful worker cycle. Repeat for mode, motion, PTZ/home/preset/tracking, camera and audio. Turn the board off and verify commands remain pending; turn it on and check actual acknowledgements. Test door/window only with firmware handlers and real wiring. Never infer physical success from a toggle changing on screen or from a successful database write. This release has static code checks and isolated worker tests; it has not been compiled with the Arduino toolchain or exercised on physical boards.

## Repair the permission failures in the supplied Flutter log

Run the updated complete Supabase SECTION 1 from the compiled SQL file. It now includes pyroguard_save_session, a narrow authenticated RPC that derives the caller's identity from Supabase Auth and the existing admin registry. The browser never supplies its own role, account status, target user or email. Missing source profile/identity records are created from the real account; existing roles/status are preserved and mismatches/disabled accounts are rejected. No passwords, sample records or administrator seeds are introduced.

The same section adds named compatibility policies for owned profile, mirror and ledger records on existing tables, and required sequence grants. Existing unrelated policies are retained. Restrictive policies can still block writes and should be inspected if a 42501 remains. Do not disable RLS or grant browsers access to auth.users. This replaces the earlier missing-table-only policy approach for these specific logged failures.

Stop the old Flutter process and rebuild this updated application. The old client still performs direct identity upserts; the new client uses the session RPC. Copy only your private worker .env into the updated worker folder, keep it outside shared ZIPs, and run npm.cmd run once followed by npm.cmd start after successful verification. Pending MySQL messages continue until the worker commits the real source records. Local-mode history uses Supabase fallback, rather than trying to read a database on another PC from a cloud function.

## New account not visible or not copied

The registration function first creates a pending Auth signup. It returns awaiting_confirmation=true without creating completed application records for an unconfirmed email. Confirmed source writes are read back before reporting source_saved=true. A failed source write is now reported as an unverified application account, not mislabeled as only a pending MySQL copy. The compiled Supabase section grants the server and worker the required table/sequence privileges on existing tables too. It never grants public access to Auth users.

Redeploy register-account along with the admin-console and device-command updates:

```powershell
npx.cmd --yes supabase@latest functions deploy register-account --project-ref torzyarstitxsreoqcig --use-api
```

For an account already created, do not create another account. Check Supabase Authentication Users for the actual email, apply SECTION 1, then run the PC worker once. The worker repairs missing profile/identity/snapshot rows from the real confirmed Auth account and copies them to MySQL, only after email confirmation. In Supabase Table Editor inspect profiles.user_id and account_identities.user_id; in MySQL Workbench inspect pyroguard_profiles and pyroguard_account_identities by that same user_id or email. A 25/25 result with empty tables is not enough: confirm this actual account's ID/email in both engines and its current admin verification status. If it is absent from Auth too, signup never completed; inspect the registration response/function logs rather than inserting a fake account row.

## REQUIRED: Confirm Account before completed registration

In Supabase Dashboard → Authentication → Sign In / Providers → Email, enable Confirm email. Deploy the updated register-account function. Use a real reachable Site URL and allowed redirect URL (the deployed web app, for example your actual Vercel URL); a localhost URL is not reachable from another device.

Registration now has these stages:
1. Submit signup: Supabase Auth stores the pending identity needed to send verification. No completed application profile/identity/snapshot is created for the unconfirmed signup, and the worker skips it.
2. Click Confirm Account in the Supabase email: Auth verifies the email. Merely opening the app or a custom HTML button is not sufficient; the email template button must use Supabase's actual confirmation link.
3. The confirmed user's session RPC/first login and active worker recover the real application profile/identity and metadata. The MySQL copy completes only after the worker's verified cycle. The admin shows awaiting confirmation before that click, then the actual source/MySQL status afterward.

The server rejects immediate-session signups when Email confirmation is disabled rather than finalizing them as completed accounts. The session RPC also rejects unconfirmed homeowner identities. Existing records created by older versions are preserved; this update does not delete older unconfirmed source/MySQL rows. Inspect and resolve those separately if needed.

Test using a real new email: before confirmation, check Auth is pending and application profile/MySQL account rows do not exist. After clicking the genuine email button, verify email_confirmed_at is populated, run the worker, and inspect the same user ID/email in both databases. The pending Auth record must exist before verification so Supabase can send and validate the link; it is not yet a completed application account.

The protected active admin registry, matching Auth email and source roles are authoritative for administrator mirror access. Old missing app-metadata role labels do not force a valid registry administrator into a homeowner identity. Browser requests cannot create or edit admin registry rows through these repairs.

For email-provider accounts, completion also requires the actual Auth confirmation_sent_at field. This prevents the worker/session repair from finalizing newly auto-confirmed signups when Confirm email was disabled. Existing source rows are retained. Older auto-confirmed accounts without a sent-confirmation record may need an administrator-led recovery rather than being automatically bootstrapped. OAuth verified identities use their provider verification; this email-button gate applies to email/password signups.
