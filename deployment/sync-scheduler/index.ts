// Optional server-side scheduler: secrets are kept in the Worker environment.
export default {
  async scheduled(_event: unknown, env: {SUPABASE_URL: string; SYNC_WORKER_SECRET: string}, ctx: {waitUntil: (task: Promise<void>) => void}) {
    ctx.waitUntil((async () => {
      const response = await fetch(`${env.SUPABASE_URL}/functions/v1/sync-outbox`, {
        method:'POST',headers:{'Content-Type':'application/json','x-sync-secret':env.SYNC_WORKER_SECRET},body:'{}',
      })
      if (!response.ok) throw new Error(`Sync worker HTTP ${response.status}`)
      const result = await response.json() as {ok?: boolean; failed?: number}
      if (result.ok !== true) throw new Error(`Sync worker has ${result.failed ?? 'unknown'} pending failures`)
    })())
  },
}
