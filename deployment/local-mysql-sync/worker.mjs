
import { readFile } from 'node:fs/promises';
import { createClient } from '@supabase/supabase-js';
import { createConnection } from 'mysql2/promise';
import {
  alreadyMirrored,
  business,
  digest,
  identifier,
  mirrorRow,
  pages,
  stable
} from './core.mjs';

let tables;

try {
  tables = JSON.parse(
    await readFile(new URL('./tables.json', import.meta.url), 'utf8')
  );

  if (
    !Array.isArray(tables) ||
    tables.length === 0 ||
    tables.some(t => !t.source || !t.target || !t.key)
  ) {
    throw new Error('Invalid table mappings');
  }
} catch (error) {
  throw new Error('Missing or invalid tables.json: ' + error.message);
}

for (const source of [
  'support_tickets',
  'support_ticket_messages',
  'support_ticket_events'
]) {
  if (!tables.some(t => t.source === source)) {
    tables.push({
      source,
      target: 'pyroguard_' + source,
      key: 'id'
    });
  }
}

const registrationKeys = [
  'full_name',
  'phone_number',
  'home_name',
  'address',
  'home_latitude',
  'home_longitude',
  'device_id',
  'stakeholder_name',
  'stakeholder_relationship',
  'stakeholder_phone',
  'bfp_station_name',
  'bfp_personnel_name',
  'bfp_rank_position',
  'bfp_phone',
  'bfp_address',
  'safety_acknowledged',
  'onboarding_completed'
];

const required = name => {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error('Set ' + name + ' in the private .env file');
  }
  return value;
};

const port = Number(process.env.MYSQL_PORT ?? 3306);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('Invalid MYSQL_PORT');
}

const interval = Number(process.env.SYNC_INTERVAL_SECONDS ?? 15);
if (!Number.isFinite(interval) || interval < 5) {
  throw new Error('SYNC_INTERVAL_SECONDS must be at least 5');
}

const sb = createClient(
  required('SUPABASE_URL'),
  required('SUPABASE_SERVER_KEY'),
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false
    },
    global: {
      fetch: (url, init) => fetch(url, {
        ...init,
        signal: init?.signal
          ? AbortSignal.any([
              init.signal,
              AbortSignal.timeout(30000)
            ])
          : AbortSignal.timeout(30000)
      })
    }
  }
);

const options = {
  host: required('MYSQL_HOST'),
  port,
  user: required('MYSQL_USER'),
  password: process.env.MYSQL_PASSWORD ?? '',
  database: required('MYSQL_DATABASE'),
  connectTimeout: 8000,
  timezone: 'Z',
  dateStrings: true,
  supportBigNumbers: true,
  bigNumberStrings: true,
  ssl: process.env.MYSQL_SSL === 'true'
    ? {
        rejectUnauthorized: true,
        ...(process.env.MYSQL_CA_FILE
          ? {
              ca: await readFile(
                process.env.MYSQL_CA_FILE,
                'utf8'
              )
            }
          : {})
      }
    : undefined
};

let stop = false;
let cycleCount = 0;

const FULL_CHECK_EVERY = 40;

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    stop = true;
  });
}

const checked = async (
  promise,
  operation = 'Supabase request'
) => {
  const result = await promise;

  if (result.error) {
    const error = result.error;
    throw new Error(
      `${operation} failed (${error.code ?? 'query'}): ` +
      `${error.message ?? 'Unknown error'}`
    );
  }

  return result.data;
};

async function publish(fields) {
  await checked(
    sb.from('pyroguard_local_sync_status').upsert(
      {
        worker_id: 'local-pc',
        heartbeat_at: new Date().toISOString(),
        ...fields
      },
      {
        onConflict: 'worker_id'
      }
    ),
    'Publish synchronization status'
  );
}

async function prepareAccounts() {
  const registrations = new Map();

  const admins = await checked(
    sb.from('admin_accounts').select('*'),
    'Read administrator accounts'
  );

  for (let page = 1; page <= 100; page++) {
    const { data, error } = await sb.auth.admin.listUsers({
      page,
      perPage: 1000
    });

    if (error) {
      throw new Error(
        'Auth account enumeration failed: ' + error.message
      );
    }

    for (const user of data.users) {
      if (!user.email_confirmed_at) {
        continue;
      }

      const metadata = Object.fromEntries(
        registrationKeys
          .filter(key => user.user_metadata?.[key] !== undefined)
          .map(key => [key, user.user_metadata[key]])
      );

      registrations.set(user.id, metadata);

      const admin = admins.find(a => a.user_id === user.id);
      const role = admin?.admin_role ?? 'homeowner';

      const status =
        user.banned_until &&
        new Date(user.banned_until) > new Date()
          ? 'disabled'
          : 'active';

      const name =
        admin?.display_name ??
        metadata.full_name ??
        null;

      const phone =
        metadata.phone_number ??
        user.phone ??
        null;

      const now = new Date().toISOString();

      await checked(
        sb.from('profiles').upsert(
          {
            id: user.id,
            user_id: user.id,
            email: user.email ?? null,
            full_name: name,
            phone,
            account_role: role,
            account_status: status,
            created_at: user.created_at,
            updated_at: now
          },
          {
            onConflict: 'id',
            ignoreDuplicates: true
          }
        )
      );

      await checked(
        sb.from('account_identities').upsert(
          {
            user_id: user.id,
            email: user.email ?? null,
            display_name: name,
            phone,
            account_role: role,
            account_status: status,
            auth_provider:
              user.app_metadata?.provider ?? 'email',
            email_confirmed: !!user.email_confirmed_at,
            mysql_synced: false,
            created_at: user.created_at,
            updated_at: now
          },
          {
            onConflict: 'user_id',
            ignoreDuplicates: true
          }
        )
      );

      const identity = await checked(
        sb.from('account_identities')
          .select('*')
          .eq('user_id', user.id)
          .maybeSingle()
      );

      if (
        identity &&
        (
          identity.email !== user.email ||
          identity.email_confirmed !==
            !!user.email_confirmed_at
        )
      ) {
        await checked(
          sb.from('account_identities')
            .update({
              email: user.email ?? null,
              email_confirmed: !!user.email_confirmed_at,
              mysql_synced: false,
              updated_at: now
            })
            .eq('user_id', user.id)
            .eq('updated_at', identity.updated_at)
        );
      }

      const existing = await checked(
        sb.from('mirror_records')
          .select('*')
          .eq('user_id', user.id)
          .eq('record_type', 'registration_snapshot')
          .eq('record_key', user.id)
          .maybeSingle()
      );

      if (
        !existing ||
        stable(existing.payload) !== stable(metadata)
      ) {
        await checked(
          sb.from('mirror_records').upsert(
            {
              user_id: user.id,
              device_id: metadata.device_id ?? null,
              record_type: 'registration_snapshot',
              record_key: user.id,
              payload: metadata,
              mysql_synced: false,
              updated_at: now
            },
            {
              onConflict:
                'user_id,record_type,record_key'
            }
          )
        );
      }
    }

    if (data.users.length < 1000) {
      return registrations;
    }
  }

  throw new Error(
    'Auth enumeration limit reached; full verification unavailable'
  );
}

async function run() {
  let db = null;
  let heartbeat = null;

  const report = {
    ok: false,
    tables: {},
    account_checks: {},
    errors: [],
    sync_state: 'starting',
    current_stage: 'starting',
    current_table: null,
    scope:
      `${tables.length} public application tables; ` +
      'full JSON plus matching typed columns; ' +
      'Supabase is authoritative'
  };

  const startedAt = new Date().toISOString();

  let connected = false;
  let ownsLock = false;
  let request = null;
  let requestPending = false;
  let lastProgressAt = 0;

  const progress = async (
    stage,
    table = null,
    force = false
  ) => {
    const now = Date.now();

    if (!force && now - lastProgressAt < 10000) {
      return;
    }

    lastProgressAt = now;

    report.sync_state = 'syncing';
    report.current_stage = stage;
    report.current_table = table;
    report.last_progress_at = new Date(now).toISOString();

    await publish({
      mysql_connected: true,
      report: JSON.parse(JSON.stringify(report))
    });
  };

  try {
    db = await createConnection(options);

    const [lock] = await db.execute(
      "SELECT GET_LOCK('pyroguard-local-sync',0) AS acquired"
    );

    if (Number(lock[0]?.acquired) !== 1) {
      throw new Error(
        'Another local worker is already running'
      );
    }

    ownsLock = true;
    connected = true;

    await db.execute(`
      CREATE TABLE IF NOT EXISTS pyroguard_local_source_records (
        source_table VARCHAR(100) NOT NULL,
        source_key VARCHAR(255) NOT NULL,
        payload JSON NOT NULL,
        payload_hash CHAR(64) NOT NULL,
        is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
        synced_at DATETIME(3) NOT NULL,
        PRIMARY KEY(source_table, source_key)
      ) ENGINE=InnoDB
    `);

    // core.mjs archives the exact source JSON in payload_raw. Older MySQL
    // databases were created without that column, which made EVERY row copy
    // fail with "Unknown column 'payload_raw'" so nothing was ever synced.
    const [rawColumn] = await db.execute(
      "SELECT COUNT(*) AS present FROM information_schema.columns " +
      "WHERE table_schema=DATABASE() " +
      "AND table_name='pyroguard_local_source_records' " +
      "AND column_name='payload_raw'"
    );
    if (Number(rawColumn[0]?.present) === 0) {
      await db.execute(
        'ALTER TABLE pyroguard_local_source_records ' +
        'ADD COLUMN payload_raw LONGTEXT NULL AFTER payload'
      );
      console.log('Added missing column pyroguard_local_source_records.payload_raw');
    }

    const syncRow = await checked(
      sb.from('pyroguard_local_sync_status')
        .select(
          'requested_at,acknowledged_at,completed_at,report'
        )
        .eq('worker_id', 'local-pc')
        .maybeSingle()
    );

    request = syncRow?.requested_at ?? null;

    requestPending =
      !!request &&
      (
        !syncRow?.acknowledged_at ||
        request > syncRow.acknowledged_at
      );

    const fullCheck =
      cycleCount++ % FULL_CHECK_EVERY === 0 ||
      requestPending;

    report.full_check = fullCheck;

    const previousReport =
      syncRow?.report &&
      typeof syncRow.report === 'object'
        ? syncRow.report
        : {};

    report.last_verified_at =
      previousReport.last_verified_at ??
      (
        previousReport.ok === true
          ? syncRow?.completed_at ?? null
          : null
      );

    report.sync_state = 'syncing';
    report.current_stage = 'starting';
    report.last_progress_at = startedAt;

    await publish({
      mysql_connected: true,
      started_at: startedAt,
      report
    });

    console.log(
      `${new Date().toISOString()} START: ` +
      `${fullCheck ? 'full verification' : 'incremental sync'}; ` +
      `${tables.length} tables; ` +
      `request ${requestPending ? 'pending' : 'none'}`
    );

    let heartbeatBusy = false;

    heartbeat = setInterval(async () => {
      if (heartbeatBusy) {
        return;
      }

      heartbeatBusy = true;

      try {
        await publish({
          mysql_connected: true
        });
      } catch (error) {
        console.error(
          'Heartbeat publishing failed:',
          error.message
        );
      } finally {
        heartbeatBusy = false;
      }
    }, 20000);

    await progress('preparing_accounts', null, true);

    const registrations = await prepareAccounts();

    await progress('loading_mysql_schema', null, true);

    const [schema] = await db.execute(
      'SELECT TABLE_NAME,COLUMN_NAME,DATA_TYPE,' +
      'IS_NULLABLE,COLUMN_DEFAULT,EXTRA,' +
      'CHARACTER_MAXIMUM_LENGTH,DATETIME_PRECISION ' +
      'FROM information_schema.columns ' +
      'WHERE TABLE_SCHEMA=DATABASE()'
    );

    const accounts = {
      profiles: new Map(),
      account_identities: new Map()
    };

    const ledger = [];
    const pending = [];

    for (const table of tables) {
      const stats = {
        state: 'running',
        rows: 0,
        verified_rows: 0,
        copied_rows: 0,
        archive_only_fields: []
      };

      report.tables[table.source] = stats;

      await progress(
        'verifying_table',
        table.source,
        true
      );

      console.log(
        `${new Date().toISOString()} TABLE START: ${table.source}`
      );

      const columns = schema.filter(
        c => c.TABLE_NAME === table.target
      );

      try {
        if (!columns.length) {
          throw new Error(
            'Missing MySQL table ' + table.target
          );
        }

        const [known] = await db.execute(
          'SELECT source_key,payload_hash ' +
          'FROM pyroguard_local_source_records ' +
          'WHERE source_table=? AND is_deleted=FALSE',
          [table.source]
        );

        const knownHashes = new Map(
          known.map(row => [
            String(row.source_key),
            row.payload_hash
          ])
        );

        // Large append-only tables: incremental cycles read only the recent
        // window (newest MySQL timestamp minus 15 minutes).
        let since = null;
        if (table.since_column && !fullCheck) {
          const [[latest]] = await db.execute(
            `SELECT MAX(${identifier(table.since_column)}) AS latest ` +
            `FROM ${identifier(table.target)}`
          );
          if (latest?.latest) {
            const at = new Date(
              String(latest.latest).replace(' ', 'T') + 'Z'
            );
            if (!Number.isNaN(at.getTime())) {
              since = {
                column: table.since_column,
                value: new Date(at.getTime() - 15 * 60 * 1000).toISOString()
              };
            }
          }
        }
        for await (const batch of pages(sb, table, 500, since)) {
          for (const row of batch) {
            if (stop) {
              throw new Error(
                'Worker stopped; cycle incomplete'
              );
            }

            stats.rows++;

            await progress(
              'verifying_table',
              table.source
            );

            if (
              alreadyMirrored(
                knownHashes,
                row,
                table,
                fullCheck
              )
            ) {
              stats.verified_rows++;

              if (accounts[table.source]) {
                accounts[table.source].set(
                  row.user_id,
                  row
                );
              }

              if (
                table.source === 'dual_record_ledger' &&
                row.source === 'supabase_table_trigger' &&
                row.operation === 'DELETE' &&
                row.mysql_synced !== true
              ) {
                ledger.push(row);
              }

              if (
                Object.hasOwn(row, 'mysql_synced') &&
                row.mysql_synced !== true
              ) {
                pending.push({ table, row });
              }

              continue;
            }

            const result = await mirrorRow(
              db,
              table,
              row,
              columns
            );

            const fresh = await checked(
              sb.from(table.source)
                .select('*')
                .eq(table.key, row[table.key])
                .maybeSingle()
            );

            if (
              !fresh ||
              digest(business(fresh)) !== result.hash
            ) {
              // Live rows (device_current_state every 5 s, heartbeats, PTZ)
              // change constantly. The copied version is still valid and the
              // newer one is copied next cycle. Before, this was an error
              // that marked the whole table pending and blocked every
              // acknowledgment back to Supabase.
              stats.changed_during_copy = (stats.changed_during_copy ?? 0) + 1;
              continue;
            }

            stats.copied_rows++;

            stats.verified_rows++;

            stats.archive_only_fields = [
              ...new Set([
                ...stats.archive_only_fields,
                ...result.archiveOnlyFields
              ])
            ];

            if (accounts[table.source]) {
              accounts[table.source].set(
                row.user_id,
                row
              );
            }

            if (
              table.source === 'dual_record_ledger' &&
              row.source === 'supabase_table_trigger' &&
              row.operation === 'DELETE' &&
              row.mysql_synced !== true
            ) {
              ledger.push(row);
            }

            if (
              Object.hasOwn(row, 'mysql_synced') &&
              row.mysql_synced !== true
            ) {
              pending.push({ table, row });
            }
          }
        }

        stats.state = 'verified';
      } catch (error) {
        stats.state = 'pending';

        report.errors.push({
          table: table.source,
          error: error.message
        });

        console.error(
          `${new Date().toISOString()} TABLE ERROR ` +
          `${table.source}: ${error.message}`
        );
      }

      console.log(
        `${new Date().toISOString()} TABLE ` +
        `${stats.state.toUpperCase()} ${table.source}: ` +
        `${stats.verified_rows}/${stats.rows} checked; ` +
        `${stats.copied_rows} copied`
      );

      await progress(
        'table_complete',
        table.source,
        true
      );
    }

    await progress(
      'processing_deletions',
      null,
      true
    );

    for (const event of ledger) {
      const table = tables.find(
        t => t.source === event.record_type
      );

      const value = event.payload?.[table?.key];

      if (!table || value == null) {
        report.errors.push({
          table: 'deletions',
          error:
            'Delete event lacks a supported source key'
        });
        continue;
      }

      try {
        const current = await checked(
          sb.from(table.source)
            .select(table.key)
            .eq(table.key, value)
            .maybeSingle()
        );

        if (current) {
          continue;
        }

        const [owned] = await db.execute(
          'SELECT payload ' +
          'FROM pyroguard_local_source_records ' +
          'WHERE source_table=? AND source_key=?',
          [
            table.source,
            String(value)
          ]
        );

        await db.beginTransaction();

        try {
          if (owned.length) {
            await db.execute(
              `DELETE FROM ${identifier(table.target)} ` +
              `WHERE ${identifier(table.key)}=?`,
              [value]
            );
          }

          await db.execute(
            `INSERT INTO pyroguard_local_source_records
             (
               source_table,
               source_key,
               payload,
               payload_hash,
               is_deleted,
               synced_at
             )
             VALUES (?,?,?,?,TRUE,UTC_TIMESTAMP(3))
             ON DUPLICATE KEY UPDATE
               payload=VALUES(payload),
               payload_hash=VALUES(payload_hash),
               is_deleted=TRUE,
               synced_at=VALUES(synced_at)`,
            [
              table.source,
              String(value),
              stable(event.payload),
              digest(event.payload)
            ]
          );

          await db.commit();
        } catch (error) {
          await db.rollback();
          throw error;
        }
      } catch (error) {
        report.errors.push({
          table: 'deletions',
          error: error.message
        });
      }
    }

    // Every row in `pending` was individually copied and read back from
    // MySQL, so it is acknowledged even if an unrelated table failed.
    // (Before, one failing table stopped ALL acknowledgments.)
    {
      await progress(
        'acknowledging_records',
        null,
        true
      );

      for (const { table, row } of pending) {
        let update = sb.from(table.source)
          .update({
            mysql_synced: true,
            mysql_synced_at:
              new Date().toISOString(),
            last_sync_error: null
          })
          .eq(table.key, row[table.key])
          .eq('mysql_synced', false);

        if (row.updated_at != null) {
          update = update.eq(
            'updated_at',
            row.updated_at
          );
        } else if (row.payload != null) {
          update = update.eq(
            'payload',
            JSON.stringify(row.payload)
          );
        }

        try {
          await checked(update);
        } catch (error) {
          report.errors.push({
            table: table.source,
            error: 'Acknowledgment failed: ' + error.message
          });
        }
      }
    }

    for (
      const [id, registration]
      of registrations
    ) {
      const profile =
        accounts.profiles.get(id);

      const identity =
        accounts.account_identities.get(id);

      if (
        profile &&
        identity &&
        report.tables.profiles?.state === 'verified' &&
        report.tables.account_identities?.state ===
          'verified' &&
        report.tables.mirror_records?.state === 'verified'
      ) {
        report.account_checks[id] = digest({
          profile: business(profile),
          identity: business(identity),
          registration
        });
      }
    }

    report.ok =
      report.errors.length === 0 &&
      tables.every(
        table =>
          report.tables[table.source]?.state ===
          'verified'
      );

    await db.execute(
      'SELECT 1 AS final_connection_check'
    );

    const completedAt =
      new Date().toISOString();

    report.sync_state =
      report.ok ? 'verified' : 'incomplete';

    report.current_stage = 'completed';
    report.current_table = null;
    report.last_progress_at = completedAt;

    if (report.ok) {
      report.last_verified_at = completedAt;
    }

    await publish({
      mysql_connected: true,
      completed_at: completedAt,
      report,
      ...(
        requestPending && report.ok
          ? {
              acknowledged_at: request
            }
          : {}
      )
    });

    const copied = Object.values(
      report.tables
    ).reduce(
      (total, table) =>
        total + (table.copied_rows ?? 0),
      0
    );

    const verifiedTables =
      Object.values(report.tables).filter(
        table => table.state === 'verified'
      ).length;

    console.log(
      `${new Date().toISOString()} ` +
      `${report.ok ? 'VERIFIED' : 'PENDING'}: ` +
      `${verifiedTables}/${tables.length} tables; ` +
      `${copied} rows copied` +
      `${fullCheck ? ' (full check)' : ''}; ` +
      `${report.errors.length} errors`
    );

    for (const error of report.errors) {
      console.error(
        `${error.table}: ${error.error}`
      );
    }
  } catch (error) {
    if (
      [
        'ECONNREFUSED',
        'ECONNRESET',
        'ETIMEDOUT',
        'PROTOCOL_CONNECTION_LOST'
      ].includes(error.code)
    ) {
      connected = false;
    }

    report.errors.push({
      table: 'worker',
      error: error.message
    });

    report.sync_state = 'failed';
    report.current_stage = 'failed';
    report.last_progress_at =
      new Date().toISOString();

    try {
      if (db && !ownsLock) {
        throw new Error(
          'Worker lock not owned'
        );
      }

      await publish({
        mysql_connected: connected,
        report
      });
    } catch {
      console.error(
        'Cannot publish synchronization status.'
      );
    }

    console.error(
      'Cycle failed:',
      error.code ?? error.message
    );
  } finally {
    if (heartbeat) {
      clearInterval(heartbeat);
    }

    await db?.end().catch(() => {});
  }

  return report.ok;
}

do {
  const ok = await run();

  if (process.argv.includes('--once')) {
    process.exitCode = ok ? 0 : 1;
    break;
  }

  for (
    let seconds = 0;
    seconds < interval && !stop;
    seconds++
  ) {
    await new Promise(resolve =>
      setTimeout(resolve, 1000)
    );
  }
} while (!stop);
