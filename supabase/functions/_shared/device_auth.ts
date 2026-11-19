// PyroGuard shared device authentication (2026-11-19)
// ---------------------------------------------------------------------------
// A device sends its key in the "x-device-key" header. The key is accepted if
// it matches ANY of these Edge Function secrets (set only the ones you use):
//
//   PYROGUARD_DEVICE_KEY / PYROGUARD_INGEST_KEY   shared key (old setup)
//   DEVICE_KEY_<ID>                               plain key for one device
//   DEVICE_KEY_SHA256_<ID>                        SHA-256 (hex) of that key
//   + legacy hash secrets passed by the caller (e.g. SENSOR_DEVICE_KEY_SHA256)
//
// <ID> is the device id in upper case with "-" replaced by "_":
//   ESP32-001 -> ESP32_001     pyroguard_camera_001 -> PYROGUARD_CAMERA_001
// ---------------------------------------------------------------------------

const env = (name: string) => Deno.env.get(name)?.trim() ?? ''

export function safeEqual(a: string, b: string) {
  if (a.length !== b.length || a.length === 0) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

export async function sha256Hex(value: string) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(d)].map((n) => n.toString(16).padStart(2, '0')).join('')
}

export const secretSuffix = (deviceId: string) => deviceId.toUpperCase().replace(/[^A-Z0-9]/g, '_')

export async function deviceAuthorized(req: Request, deviceId: string, legacyHashSecrets: string[] = []) {
  const supplied = req.headers.get('x-device-key')?.trim() ?? ''
  if (supplied.length < 16) return false
  const id = secretSuffix(deviceId)

  for (const plain of [env('PYROGUARD_DEVICE_KEY'), env('PYROGUARD_INGEST_KEY'), env(`DEVICE_KEY_${id}`)]) {
    if (plain && safeEqual(supplied, plain)) return true
  }
  const hashes = [env(`DEVICE_KEY_SHA256_${id}`), ...legacyHashSecrets.map(env)]
    .map((h) => h.toLowerCase()).filter((h) => /^[a-f0-9]{64}$/.test(h))
  if (!hashes.length) return false
  const suppliedHash = await sha256Hex(supplied)
  return hashes.some((h) => safeEqual(suppliedHash, h))
}
