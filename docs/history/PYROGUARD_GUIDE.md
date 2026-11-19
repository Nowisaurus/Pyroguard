IMPORTANT: There is ONE compiled SQL file: database/PYROGUARD_ALL_QUERIES.sql. Execute only SECTION 1 in Supabase and only SECTION 2 in MySQL Workbench. Never execute both sections in either editor.

PyroGuard capstone guide
Documentation reviewed 22 October 2026 (original technical release notes dated 10–11 October 2026). This is the detailed Markdown guide. PYROGUARD_NOTES.txt contains the same instructions for Notepad. Earlier version-specific guides and reset scripts are excluded from this ZIP.
Files to use
File	Purpose	Where it runs
PYROGUARD_GUIDE.md	Setup, operation, laptop transfer and verification	Read this first
PYROGUARD_NOTES.txt	Plain-text copy of this guide	Notepad
database/PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase)	Current additive source schemas, permissions, capture and PC status	Supabase SQL Editor
database/PYROGUARD_ALL_QUERIES.sql (SECTION 2: MySQL)	Current additive mirror schemas and diagnostic queries	MySQL Workbench
deployment/local-mysql-sync/.env.example	Private worker configuration template	Copy to .env on the MySQL laptop
deployment/local-mysql-sync/worker.mjs	Actual Supabase-to-local-MySQL worker	Node.js on the MySQL laptop


There is one compiled SQL file with two marked sections because Supabase uses PostgreSQL and MySQL uses different syntax. Run only the Supabase section in Supabase and only the MySQL section in Workbench. CMakeLists.txt files in platform folders are Flutter build files, not extra instruction documents; they are retained.
Verification note (22 October 2026): The procedures below describe the 25-table mirror from the October 10 package. A later laptop log reported a 28/28 verification. Inspect the actual installed worker/schema before choosing a target count; do not change SQL or assume current production parity from these documents alone.

Your current setup
You repaired missing Supabase tables and progressed from 7/25 to 23/25. The last missing tables were system_state and device_commands. Their definitions and capture triggers are now included in PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) with the other 23 application tables. A successful 25/25 run verifies the inspected records, including empty tables; test real account/settings/device rows too.

MySQL remains installed on your laptop. Supabase stays online in the same project. The PC worker connects locally to MySQL at 127.0.0.1:3306 and makes outbound HTTPS requests to Supabase. No public MySQL hostname or router port forwarding is required. A mobile APK or web app uses Supabase, and the PC worker mirrors its records into MySQL.

Supabase is the source of application data. This is not two-way replication: manual edits made only in MySQL are not imported into Supabase and source-owned rows can be overwritten on the next copy. Writes are not atomic across the two engines. The laptop must be awake, MySQL running, internet working and the worker active. Otherwise, Supabase continues receiving data and MySQL catches up later.
Current application behavior
- Administrators and homeowners share the login screen, navigation styling and orange/red/maroon palette. Admin routes remain separate; admins do not enter homeowner screens or tutorials and homeowners cannot open the admin console.
- The admin header uses the authenticated registry name. The Users tab reads real Auth registrations newest first, including unconfirmed registrations and missing-profile cases. Its display is limited to the latest 100 non-fixed-admin registrations from an Auth scan capped at 5,000; truncation is shown. This display limit does not limit the PC worker's 25-table scans.
- Admin Database sync shows the PC worker's freshness, last cycle and per-table result. Retry sync requests the next PC cycle; it cannot start or wake a laptop remotely. User rows are compared against content hashes from verified MySQL read-backs, rather than trusting mysql_synced alone.
- Homeowner registration saves a pending Supabase Auth signup; application records are finalized after email confirmation. In local-PC mode the MySQL result remains pending until the worker commits it. Existing roles/status are preserved. Missing application profile/identity rows can be recovered from actual confirmed Auth accounts, and email confirmation is refreshed from Auth. Unconfirmed signups are not bootstrapped into completed application profiles.
- The tutorial has four swipeable pages, transparent drawing frames and synchronized rounded Material cards. Skip is available from the first drawing; Get started appears on the fourth page. Playback starts automatically without play, pause or volume controls. Browsers that block audible autoplay fall back to muted playback. Content centers on wide screens and stacks on phones. A faint edge can remain from background extraction.
- Light/dark themes and responsive desktop/mobile layouts remain. Hardware connection/heartbeat is separate from cloud connectivity. An online database or worker is not proof that ESP32 sensors are connected.
- Manual emergency/BFP actions and incident/media/session audit records remain in the application. Binary media remains in Supabase Storage; stored URLs and metadata are mirrored. Test actual sensor/alert and emergency flows before the capstone demonstration.
The source currently recognizes nowel@pyroguard.local, benedict@pyroguard.local, danahia@pyroguard.local and christian@pyroguard.local as fixed admin emails. The actual active registry, matching authenticated identity and authorized role are still required. This package does not create administrators, assign passwords or replace working registry entries. If an actual admin email differs from the code allowlist, reconcile the app/server allowlist and real registry deliberately; do not seed a replacement account using an old SQL sample.

Client login lockout is per account/device: three failures cause a 60-second lock, cumulative failure 10 causes a 15-minute lock, and successful login clears the count. Client storage can be cleared, so this is not server-wide rate limiting. MFA/provider login requires the project's corresponding real authentication configuration.
Database queries: what changed and when to run them
PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) contains all 25 source-table definitions, the exact operational capture logic used in your repairs, both final missing tables, protected worker status, role RPCs and read-only diagnostics. New tables receive owner/admin-read policies and service-role grants. Existing tables, their records and their policies are preserved. It also adds nullable event/logged_in_at/logged_out_at columns used by the current identity client. No sample users, fixed UUIDs, passwords, device readings or admin registry seeds are inserted. There is no database reset or Auth account deletion.

Capture triggers are refreshed for the 23 operational source tables; the mirror and ledger tables are excluded from capture to prevent recursion. The script is transactional. Copy the entire SECTION 1 between the Supabase BEGIN/END markers, including BEGIN, COMMIT and its final diagnostic queries. Do not include SECTION 2. Clear selections in SQL Editor before Run: highlighted fragments may execute alone. A truncated dollar-quoted block is not a complete SQL query.

PYROGUARD_ALL_QUERIES.sql (SECTION 2: MySQL) creates missing mirror/support tables with CREATE TABLE IF NOT EXISTS. It does not replace existing tables or insert demonstration accounts. Existing incompatible column definitions are not silently changed; the worker reports them. For a new main laptop, restore the actual training-laptop backup first to preserve its exact schema and records. The MySQL section is an additive reference/fallback, not a substitute for exporting real data.

The default MySQL schema name in the file is pyroguard_db. If yours differs, change the CREATE DATABASE and USE names before running it, and use the same real name in .env. MySQL DDL is not one rollback-safe transaction. Back up before applying schema changes. Table presence alone does not establish row equality.

For this updated package, you can apply PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase) once to incorporate the consolidated additive changes. You do not need to rerun old migrations, reset Auth or recreate administrators. Moving MySQL to another laptop while keeping the same Supabase project does not itself require rerunning the Supabase schema.

Newly created tables do not grant anonymous firmware writes. Device producers must use an authorized backend or authenticated owner/device flow. If firmware reports a permission error, fix its authentication/ownership instead of treating zero rows as real telemetry or granting unrestricted public writes. Existing policies are preserved rather than silently reconfigured; review them before making a capstone deployment public.
Deploy the current functions
From the Flutter project root, confirm the project reference is your actual project. You already logged in; repeat login only if necessary.
npx.cmd --yes supabase@latest login
npx.cmd --yes supabase@latest secrets set PYROGUARD_MYSQL_MODE=local-pc --project-ref torzyarstitxsreoqcig
npx.cmd --yes supabase@latest functions deploy admin-console --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy register-account --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy mysql-history --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy sync-outbox --project-ref torzyarstitxsreoqcig --use-api
Local mode does not use Supabase MYSQL_HOST=127.0.0.1: that would point at the hosted function's environment. MySQL credentials belong only in the laptop worker's private .env. The cloud outbox worker reports local-PC mode; disable any previously configured hosted MySQL scheduler for this setup. The updated device-command function and existing fire-alert function require their actual device/notification configuration when used.
Configure and run the PC worker
Install Node.js 22 or newer, MySQL Server and MySQL Workbench. The training machine's Node 24 meets this requirement. Workbench is a client; the MySQL Server service must also be running.

Open PowerShell at the Flutter project root:
cd deployment\local-mysql-sync
Copy-Item .env.example .env
notepad .env
Copy the template only if .env does not already exist; do not overwrite working settings. Use the same Supabase URL as the app. Set SUPABASE_SERVER_KEY to your private server secret or legacy service_role key, never the anon/publishable key. A key pasted into chat was exposed: replace/revoke it through the appropriate Supabase key-management flow and use its replacement. For a legacy JWT credential, creating a new secret key alone does not revoke the old JWT; follow Supabase's legacy-key/JWT rotation instructions and update affected server configurations before disabling old credentials. Do not paste the replacement into chat or Flutter.
Setting	What to enter
SUPABASE_URL	Same online project URL used by the application
SUPABASE_SERVER_KEY	Private server credential for that project
MYSQL_HOST	127.0.0.1 when the worker and MySQL run on the same laptop
MYSQL_PORT	Actual local MySQL port, usually 3306
MYSQL_USER	Actual local MySQL user
MYSQL_PASSWORD	That user's actual password on this laptop
MYSQL_DATABASE	Existing schema name, for example pyroguard_db
MYSQL_SSL	false for the current local non-TLS setup; configure true and MYSQL_CA_FILE if using verified TLS
SYNC_INTERVAL_SECONDS	15; the next scan waits for the current scan to finish


Save as .env, not .env.txt. Avoid spaces immediately after equals signs unless intentionally part of a quoted value. Keep the file private and outside backups/ZIPs distributed to others. MySQL database users/passwords are separate from Supabase credentials and PyroGuard admin logins. Prefer a dedicated local MySQL user with the needed schema/row privileges instead of a publicly exposed root account.
npm.cmd ci
npm.cmd run once
The goal is VERIFIED: 25/25 tables; 0 errors. If a table is pending, inspect its named error. PGRST205 indicates a source table unavailable to the API; check the table-presence diagnostic in PYROGUARD_ALL_QUERIES.sql (SECTION 1: Supabase). If the table exists, try NOTIFY pgrst, 'reload schema'; in Supabase SQL Editor. Missing tables require the actual schema definitions. MySQL missing-table/nullability/read-back errors require inspecting the installed mirror schema; do not skip that table to claim success.

Keep synchronization active:
npm.cmd start
Leave the window open. Ctrl+C stops it; allow the process to exit. A heartbeat older than 90 seconds is treated as offline. With large histories a full cycle can take longer than 15 seconds, so SYNC_INTERVAL_SECONDS is not a guaranteed end-to-end latency.

To check configuration without displaying values:
node --env-file=.env -e "for (const k of ['SUPABASE_URL','SUPABASE_SERVER_KEY','MYSQL_HOST','MYSQL_PASSWORD','MYSQL_DATABASE']) console.log(k + ': ' + (process.env[k]?.trim() ? 'SET' : 'MISSING'))"
An intentionally empty local MySQL password will show MISSING in this convenience check. Do not send .env contents or secrets when troubleshooting.
Move MySQL from the training PC to the main capstone laptop
The simplest layout is MySQL Server and the worker together on the main laptop. The Flutter app may run there or on another phone/computer; it continues accessing the same online Supabase project. Your ESP32 does not connect directly to this local MySQL instance.
A. Prepare the main laptop
1. Install MySQL Server/Workbench, Node.js 22+ and Flutter if you will build/run the app there. Prefer the same compatible MySQL major version as the training PC.
2. Extract this application ZIP on the main laptop. It deliberately excludes private .env, installed node_modules and any real database backups.
3. Confirm the MySQL Server Windows service is running. Create a local database login or use the main installation's existing local login. Its password may differ from the training PC's password.
B. Finish and stop the training PC's worker
1. Wait for a completed VERIFIED cycle. Record the row counts/results and check your latest real account.
2. Press Ctrl+C and let the training worker exit. Disable its scheduled startup task, if configured.
3. Keep it stopped while exporting and after the move. The advisory lock blocks duplicates on one MySQL server, but does not stop two different laptops from writing the same shared local-pc status row.
4. Supabase may keep accepting new records during the move. They will be copied by the main laptop after restart; do not delete the source or old database to stop writes.
C. Export the actual training database
1. In Workbench, connect to the training PC's real MySQL instance.
2. Open Server > Data Export.
3. Select the entire PyroGuard schema and all its tables, including local-source archive/tombstones and ledger/mirror records. Select Dump Structure and Data, not Structure Only.
4. Choose Export to Self-Contained File and save a private file such as PyroGuard_Training_Backup.sql. Include schema creation if appropriate for a new empty target. Use the export progress/log to confirm success.
5. Copy the backup securely to the main laptop. Keep the original intact until verification is complete. The source backup contains real personal/device data; do not upload it publicly or bundle it with the application ZIP.
Workbench export/import documentation: https://dev.mysql.com/doc/workbench/en/wb-admin-export-import-management.html
D. Restore on the main laptop
1. Create a NEW Workbench connection to the main laptop's 127.0.0.1, actual port and local MySQL credentials. Test it.
2. Open Server > Data Import and choose Import from Self-Contained File, then select the actual backup.
3. Import into a NEW/EMPTY target PyroGuard schema. A dump can include table-replacement statements, so do not aim it at another populated database or the training source.
4. Check Import Progress for errors. Confirm all expected tables and actual records were restored, including pyroguard_local_source_records.
5. A normal application-schema export does not transfer MySQL server users/passwords. Configure the local login on the main laptop separately. Never copy the raw MySQL data folder between installations as a substitute for a proper export/restore.
6. Use database/PYROGUARD_ALL_QUERIES.sql (SECTION 2: MySQL) only if you need its additive table setup/reference. Do not replace the restored real data with old seeded/reset scripts.
E. Configure the main worker and catch up
1. Create a new private .env on the main laptop from .env.example.
2. Keep SUPABASE_URL and the authorized server credential for the SAME Supabase project. Set MYSQL_HOST=127.0.0.1 because MySQL now runs on this main laptop.
3. Enter the main laptop's actual MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD and restored MYSQL_DATABASE. Do not blindly reuse the training MySQL password.
4. From deployment/local-mysql-sync on the main laptop, run npm.cmd ci, then npm.cmd run once. Wait for VERIFIED: 25/25 tables; 0 errors.
5. Confirm pending source records created during the move were copied. Then run npm.cmd start and keep it open.
6. Do not start the training worker again. Keep the old database as a backup until you have confirmed the main setup.
There is no need to change the app's Supabase URL, recreate Supabase accounts, redeploy functions merely because MySQL moved, or put the main laptop's IP into Supabase MYSQL_HOST. If the main laptop uses a different network, the boards' Wi-Fi configuration and local camera IPs may need updating; moving MySQL alone does not change the online Supabase project.

If the worker runs on the main laptop but MySQL stays on a different laptop, 127.0.0.1 is incorrect. That arrangement requires the MySQL laptop's reachable LAN address, appropriate bind/firewall settings, a restricted database user and secured connectivity. The recommended capstone layout avoids that extra network dependency by keeping MySQL and the worker on the same main laptop.
F. Optional automatic startup
After a successful manual run, use Windows Task Scheduler on the MAIN laptop at user logon:
- Program: full node.exe path returned by where.exe node.
- Arguments: --env-file="FULL_WORKER_FOLDER.env" "FULL_WORKER_FOLDER\worker.mjs"
- Start in: the full local-mysql-sync folder path.
- Configure restart on failure, prevent overlapping runs, and ensure the main laptop remains awake.
Keep credentials inside private .env, not task arguments. Automatic startup does not make synchronization work while the laptop is shut down or offline.
Run, build and callback configuration
In another terminal at the Flutter project root:
flutter pub get
flutter analyze
flutter run -d chrome
For an Android release after resolving analysis/build issues:
flutter build apk --release
The APK still uses Supabase; MySQL copies arrive while the main-laptop worker runs. Never embed server/service-role/MySQL credentials in the APK or browser app. Match the actual Supabase URL and public client key to the project before building.

Set Supabase Authentication Site URL and allowed Redirect URLs to https://pyroguard-web-blue.vercel.app/. The updated registration function uses this production confirmation redirect. A localhost email link is reachable only on the computer hosting that local site, not another phone/laptop. Moving MySQL does not fix email callbacks or deploy the Flutter web app. Configure OAuth providers and mobile deep links separately when using those flows.
Prove synchronization with actual records
1. Sign in as administrator. Check the real registry name, navigation at 320/375/430 px and desktop width, both themes and homeowner/admin route separation.
2. Open Database sync. The MAIN worker must be online, the last cycle completed, and table results verified. A 25/25 result may include empty tables; do not call an empty history real sensor evidence.
3. In Users, verify the newest actual account and creation date. Create a real account using your own test email, check its UUID in Supabase Auth, and confirm the same UUID/email/name in MySQL profiles and identities. Confirm its real registration_snapshot and email-confirmation state after verification.
4. Change a real profile/home/preference value through the app, wait for a completed cycle, and compare the actual source and target rows. Inspect archive-only fields if the typed schema is older.
5. Generate an actual device reading, command/ack and event from your hardware. Compare device_id, timestamps and values in both databases. If the source table is empty or permissions fail, fix the producer rather than inserting demonstration readings.
6. Stop only the worker, make a test change in Supabase/app, restart it, and verify catch-up. Check that stopping the worker causes admin status to become offline after the freshness window.
7. On the main laptop, compare these same real account/device rows against your transfer backup and training records. Verify the old worker/task stays stopped.
Useful read-only MySQL queries, replacing only the email with your actual test email:
SELECT user_id,full_name,email,phone,account_role,account_status
FROM pyroguard_profiles WHERE email='YOUR_ACTUAL_TEST_EMAIL';

SELECT user_id,email,display_name,email_confirmed,account_role,account_status
FROM pyroguard_account_identities WHERE email='YOUR_ACTUAL_TEST_EMAIL';

SELECT user_id,payload FROM pyroguard_mirror_records
WHERE record_type='registration_snapshot'
  AND user_id=(SELECT user_id FROM pyroguard_account_identities
               WHERE email='YOUR_ACTUAL_TEST_EMAIL');
Synchronization coverage and limits
The worker scans these 25 source tables without the admin display's 100-row cap:
Supabase source	MySQL typed mirror
admin_accounts	pyroguard_admin_accounts
profiles	pyroguard_profiles
account_identities	pyroguard_account_identities
homes	pyroguard_homes
stakeholders	pyroguard_stakeholders
emergency_contacts	pyroguard_emergency_contacts
safety_setups	pyroguard_safety_setups
user_preferences	pyroguard_user_preferences
devices	pyroguard_devices
device_current_state	pyroguard_device_current_state
device_heartbeats	pyroguard_device_heartbeats
pyroguard_camera_telemetry	pyroguard_pyroguard_camera_telemetry
system_state	pyroguard_system_state
device_commands	pyroguard_device_commands
ptz_state	pyroguard_ptz_state
ptz_commands	pyroguard_ptz_commands
sensor_history	pyroguard_sensor_history
event_history	pyroguard_event_history
camera_history	pyroguard_camera_history
camera_events	pyroguard_camera_events
audio_sessions	pyroguard_audio_sessions
mirror_records	pyroguard_mirror_records
dual_record_ledger	pyroguard_dual_record_ledger
emergency_action_logs	pyroguard_emergency_action_logs
sensor_readings	pyroguard_sensor_readings


Supporting worker-status tables, private Auth internals, binary media objects and arbitrary extra database tables are outside this 25-table application mirror. Safe identity/registration data is included; Auth passwords, hashes and access/refresh/session tokens are never copied.

Each row uses a MySQL transaction for matching typed columns plus the complete JSON archive in pyroguard_local_source_records. Both copies are read back. Extra source columns remain in the archive and are named in the table report. Target-only unknown nullable values become null; required unknown fields fail instead of inventing defaults. Source precision, length, invalid timestamps and concurrent changes can leave a table pending. Existing source defaults are copied as source data; the worker does not manufacture sensor readings.

Keyset scans use a high-water key and re-read rows to detect content changes while copying. Rows created after inspection are caught on later cycles. Verification is of the inspected version during that cycle, not one global atomic snapshot. mysql_synced is bookkeeping, not proof by itself. Outbox acknowledgments happen only after the required tables/deletions succeed, with version guards.

Captured deletes become archive tombstones. A typed row is deleted only if still absent in Supabase and previously copied by this worker; an old deletion does not delete a recreated source row. Local-only rows are not purged. Historical rows deleted before capture existed are not automatically removed. Copying the archive when moving laptops preserves the worker's ownership/deletion history.
Validation status
The worker's isolated tests cover typed/JSON read-back, null/extra-field preservation, unknown-default handling, rollback, precision, bounded pagination, full 25-table cycles, partial-failure acknowledgment handling, deletion/recreation and status/hash agreement. Test fixtures do not touch production. npm.cmd test runs the included core tests locally.

This consolidation validates SQL/source syntax, table/file coverage and ZIP integrity. Flutter compilation, actual Windows task execution, MySQL export/restore and live hardware/database round trips are performed on your laptops, not in this editing environment. Your successful live worker output is stronger evidence than static syntax checks, but run the actual-record and transfer tests above before relying on the main laptop for the capstone.
Current error repairs
The Supabase SQL adds the missing account identity event, logged_in_at and logged_out_at columns, and reloads the PostgREST schema cache. Run the complete Supabase section of database/PYROGUARD_ALL_QUERIES.sql in the Supabase SQL Editor; do not paste isolated fragments.

The shared glass panels and highlighted mobile navigation tiles now contain transparent Material layers so ListTile backgrounds and ink effects paint above the panel decoration. Rebuild the Flutter application to receive this UI fix.

“MySQL mirror pending” means Supabase saved the source data and the local worker has not acknowledged its MySQL copy yet. Run the worker on the active MySQL laptop and inspect its cycle result and database records. Pending is not proof of a successful MySQL write.
Current admin management and automatic tutorial playback
Tutorial pages autoplay with no play, pause, volume or scrub controls. Next, previous, swipe, page indicators and Skip from the first drawing remain. Audible autoplay is attempted; browsers that block it use muted playback so drawings and cards still animate automatically. Browser sound cannot be forced without a permitted user gesture.

The verified administrator can enable/disable homeowner sign-ins and rename registered devices. Fixed administrator accounts cannot be modified through homeowner management. Disabling blocks future sign-ins; an existing access token may remain valid until expiry. Auth and source-profile status updates are separate operations: an incomplete write is reported and must be retried, never presented as fully saved. Source changes are mirrored by the active local MySQL worker.

The device menu queues Arm Home, Arm Away or Disarm for the selected registered device. The administrator sees command ID, pending/applied/failed status and the actual device result. A queued command does not prove physical execution. The admin may manage configuration and inspect sensor telemetry; the application does not fabricate readings or calibrate a physical MQ-2 remotely.

Deploy the updated server functions from the application root:
npx.cmd --yes supabase@latest functions deploy admin-console --project-ref torzyarstitxsreoqcig --use-api
npx.cmd --yes supabase@latest functions deploy device-command --project-ref torzyarstitxsreoqcig --use-api
The device-command function requires PYROGUARD_DEVICE_KEY as its private secret; the main board's HISTORY_DEVICE_KEY must match. Do not put the service-role key in firmware. Configure the gateway/function JWT setting for the actual firmware device-key request; test that invalid device keys are rejected before deployment. The function accepts only explicit applied/failed acknowledgements for a pending command belonging to that device. Local-PC acknowledgements stay MySQL-pending until the worker mirrors them.

The bundled main ESP32-S3 sketch now polls the device-command gateway every two seconds and reports supported/unsupported results. Install ArduinoJson 6.x, fill in actual Wi-Fi credentials, device ID and revocable device key, and enable only the wired modules. Arm Away gates the three-PIR motion action; Arm Home and Disarmed suppress PIR-triggered actions. Fire/smoke sensing remains active. Motion enable/disable is supported only when ENABLE_PIR is on. Door/window hardware handlers are not implemented in this sketch, so those commands return failed instead of pretending to switch a sensor. PTZ uses its separate ptz_commands/ptz_state transport; it requires ENABLE_PTZ, verified servo pins and working firmware polling. The separate camera/audio board requires its own correct configuration and network access.

Hardware acceptance test: queue one control for the actual registered device, inspect its device_commands status/result, observe the physical effect, then confirm the same record in MySQL after a successful worker cycle. Repeat for mode, motion, PTZ/home/preset/tracking, camera and audio. Turn the board off and verify commands remain pending; turn it on and check actual acknowledgements. Test door/window only with firmware handlers and real wiring. Never infer physical success from a toggle changing on screen or from a successful database write. This release has static code checks and isolated worker tests; it has not been compiled with the Arduino toolchain or exercised on physical boards.
Repair the permission failures in the supplied Flutter log
Run the updated complete Supabase SECTION 1 from the compiled SQL file. It now includes pyroguard_save_session, a narrow authenticated RPC that derives the caller's identity from Supabase Auth and the existing admin registry. The browser never supplies its own role, account status, target user or email. Missing source profile/identity records are created from the real account; existing roles/status are preserved and mismatches/disabled accounts are rejected. No passwords, sample records or administrator seeds are introduced.

The same section adds named compatibility policies for owned profile, mirror and ledger records on existing tables, and required sequence grants. Existing unrelated policies are retained. Restrictive policies can still block writes and should be inspected if a 42501 remains. Do not disable RLS or grant browsers access to auth.users. This replaces the earlier missing-table-only policy approach for these specific logged failures.

Stop the old Flutter process and rebuild this updated application. The old client still performs direct identity upserts; the new client uses the session RPC. Copy only your private worker .env into the updated worker folder, keep it outside shared ZIPs, and run npm.cmd run once followed by npm.cmd start after successful verification. Pending MySQL messages continue until the worker commits the real source records. Local-mode history uses Supabase fallback, rather than trying to read a database on another PC from a cloud function.
New account not visible or not copied
The registration function first creates a pending Auth signup. It returns awaiting_confirmation=true without creating completed application records for an unconfirmed email. Confirmed source writes are read back before reporting source_saved=true. A failed source write is now reported as an unverified application account, not mislabeled as only a pending MySQL copy. The compiled Supabase section grants the server and worker the required table/sequence privileges on existing tables too. It never grants public access to Auth users.

Redeploy register-account along with the admin-console and device-command updates:
npx.cmd --yes supabase@latest functions deploy register-account --project-ref torzyarstitxsreoqcig --use-api
For an account already created, do not create another account. Check Supabase Authentication Users for the actual email, apply SECTION 1, then run the PC worker once. The worker repairs missing profile/identity/snapshot rows from the real confirmed Auth account and copies them to MySQL, only after email confirmation. In Supabase Table Editor inspect profiles.user_id and account_identities.user_id; in MySQL Workbench inspect pyroguard_profiles and pyroguard_account_identities by that same user_id or email. A 25/25 result with empty tables is not enough: confirm this actual account's ID/email in both engines and its current admin verification status. If it is absent from Auth too, signup never completed; inspect the registration response/function logs rather than inserting a fake account row.
REQUIRED: Confirm Account before completed registration
In Supabase Dashboard → Authentication → Sign In / Providers → Email, enable Confirm email. Deploy the updated register-account function. Use a real reachable Site URL and allowed redirect URL (the deployed web app, for example your actual Vercel URL); a localhost URL is not reachable from another device.

Registration now has these stages:
1. Submit signup: Supabase Auth stores the pending identity needed to send verification. No completed application profile/identity/snapshot is created for the unconfirmed signup, and the worker skips it.
2. Click Confirm Account in the Supabase email: Auth verifies the email. Merely opening the app or a custom HTML button is not sufficient; the email template button must use Supabase's actual confirmation link.
3. The confirmed user's session RPC/first login and active worker recover the real application profile/identity and metadata. The MySQL copy completes only after the worker's verified cycle. The admin shows awaiting confirmation before that click, then the actual source/MySQL status afterward.
The server rejects immediate-session signups when Email confirmation is disabled rather than finalizing them as completed accounts. The session RPC also rejects unconfirmed homeowner identities. Existing records created by older versions are preserved; this update does not delete older unconfirmed source/MySQL rows. Inspect and resolve those separately if needed.

Test using a real new email: before confirmation, check Auth is pending and application profile/MySQL account rows do not exist. After clicking the genuine email button, verify email_confirmed_at is populated, run the worker, and inspect the same user ID/email in both databases. The pending Auth record must exist before verification so Supabase can send and validate the link; it is not yet a completed application account.

The protected active admin registry, matching Auth email and source roles are authoritative for administrator mirror access. Old missing app-metadata role labels do not force a valid registry administrator into a homeowner identity. Browser requests cannot create or edit admin registry rows through these repairs.
Philippine phone numbers
Signup phone fields show the fixed +63 country prefix and accept at most 10 national digits. Pasting an 11-digit local number starting with 0 converts it to national format. Homeowner mobiles must start with 9 and contain 10 national digits. Values are saved in +63 format; the local leading 0 is removed, not added after +63. Server registration also validates and normalizes phone metadata. Settings saves normalize numbers and reject excess digits. Existing saved phone values are not automatically rewritten.
Current production confirmation link and responsive tutorial
The registration function now passes emailRedirectTo=https://pyroguard-web-blue.vercel.app/ directly. Deployment of this function does not change hosted Supabase Auth settings. In the Supabase dashboard set Authentication → URL Configuration → Site URL to https://pyroguard-web-blue.vercel.app/ and add that exact URL to Redirect URLs. Keep Confirm email enabled. In Authentication → Email Templates → Confirm signup paste the complete contents of supabase/templates/confirm_signup.html. Its button and fallback link both use {{ .ConfirmationURL }}; a plain link to the Vercel homepage does not verify an account. After saving settings, request a fresh email; old email links do not change retrospectively. Official documentation: https://supabase.com/docs/guides/auth/auth-email-templates and https://supabase.com/docs/guides/auth/redirect-urls.

Redeploy register-account and admin-console after applying the updated complete Supabase SECTION 1. Rebuild the Flutter web app and deploy the new build to the existing Vercel project. The updated role resolver calls the protected source-repair RPC before checking the account role, so a newly verified user can obtain their real profile/identity immediately rather than waiting for the PC worker. Private server credentials remain outside the web build.

Tutorial Skip is visible and enabled from page 1; it saves onboarding completion and opens the homeowner dashboard. Cards now use rounded Material cards with elevation and circular icon badges. The whole tutorial is centered within 1120 pixels on wide screens; its content is capped at 1080 pixels and individual cards at 430 pixels. Wide screens show drawing and card side by side; phones stack the drawing above the card. Card content scrolls if space or large text requires it. Drawing playback remains automatic with no play/pause/volume controls. Password guidance is visible on signup and login: 12–256 characters, uppercase, lowercase, digit, symbol and no spaces.
Worker repair for confirmed accounts that were skipped
The earlier worker required confirmation_sent_at in addition to email_confirmed_at. Email-delivery metadata can be absent in returned Auth records and is not proof of whether an account is verified. That extra filter has been removed from the worker, session RPC and admin repair. Supabase's actual email_confirmed_at is the verification authority. Keep Confirm email enabled so new email/password accounts receive the confirmation message; unconfirmed signups remain pending and are not bootstrapped into completed records.

Stop the old worker with Ctrl+C, use the updated deployment/local-mysql-sync folder with the actual private .env, and run npm.cmd ci, npm.cmd run once, then npm.cmd start after a successful cycle. The worker must run on the PC hosting MySQL (or have an explicitly configured reachable host); deploying Flutter to Vercel cannot start or reach MySQL at that PC's 127.0.0.1. Check MySQL Server is running, MYSQL_DATABASE names the actual restored schema, SUPABASE_SERVER_KEY is a valid private server credential and the PC has internet access.

Verify a real confirmed account in Supabase profiles/account_identities and MySQL pyroguard_profiles/pyroguard_account_identities using the same user ID/email. If a cycle still fails, use its exact named table/error; do not assume a UI message proves the MySQL copy succeeded. The code fixes and isolated checks do not establish live connectivity to your PC's databases. Follow the main-laptop transfer section to move the actual backup and run only one active worker.
Incident email, SMS and background push: current status and required setup
The current NotificationService creates local notifications when the application detects supported sensor events. Its sms: links open the phone SMS composer and require the user to send; these are not automatic modem messages. Supabase signup confirmation email does not send incident alerts. No automatic incident-email provider, modem gateway or background push delivery has been configured or tested in this release. Saving notification preferences is not proof of delivery.

Automatic incident delivery requires a continuously running server or main-laptop worker that processes actual persisted incident IDs and their owning users. Before implementation, identify the modem manufacturer/model/firmware and carrier/SIM plan, the incident email provider and push project. Do not invent a modem endpoint or put provider secrets into Flutter. A modem number alone cannot authorize or send a text. SMS requires a supported authenticated local SMS API or a USB/serial AT interface and an SMS-capable SIM/plan. Check the manufacturer's documentation for that exact device; a router's manual SMS page does not establish an automation API. A supported modem sends from its own installed SIM. Where no SMS interface is available, use a supported SMS gateway or dedicated SMS modem.

Use a durable delivery queue with one entry per real incident, recipient and channel, user alert preferences, bounded retries and duplicate prevention. Keep pending/sent/delivered/failed distinct; a queued request or modem acceptance is not handset delivery. Store real delivery receipts and errors and synchronize those records to MySQL after an additive schema migration. Never mark a channel delivered without evidence. Keep camera recordings private: include an authenticated incident link, not a public unrestricted recording URL. Unknown motion/recording should be described as unrecognized activity only if the actual hardware/classifier reports it; recording alone is not proof of an intruder. Emergency services remain a deliberate user action.

For phone/web alerts while the app is closed, configure a push service and device-token registration with ownership checks and logout cleanup. Flutter local notifications alone do not deliver remote background incidents; web push also requires a service worker. Test a real owned incident across in-app history, email inbox, SMS handset receipt and background push, including offline recovery and duplicate retries, before claiming end-to-end operation.

References: https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages ; https://www.twilio.com/docs/messaging/guides/outbound-message-status-in-status-callbacks ; an example AT-capable modem (not confirmation of your router): https://www.waveshare.com/wiki/SIM7600G-H_4G_HAT_%28B%29 .
Email OTP signup confirmation
Signup now opens /verify-email. The user enters the real six-digit Supabase email token and taps Confirm Account; verifyOTP uses OtpType.email. The server verifies expiry, invalid codes and token reuse. No OTP is generated or stored in Flutter or MySQL. The existing email confirmation link is retained as an alternative. Keep Confirm email enabled and paste the updated supabase/templates/confirm_signup.html into hosted Authentication > Email Templates > Confirm signup: it includes {{ .Token }} and {{ .ConfirmationURL }}. Function deployment alone does not change the hosted email template. Rebuild/redeploy Flutter after these changes.

A returning unconfirmed user can open /#/verify-email on the deployed Flutter web app, enter their signup email, and request a new confirmation after the countdown. Resend uses the signup confirmation flow, not passwordless account creation. The UI waits 60 seconds; Supabase applies its actual server rate limits. Configure the hosted Email OTP expiration to an appropriate short interval, and keep the six-digit OTP length aligned with this UI. Auth holds a pending signup before verification; completed application records are created only after verified Auth, and the local worker subsequently mirrors and checks real rows. OTP verification does not mean MySQL has already committed.

The submitted modem product screenshot has ZLT T10 Plus selected and also lists MeiG SLT728. The exact installed device model/firmware remains unverified until checked on its label. No automatic SMS API for this DITO router has been verified, so no invented modem integration or shared personal phone number is included. Check whether the router management page offers outbound SMS and whether the manufacturer documents an API; receiving carrier messages is not proof that automatic outbound SMS is supported.

OTP reference: https://supabase.com/docs/reference/dart/auth-verifyotp .
11 October: saved-data restoration, OTP delivery and confirmed modem
The actual device label confirms C&M SLT728, a 4G CPE, with WebUI at 192.168.8.1. The earlier shopping-page ZLT T10 Plus selection was not the installed model. No outbound SMS API is established by the label. While connected to its Wi-Fi, open the printed WebUI address, sign in privately and inspect SMS/Messages for an outbound Send/Create action. Confirm a manual text can reach your own phone and ask the manufacturer/carrier for the exact firmware's supported SMS automation interface. Do not guess endpoints, bundle router passwords or infer outbound capability from receiving messages. This update does not connect automatic modem SMS.

Signup email OTP requires a configured Supabase sender. The default SMTP service is restricted to organization-team addresses and limited testing; it is not suitable for arbitrary capstone users. Configure custom SMTP in hosted Supabase Authentication using a real authorized sender, host, port and private credentials. Keep Confirm email enabled, save the updated confirm-signup template with {{ .Token }} / {{ .ConfirmationURL }}, and configure the production Site URL/redirect allowlist. The confirmation input now supports configured 6–8 digit numeric codes. Login includes Confirm signup / resend email code, so a returning unconfirmed user can retry without registering again. Expiry and rate limits are enforced by Supabase. Test an actual non-team recipient, including spam folder, invalid/expired code and resend. No SMTP credentials or guaranteed delivery are included. Reference: https://supabase.com/docs/guides/auth/auth-smtp .

Saved setup is loaded by the authenticated user's ID from Supabase on reopening. Bootstrap now fills missing setup rows instead of replaying signup defaults over existing home/contact/safety/preference/device rows. Existing security mode/state is not overwritten with DISARMED on a retry. A missing state insert uses ignoreDuplicates to preserve a concurrently created device state. Multiple registered devices no longer make the settings page's single-device read fail: the settings summary selects the latest registered row. This summary does not remove any other device records. Existing server data is authoritative; MySQL mirrors it after the worker verifies a cycle. An explicit restore from a MySQL backup is an operator procedure, not an automatic reverse sync.

The app now starts incident history logging independently of local notification, sound and SMS-composer execution, so notification failure cannot prevent the history attempt. Warning/fire event_type and source timestamp are retained explicitly. History persistence still requires successful authenticated database writes; this is not an offline-guaranteed durable client queue. Local notification failures are caught, web avoids the unsupported native notification plugin, stored notifications/push preferences are consulted for OS notifications, and automatic opening of the homeowner SMS composer respects SMS preferences. A deliberate manual BFP SMS action is separate. Previous-user emergency contact values are cleared before loading the current account's contacts. Critical sensor alarms remain active independently of optional OS notification preferences.

This release does not include a configured incident email sender, automatic modem SMS or remote background push. These need separate provider/gateway integration, real credentials and delivery receipts. Foreground app warning banners/fire overlays, local device notifications where permission is granted, incident history and manual contact actions are different from remote delivery. A stored email/SMS preference is not a sent message. Do not claim a notification arrived without seeing it on the intended recipient/device.

Restoration acceptance test: (1) Sign in with your real confirmed account. (2) Edit home details, primary contacts, alert preferences and theme; set a supported security mode and obtain its real acknowledgement. (3) Run the worker and compare the same owned rows in both databases. (4) Close/reopen and sign out/in; verify the latest saved settings and existing incident/media history are loaded without reverting to signup values. (5) Run a setup retry and confirm existing records remain unchanged. (6) On another phone sign in to the same account and inspect those records. (7) Deny OS notification permission and generate a real sensor event: history should still be attempted and the in-app warning should remain available. (8) Inspect actual source rows and MySQL read-back; a visual alert is not proof of either write.

The 25-table mirror covers defined application records, not every arbitrary database table. Photos/videos are stored in Supabase Storage and their links/metadata are mirrored; back up Storage objects separately for disaster recovery. Auth passwords/OTP/access tokens are intentionally not copied to MySQL. No seeded users, readings, recordings or personal modem credentials are added. Flutter/Arduino builds, live SMTP delivery, hardware round trips and live source/MySQL connectivity must be validated on your deployment machines.
Email OTP after 24 hours of inactivity
Email is the selected verification channel; no SMS provider is required. Signup keeps its confirm-signup OTP/template. Returning users now have a separate email sign-in code flow. Save supabase/templates/reauth_email.html into hosted Authentication > Email Templates > Magic Link; its {{ .Token }} supplies the code for signInWithOtp. Save the existing confirm_signup.html into Confirm signup separately. Keep custom SMTP configured and enabled; neither template configuration nor sender credentials are changed by deploying the Flutter code. Rebuild/redeploy Flutter.

The device-local inactivity monitor records real pointer/tap, scrolling and keyboard interactions for an authenticated account and persists the timestamp across restart. A route check and a 30-second foreground poll check expiry; resuming the app checks again. No interaction for 24 hours locks that account on that device, signs out the local session and opens Verify to continue. A later tap does not reset an already expired timestamp. Supabase background token refreshes do not count as user activity. Logging in with a password on that locked device does not clear the OTP-required marker. A new installation with no prior activity history establishes its initial baseline; this is not an account-wide security policy. Changed/cleared device storage or a different device can bypass the local marker. A clock moving backwards locks conservatively.

The returning user taps Send / resend email code and verifies the real Supabase code. signInWithOtp uses shouldCreateUser=false; this flow does not register a new account. Verification clears only that account's inactivity marker and starts a fresh 24-hour activity period. The server still checks the real code and expiry. OTP lifetime is separate from the 24-hour inactivity threshold; keep the hosted OTP lifetime short. The returning-user template is code-only to avoid consuming its token in a link before it can clear the device lock. Signup still offers its confirmation link.

The returning-user bootstrap does not force setup and does not reset existing home/contact/preferences/security records. Admin routing and MFA checks still apply after verification; admins return to admin, onboarded homeowners to dashboard, and unfinished homeowners to the tutorial. App local signout does not delete server records, media or the MySQL mirror. Live device monitoring/incident processing on configured hardware is separate from a user's app login.

This is an application-level device inactivity lock, not a guaranteed revocation of all server access tokens or account sessions. Strong server-enforced session lifetime/inactivity settings require the appropriate Supabase plan/configuration and security policy; they are not automatically enabled here. A previously issued JWT may remain valid until expiry.

Acceptance tests: Verify signup with a real email. Save actual settings/history, then on a development test build set the local activity timestamp for that user's device to just before 24 hours and confirm no lock, then just past 24 hours and confirm the OTP screen on resume. Check exactly 24 hours locks, foreground idling locks, restart retains the marker, and password login does not bypass it. Request a real email, check invalid/expired code errors and resend cooldown, verify a fresh code, and confirm the same account ID/settings/history remain. Test admin routing and MFA separately. Test account switching to ensure another user's OTP does not clear the original user's marker. Restore the normal 24-hour configuration before demonstration; do not fabricate production records to test timeout.

Syntax/configuration checks passed; the full Flutter build and live email delivery still need testing on the deployment laptop with hosted SMTP/templates.
App-to-hardware command integration update
PTZ firmware now uses the device-command Edge Function for command reads, state reports and acknowledgements, rather than anonymous direct REST access to protected PTZ tables. Deploy the updated device-command function. Apply current Supabase SECTION 1: it adds nullable ptz_state.last_device_at, updated only by device reports. The MySQL worker preserves this extra field in its complete JSON archive even if the existing typed mirror lacks the column. No schema reset or fake report is inserted.

The gateway rejects invalid device keys and unregistered device IDs, validates PTZ angle ranges, and permits acknowledgements only for a matching pending command/device. Keep the device key private. The current installation uses a shared configured device key; it is not a complete per-device provisioning or certificate system. Configure only trusted boards and rotate compromised keys.

PTZ now uses the authenticated account's configured device ID instead of a fixed default target. Its READY status requires last_device_at from the actual firmware gateway. Changing auto_tracking settings cannot renew this device heartbeat, and device position reports preserve the app's desired auto_tracking value. The firmware reports while idle as well as after movement. Unknown presets, modes or invalid manual coordinates report failed instead of falsely reporting execution. Home/manual/preset/stop requests are idempotent and retry if acknowledgement delivery fails. Servo position reports describe the commanded angle, not encoder-measured confirmation; observe the physical servo during acceptance tests. The speed field is not implemented as a servo-speed controller.

Homeowner security settings now show the latest actual device_commands status/result. Desired settings and pending requests are not proof of hardware application. Security feedback subscriptions are closed when leaving the homeowner shell. A missing configured device ID prevents command submission instead of silently targeting a default device. The admin's existing command-result view remains available. The current feedback summary shows the latest command, not a full multi-command execution transcript.

Deployment order:
1. Register the actual board in the app with the intended DEVICE_ID; confirm devices has that ID and owning user.
2. Apply the current complete Supabase SECTION 1.
3. Deploy from the project root: npx.cmd --yes supabase@latest functions deploy device-command --project-ref torzyarstitxsreoqcig --use-api .
4. Configure PYROGUARD_DEVICE_KEY as a private function secret; set matching HISTORY_DEVICE_KEY in the firmware privately. No service-role key goes into the board or Flutter. Function JWT verification remains disabled for this endpoint because it verifies the explicit device key itself.
5. Configure actual Wi-Fi credentials, Supabase project and DEVICE_ID in firmware. Enable ENABLE_PTZ only with wired servos and verified pins/supply; enable ENABLE_PIR only with wired PIR modules. The bundle leaves optional modules disabled by default so unwired hardware is not assumed. Install ArduinoJson 6.x and ESP32Servo for enabled PTZ, select the actual ESP32-S3 board, compile and flash. Avoid camera/servo pin conflicts.
6. Rebuild/redeploy Flutter and keep the configured MySQL worker running. Confirm gateway registration/key errors in Serial Monitor without exposing credentials.
Acceptance: With the board off, queue one supported command and confirm it stays pending. Power on and connect it, confirm PTZ's device heartbeat, queue HOME and a small manual movement, watch the actual servo and inspect executed/failed. Test a configured preset and unknown preset failure. For supported security/PIR wiring, test Arm Away, Arm Home, Disarm and motion enable/disable; inspect the real command status/result and observe effects. Check fire/smoke detection stays active independently of intrusion modes. Stop the board and verify PTZ freshness expires. Compare the same command IDs/state reports in Supabase and MySQL after a verified worker cycle.

Camera capture/live streaming, microphone/speaker paths and door/window controls each need their own matching firmware and wiring. The latest addition implements optional door/window reed-contact handlers with explicit wiring configuration; camera/audio physical tests remain required. Do not expose anonymous writes to bypass telemetry producer permission errors. The gateway command tests and source syntax checks passed; Flutter/Arduino compilation and real board acceptance tests remain on the deployment laptop.
Latest changes: authenticated hardware readings and persistent incidents
Added main-board telemetry actions to supabase/functions/device-command/index.ts. Firmware now sends device_current_state, device_heartbeats and sensor_history through the private device-key gateway, instead of anonymous REST writes to protected tables. The gateway accepts only these explicit tables/fields and derives history ownership from the registered devices row. Client-supplied user IDs and sync completion flags cannot replace the owner or mark MySQL complete. Failed DHT readings store null rather than a stale temperature/humidity.

Added incident_queue_module.h: actual smoke warnings, confirmed smoke-plus-flame transitions, armed PIR motion and configured door/window openings are submitted to event_history from the board, including when the app is closed. Twenty pending incidents at most are retained in ESP32 NVS and retried over HTTPS. Queue overflow/storage failures are logged; indefinite offline retention cannot be guaranteed. The source created_at is the server receipt time; captured_uptime_ms is board uptime, not a fabricated UTC capture time. Repeated identical warning levels do not create a new incident every sample. record_key is unique per queued event and server retries use ignoreDuplicates, preserving the original record. Existing application alerts may still create separate history entries; cross-producer deduplication is not claimed. No person-recognition classifier was added.

Added perimeter_module.h and actual ARM_DOOR/DISARM_DOOR/ARM_WINDOW/DISARM_WINDOW handlers. Above the module includes in pyroguard_esp32s3.ino define ENABLE_DOOR=1 and DOOR_SENSOR_PIN to the actual GPIO, and/or ENABLE_WINDOW=1 and WINDOW_SENSOR_PIN to its actual GPIO. They are disabled by default. This implementation uses INPUT_PULLUP with a closed reed contact to ground: LOW=closed, HIGH=open. Verify contact polarity and GPIO/supply compatibility before enabling. Compiling enabled hardware without its configured GPIO fails deliberately. Open contacts produce incidents only when their protection is enabled and security is armed. These are protection switches, not door-lock actuators. Fire/smoke sensing remains active when intrusion protection is disabled. Configure module flags in the sketch before includes, not after the security header.

Camera firmware now has /api/motion/on and /api/motion/off routes, reports motion_detection_enabled, and refuses enable commands when the camera/audio subsystem is not ready. The Flutter microphone/speaker/motion methods read back /status before returning success. Night vision remains unsupported until a real IR actuator and its pin/driver are specified. Camera/audio routes currently require the actual board IP on a trusted LAN; an HTTPS Vercel page cannot reliably call or stream an HTTP private-IP device because of browser transport restrictions. Remote secure camera transport, automatic incident email/SMS/background push are still separate integration work. Do not describe all controls or media as remotely available or physically tested.

The local MySQL worker remains responsible for verified asynchronous Supabase-to-MySQL mirroring. Source save success does not claim simultaneous atomic commits. Its complete JSON archive preserves event record_key even where the typed MySQL table lacks that new column. MySQL must be running and the worker must stay active on the main laptop.
Apply this update, in order (PowerShell)
1. Back up both databases. Replace application source with this ZIP's PyroGuard_RoleSeparated contents, preserving your existing local Git repository and private deployment/local-mysql-sync/.env. Do not overwrite your private credentials with examples.
2. In Supabase SQL Editor run the entire PostgreSQL SECTION 1 of database/PYROGUARD_ALL_QUERIES.sql, including its final COMMIT. Do not execute SECTION 2 there. Section 1 now adds event_history.record_key and its unique index plus ptz_state.last_device_at without resetting existing rows. Use MySQL SECTION 2 only in MySQL Workbench if installing/updating the mirror schema; do not run fragments from a DO block.
3. From the application root authenticate and deploy the functions:
npx.cmd --yes supabase@latest login
npx.cmd --yes supabase@latest functions deploy --project-ref torzyarstitxsreoqcig --use-api
Ensure the hosted private PYROGUARD_DEVICE_KEY is configured and matches HISTORY_DEVICE_KEY on trusted firmware. Service-role/server keys belong only in private server/worker configuration. Do not commit board Wi-Fi passwords or device keys. No new real credential is included in this ZIP.
4. In Arduino IDE install ESP32 board support, ArduinoJson 6.x, DHT dependencies and the enabled hardware module libraries. Configure the real board ID/owner, pins, Wi-Fi and matching device key; compile and flash the sensor sketch. Flash the separate camera/audio sketch on its intended board when using its routes. These sketches cannot substitute for verification of the actual hardware pinout.
5. Check the Flutter app locally:
flutter pub get
flutter analyze
flutter run -d chrome
For physical LAN camera/audio testing use the installed mobile/desktop app where appropriate. Build Android with flutter build apk --release.
6. Start the real MySQL service. Then:
cd deployment/local-mysql-sync
npm.cmd install
npm.cmd test
npm.cmd run once
npm.cmd start
Review actual parity results and errors; keep this worker terminal/service running. Never insert sample users/incidents to make a dashboard appear populated.
Update the existing GitHub repository
Extract and copy the updated contents into the existing tracked application folder (the folder containing lib, pubspec.yaml and supabase). Keep its existing .git directory. Use your actual GitHub identity, then:
git config user.name "YOUR ACTUAL NAME"
git config user.email "YOUR VERIFIED GITHUB EMAIL OR GITHUB NOREPLY EMAIL"
git status
git remote -v
git branch --show-current
For the existing main branch and previously configured origin https://github.com/Nowisaurus/Pyroguard-Application-System.git:
git add .
git diff --cached --stat
git diff --cached
git commit -m "Connect hardware telemetry and retain incident records"
git push origin main
Before committing, inspect staged content for passwords, device keys, worker .env and SQL data dumps. The included .gitignore excludes private environment files, build output, archives and local tool dependencies, but ignore rules do not untrack files already committed. Remove previously tracked private files from Git tracking, rotate exposed credentials, and keep private local copies. If your current branch is not main, push the actual intended branch and verify Vercel tracks it. Do not force-push. If this folder has no Git repository, initialize it only after confirming it is the intended source folder: git init, git branch -M main, git remote add origin https://github.com/Nowisaurus/Pyroguard-Application-System.git, then commit before pushing. If the remote already has commits, clone that repository first and copy the updated files into the clone; do not replace its history.
Update the existing Vercel site
Open the existing pyroguard-web-blue Vercel project. Verify Settings → Git connects to Nowisaurus/Pyroguard-Application-System and the tracked Production branch is the branch you push (normally main). Pushing a new commit to that connected production branch triggers a deployment; monitor Deployments and build logs. Keep the root directory pointing to the directory containing pubspec.yaml. Use the project's existing Flutter installation/build setup; the build must run flutter pub get and flutter build web --release, with Output Directory build/web. A stock Node build does not compile Flutter, and the Vercel builder must have Flutter installed by your build setup. Do not upload the entire source ZIP as static web output.

If the project is not Git-connected, connect the repository in Vercel or build locally with flutter build web --release and use the existing Vercel project's manual deployment workflow for build/web. Confirm the successful production deployment's domain remains https://pyroguard-web-blue.vercel.app/. Test a fresh email verification and the /#/verify-email screen there; retain the matching Supabase redirect allowlist and saved email templates. GitHub/Vercel deployment alone does not run SQL, deploy Supabase functions, start the local worker or flash boards.

References: https://vercel.com/docs/git ; https://supabase.com/docs/guides/functions/quickstart .
Real-device acceptance before claiming completion
Confirm a registered device/owner and matching private device key. With the board offline, queue a supported command and verify pending; connect it and observe the actual movement/protection state and applied/failed acknowledgement. For each enabled contact open/close the real switch and test arm, disarm and protection off. Generate controlled sensor inputs safely without starting a real fire; verify source event_history and its matching MySQL archived record after worker readback. Disconnect internet, create a supported incident, reboot the ESP32, reconnect and confirm the durable queued event arrives once by record_key. Check queue-full/NVS errors rather than assuming unlimited storage. Test actual camera, motion, mic and speaker responses and disconnect failures on the intended LAN. No physical board tests or hosted deployment were performed by the package author in this update.

Camera-board addition: its current telemetry now also uses the private device-key gateway, with camera/controller association checks; it no longer calls the anonymous telemetry write or legacy history mirror from postTelemetry. Real frame-motion events are queued durably through the same incident mechanism and saved into event_history with the registered controller owner. This records frame change, not proof of an unfamiliar person or a saved photo/video. Camera media uploads and a remote HTTPS stream are not added. Configure the existing SUPABASE_ROOT_CA with the correct trusted CA before production: the camera sketch's inherited blank-CA prototype mode skips certificate verification. Install ArduinoJson 6.x for the camera sketch too. Keep its incident_queue_module.h beside the camera .ino when compiling.