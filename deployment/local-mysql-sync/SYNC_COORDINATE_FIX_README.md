# PyroGuard MySQL JSON coordinate verification fix

## What changed
- `deployment/local-mysql-sync/core.mjs` allows a tolerance of 1e-9 for geographic `latitude` and `home_latitude` JSON numbers in addition to existing longitude handling.
- Tolerance is restricted to valid geographic ranges: latitude ±90, longitude ±180.
- Other numerical measurements still compare exactly.
- Full source JSON `payload_raw` and SHA-256 archive verification remain exact; this is only the typed MySQL JSON read-back comparison.
- No Supabase or MySQL schema migration is required for this JavaScript change.

## Test
From `deployment/local-mysql-sync`, keep your existing protected `.env` (the full-project ZIP does not bundle secrets):

```powershell
npm ci
npm test
npm run once
```

Expect `VERIFIED: 28/28 tables; ...; 0 errors` only if the actual MySQL read-back differences are within the permitted coordinate tolerance and there are no other errors. If `PENDING` persists, compare actual coordinate values and repair the specific precision mismatch instead of widening tolerance blindly.

## Important
- Do not place your Supabase service role key in Flutter code.
- Do not copy `.env` into version control.
- MySQL's JSON typed representation may normalize decimal formatting. The exact raw JSON archive remains preserved and hash-verified separately.
