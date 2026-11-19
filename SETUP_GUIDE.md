# PyroGuard – Supabase ⇄ MySQL Sync Fix (2026-11-19)

Project: **`gljzunjbmmsbkayxtyfc.supabase.co` (new project)** · MySQL `pyroguard_db` (local PC worker)

## NEW PROJECT – do these first (in order)

1. **Admin accounts.** Authentication → Users → **Add user → Create new user**, tick **Auto Confirm User**, for:
   `nowel@pyroguard.local`, `sean@pyroguard.local`, `danaya@pyroguard.local`, `dave@pyroguard.local`. These are the four the app's allowlist accepts.
   Don't use the `bootstrap-admins` function: it creates a different list that the app rejects.
2. **SQL Editor:** run `database/00_SUPABASE_BASE_SCHEMA_NEW_PROJECT.sql`. It creates all the core tables, the role functions, the policies and the support tickets, and registers the admins by e-mail. Its message lists any admin not created yet; add them and run it again.
   **Don't run `PYROGUARD_ALL_QUERIES_SUPABASE.sql` on the new project**, because it expects the old project's user IDs. Everything it contains is in `00`.
3. **SQL Editor:** run `database/01_SUPABASE_FINAL_SYNC_FIX.sql`. On an empty project it will report "Home 1 not found yet". That's expected.
4. **App:** use the new `lib/main.dart` (it has the new URL and anon key). Then the homeowner signs up, confirms the e-mail and completes onboarding: home, plus controller ID **ESP32-001**.
5. **SQL Editor:** run `01` **again**. Now it shows `Home 1 = homes.id …`, registers ESP32-002 and enrolls the members.
6. **MySQL:** back up the old data, run `02_MYSQL_FINAL_SYNC_FIX.sql`, then `07_MYSQL_RESET_FOR_NEW_SUPABASE_PROJECT.sql`. The old rows belong to the deleted project.
7. **Worker:** create `deployment/local-mysql-sync/.env` from `.env.example` with the new URL and the **new service_role key** (it's called `SUPABASE_SERVER_KEY`). Copy `tables.json`, then run `npm run once`.
8. Continue with steps 3–7 of the run order below: edge functions, secrets, logo upload, e-mail webhook, firmware. **Every** function and secret must be set again in the new project, including the existing ones: `PYROGUARD_MYSQL_MODE=local-pc`, plus `SUPABASE_ANON_KEY` if the dashboard doesn't provide it.
9. **Authentication → URL Configuration and Email Templates:** set the Site URL and redirect URLs again (see the Google/Facebook section), and paste your two templates (`templates/confirm_signup.html`, `templates/reauth_email.html`). Keep **Confirm email** turned ON; `register-account` refuses signups without it.
10. **Vercel:** if the web build sets `SUPABASE_URL` / `SUPABASE_ANON_KEY`, update them, or rebuild with the new `lib/main.dart`.

Files already switched to the new project: `lib/main.dart`, all four firmware sketches, `supabase/confirm_signup_email.html` (logo link), `deployment/sync-scheduler/wrangler.json`.


## Single camera (Camera 2 removed) – 2026-11-19

PyroGuard now uses **one camera: Camera 1 (DFR1154, two-way audio, pan/tilt on ESP32-001)**. ESP32-002 stays: it still covers the Kitchen and Bedroom sensors, but it has no camera.

**App (Flutter):**
* Camera tab shows **Live Camera** with one card; the **CH** (switch camera) buttons are gone.
* The "monitoring only" mode, the Camera 2 PTZ queue (`ptz_service.dart`), the Camera 2 audio board setting (`camera_two_audio_config.dart`) and the Camera 2 access key (`camera_two_endpoint.dart` → replaced by `camera_endpoint.dart`) were removed.
* Dashboard status strip and Device screen: the Camera 2 card is removed. The ESP32-002 card now says it has no camera. The Camera 1 card shows "Pan servo GPIO 13 • Tilt servo GPIO 14".
* About text updated.

**Database / functions:**
* `01` deletes Camera 2 registry and telemetry rows, drops the unused `pyroguard_camera_audio_devices` table, and limits storage uploads to the `pyroguard_camera_001/` folder.
* **Fixed:** the camera card's ONLINE badge reads `pyroguard_camera_registry.last_seen_at`, but nothing ever updated it, so the camera always looked offline. A trigger now updates it on every Camera 1 heartbeat.
* `camera-ingest` accepts only `pyroguard_camera_001`. `incident-email` attaches Camera 1 photos to Entrance/Sala alerts; Kitchen/Bedroom alerts arrive without a photo.

**Check after pulling:** `flutter pub get` then `flutter analyze`. Expect no errors; a few "unused import" infos are harmless.

## Where everything is now

| Folder | What | Run / use |
|---|---|---|
| `database/00…07` | All current SQL | in number order (see top of this guide) |
| `database/PYROGUARD_ALL_QUERIES_MYSQL.sql` | MySQL base schema | once, before `02` |
| `database/_superseded_do_not_run/` | old scripts, for reference | **never** |
| `supabase/functions/` | 11 Edge Functions (+ `_shared`) | `supabase functions deploy …` |
| `firmware/` | Camera 1, ESP32-001, ESP32-002, (alt) v3.1 | Arduino IDE |
| `deployment/local-mysql-sync/` | MySQL worker (`.env.example`, `tables.json`) | `npm ci` then `npm run once` |
| `lib/` | Flutter app (new project URL in `main.dart`) | `flutter run` |

**Connections verified:** every table and column used by the app, the Edge Functions and the worker exists in `00` + `01` (33 tables, 0 missing). All 34 worker tables exist in MySQL with their key column. All 3 functions the app calls exist. All firmware points at `gljzunjbmmsbkayxtyfc` on Wi-Fi `Pyroguard_Team`. The Camera 1 ⇄ ESP32-001 LAN key matches, and the camera IP 192.168.8.99 is the same in the camera, ESP32-001 and the app.

## What was wrong

| # | Problem | Effect | Fixed in |
|---|---------|--------|----------|
| 1 | Camera 1 firmware pointed at a **different Supabase project** (`gljzunjbmmsbkayxtyfc`) and had cloud off | No camera heartbeat or photos ever reached the app | `firmware/PyroGuard_Camera1_DFR1154` |
| 2 | `camera-ingest` Edge Function **did not exist** | Camera uploads had nowhere to go | `supabase/functions/camera-ingest` |
| 3 | `pg_ticket_guard` rejected every update without a logged-in user | The MySQL worker could never mark tickets synced; each try bumped `updated_at` → endless re-sync | `01_SUPABASE…` §1 |
| 4 | MySQL `pyroguard_room_sensor_readings` was never created (your master MySQL script even fails on it at the last line) | Room readings never reached MySQL | `02_MYSQL…` §2 |
| 5 | Two scripts defined the same fire trigger; the old one created "fires" from flame+heat | False CRITICAL_FIRE events, depending on run order | `01_SUPABASE…` §5 |
| 6 | `20261104_shared_read_only_home1.sql` let **any** signed-in account read all hardware data | Overrode the Home 1 membership rules | Removed in `01…` §4 |
| 7 | Room CHECK from 20261101 allowed only `sala`/`bedroom` | Entrance + kitchen inserts failed | `01…` §2 |
| 8 | Door/window table had no single key; MySQL admin CHECK allowed only 4 admins | Those rows could not be mirrored | `01…` §3, `02…` §0/§4 |
| 9 | The v3.1 controller sketch was hard-coded `ESP32-001`, sent a flat payload that `sensor-ingest` read only half of, and skipped the TLS certificate check | Zone 2 was lost, and a second board overwrote ESP32-001's rooms | `sensor-ingest` + `firmware/PyroGuard_ESP32_v3_1_Analog` |
| 10 | Worker health was hard-coded to "25 tables" | The app never showed MySQL as in sync | `_shared/local_sync.ts` |
| 11 | No `incident-media` / `assets` buckets were created | App snapshots failed, and the email logo was broken | `01…` §6 |
| 12 | Ticket assignment/archive guards also blocked the service role | Admin console and worker updates failed | `01…` §1 |

Your pasted queries are all folded into `01`/`02` (corrected). **Don't run the separate 20261031–20261104 migration files again.**

---

## Run order

### 0. Back up
Supabase: Database → Backups (or `pg_dump`). MySQL: `mysqldump -u root -p pyroguard_db > before_fix.sql`

### 1. Supabase SQL (SQL Editor, in this order)
1. New project: `00_SUPABASE_BASE_SCHEMA_NEW_PROJECT.sql` first, then `database/01_SUPABASE_FINAL_SYNC_FIX.sql` — safe to run more than once.
2. `database/03_VERIFY_SUPABASE.sql` — run block by block.

### 2. MySQL (Workbench)
1. `database/02_MYSQL_FINAL_SYNC_FIX.sql` → the last two result grids must show **no MISSING** and **6 columns**.
2. Copy `deployment/local-mysql-sync/tables.json` over the one in your project (it adds 5 tables).
3. Restart the worker: `cd deployment/local-mysql-sync` → `npm run once` → expect `VERIFIED: 34/34 tables`.
4. `database/04_VERIFY_MYSQL.sql` — the numbers should match step 1.2.

*Optional:* if Analytics/Calendar are still full of old noise "fires", run `05_OPTIONAL_ARCHIVE_FALSE_FIRE_SUPABASE.sql`, then `06_OPTIONAL_ARCHIVE_FALSE_FIRE_MYSQL.sql`. Run them only after the new firmware has sent data.

### 3. Edge Functions
Copy everything in `supabase/` into your project's `supabase/` folder (replacing `config.toml`, `sensor-ingest`, `device-command` and `_shared/local_sync.ts`, and adding `camera-ingest`, `incident-email` and `_shared/device_auth.ts`). Then:

```bash
supabase login
supabase link --project-ref gljzunjbmmsbkayxtyfc
supabase functions deploy sensor-ingest  --no-verify-jwt
supabase functions deploy device-command --no-verify-jwt
supabase functions deploy camera-ingest  --no-verify-jwt
supabase functions deploy incident-email --no-verify-jwt
# these import the fixed _shared/local_sync.ts, so redeploy them too:
supabase functions deploy admin-console mysql-history register-account sync-outbox --no-verify-jwt
```

### 4. Secrets (Dashboard → Edge Functions → Secrets, or CLI)
```bash
# Both ESP32 boards running the unified sketch use this key (DEVICE_INGEST_KEY in the .ino)
supabase secrets set PYROGUARD_DEVICE_KEY=ed9013b82a5fac0e6de7781337d293bf17b5be2bb5698ef8d18f0041978034a2
# Only if ESP32-002 runs the v3.1 analog sketch (its SENSOR_DEVICE_KEY)
supabase secrets set DEVICE_KEY_ESP32_002=B92843BBB888A4C390CEC029013DA205517A58BDFE3B6C823ADB7BD4B0766373
# Camera 1 (CAMERA_DEVICE_KEY in its .ino)
supabase secrets set DEVICE_KEY_PYROGUARD_CAMERA_001=8DEBA5CFC59BB60D05E3EAE3249AB333BD0C9895F50C0FC7EB68F8F1C13EEDE1
# Incident e-mails
supabase secrets set INCIDENT_WEBHOOK_SECRET=<make-a-long-random-string>
supabase secrets set BREVO_API_KEY=<from Brevo> EMAIL_FROM=dev.pyroguard@gmail.com
supabase secrets set APP_URL=https://pyroguard-web-blue.vercel.app/
# keep your existing one:  PYROGUARD_MYSQL_MODE=local-pc
```
> These device keys now appear in firmware, in old files and in this chat. They're fine for the defense, but generate new ones before any public deployment.

### 5. Buckets (created by `01…`; one manual step)
* **incident-media** (public, 5 MB, jpeg/png/webp): camera photos at `pyroguard_camera_001/YYYY/MM/DD/…jpg`, plus app snapshots.
* **assets** (public): your email template loads `assets/logo.png`. Go to Storage → assets → **Upload** and upload your logo named exactly `logo.png` (for example `assets/images/phonix_logo.png` renamed).

### 6. Incident e-mail with photo
1. **Brevo** (free, works with a Gmail sender): sign up → Senders, Domains & Dedicated IPs → **Add sender** `dev.pyroguard@gmail.com` → confirm the code they email → SMTP & API → **API keys** → create one → put it in `BREVO_API_KEY`.
   *(Resend also works via `RESEND_API_KEY`, but to email other people it needs your own domain. Edge Functions can't use Gmail SMTP because ports 25/587 are blocked.)*
2. Dashboard → **Database → Webhooks → Create**: name `incident-email`, table `public.event_history`, events **Insert**, type **Supabase Edge Functions**, function `incident-email`, method POST, header `x-webhook-secret: <INCIDENT_WEBHOOK_SECRET>`.
3. What triggers an email: confirmed **CRITICAL_FIRE**, and DOOR_OPEN / WINDOW_OPEN / MOTION while **ARMED**. Recipients are the owner plus approved Home 1 members who have e-mail alerts on (Settings). Repeats of the same alert within 5 minutes are throttled. The newest camera photo (taken from 60 s before up to 15 s after the event) is attached and shown inline.
4. Test it without a fire. In the SQL Editor, take any existing `record_key` from `event_history`, then:
```bash
curl -X POST https://gljzunjbmmsbkayxtyfc.supabase.co/functions/v1/incident-email \
  -H "x-webhook-secret: <secret>" -H "Content-Type: application/json" \
  -d '{"record_key":"<a CRITICAL_FIRE record_key>","wait":true}'
```
   Results are logged in `public.pyroguard_incident_emails`.

### 7. Firmware

| Board | Sketch | Set before upload |
|-------|--------|-------------------|
| Camera 1 (DFR1154) | `PyroGuard_Camera1_DFR1154` | nothing (Wi-Fi `Pyroguard_Team`, fixed IP 192.168.8.99) |
| ESP32-001 Entrance + Sala + PTZ | `PyroGuard_ESP32_001_MultiSensor` (`PYROGUARD_BATCH 1`) | nothing |
| ESP32-002 Kitchen + Bedroom | **either** `PyroGuard_ESP32_002_MultiSensor` (same pin map as ESP32-001, digital MQ-2) **or** `PyroGuard_ESP32_v3_1_Analog` (analog MQ-2, 4 buzzers) — pick the one that matches the wiring | v3.1: needs the `DEVICE_KEY_ESP32_002` secret |

* Use the project's unified ESP32-001 sketch, not the one you attached. It has the same pins and features, plus the false-fire guard that sends `fire_confirmed`. The file you attached never sent `fire_confirmed`, so it could never raise a fire, and it joined Wi-Fi `Infinix HOT 50`. That's not the camera's network, so the PTZ/motion link couldn't work.
* New: when a confirmed fire or an intrusion starts, ESP32-001 asks Camera 1 for an evidence photo, and Camera 1 uploads it. Camera 1 also uploads one photo when motion starts (at most one per minute).
* Serial Monitor checks: ESP32 → `[CLOUD] STORED …`; Camera → `[CLOUD] Heartbeat HTTP=200` and `[CLOUD] Photo (motion, … bytes) HTTP=200`.

---

## Google and Facebook sign-in

The app code is already done: `login_screen.dart` calls `signInWithOAuth`, and Android/iOS already register `io.supabase.flutter://callback`. Only dashboard setup is needed.

**A. Supabase URL settings** — Authentication → URL Configuration
* Site URL: `https://pyroguard-web-blue.vercel.app/`
* Redirect URLs: add `https://pyroguard-web-blue.vercel.app/**`, `io.supabase.flutter://callback`, and for local web testing `http://localhost:*` (or your exact port).

**B. Google**
1. console.cloud.google.com → create/select a project → **Google Auth Platform**:
   * Branding: app name "PyroGuard", support email, logo.
   * Audience: External. While the app is in *Testing*, add your team's Gmail addresses as test users.
   * Data Access: add the `openid` scope (email and profile are added by default).
2. **Clients → Create client → Web application**:
   * Authorized JavaScript origins: `https://pyroguard-web-blue.vercel.app` (add `http://localhost:<port>` for local web).
   * Authorized redirect URIs: `https://gljzunjbmmsbkayxtyfc.supabase.co/auth/v1/callback`
3. Copy the Client ID + Secret → Supabase **Authentication → Sign In / Providers → Google** → enable → paste → Save.

**C. Facebook**
1. developers.facebook.com → My Apps → **Create App** → use case **Authenticate and request data from users with Facebook Login**.
2. Facebook Login → Settings → **Valid OAuth Redirect URIs**: `https://gljzunjbmmsbkayxtyfc.supabase.co/auth/v1/callback`
3. Use Cases → Authentication and Account Creation → make sure **email** and **public_profile** are listed (add email if it's missing).
4. Settings → Basic → copy the **App ID** and **App Secret** → Supabase **Sign In / Providers → Facebook** → enable → paste → Save.
5. While the app is in Development mode, only people added under **App Roles → Roles** can log in. Add your panel and team as testers for the defense. Going Live needs a Privacy Policy URL, an app icon and the app domain.

**How it fits PyroGuard:** Google/Facebook accounts arrive already email-verified. The `auth.users` trigger enrolls them in Home 1 automatically, and `pyroguard_save_session` creates their `profiles` / `account_identities` rows, which the worker copies to MySQL. Admin accounts (`*@pyroguard.local`) keep using email + password.

---

## Quick acceptance test
1. Power the ESP32s → `03_VERIFY_SUPABASE` block 2 shows 4 rooms **FRESH**.
2. Open a door → `event_history` gets DOOR_OPEN → within one worker cycle it's in MySQL (`04_VERIFY_MYSQL` §5).
3. Wave at Camera 1 → a `camera_events` row with `snapshot_url` appears, and the photo opens.
4. Arm the system in the app, open the door → an intrusion email arrives with the camera photo.
5. `npm run once` → `VERIFIED: 34/34 tables`; the app's MySQL status shows parity.
6. Sign in with Google on the web build → the account shows up as `member / approved` in `03…` block 6.

**To delete test tickets on purpose** (deletion is otherwise blocked):
```sql
BEGIN; SET LOCAL pyroguard.allow_ticket_delete = 'on'; DELETE FROM public.support_tickets WHERE ...; COMMIT;
```
