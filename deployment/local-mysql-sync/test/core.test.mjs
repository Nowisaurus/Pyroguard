import test from 'node:test';
import assert from 'node:assert/strict';

import {
  mirrorRow,
  stable,
  digest,
  business,
  equalColumn,
  convert,
  pages,
} from '../core.mjs';

const columns = [
  {
    COLUMN_NAME: 'id',
    DATA_TYPE: 'bigint',
    IS_NULLABLE: 'NO',
    EXTRA: 'auto_increment',
  },
  {
    COLUMN_NAME: 'temperature',
    DATA_TYPE: 'decimal',
    IS_NULLABLE: 'YES',
  },
  {
    COLUMN_NAME: 'flame_detected',
    DATA_TYPE: 'tinyint',
    IS_NULLABLE: 'YES',
  },
  {
    COLUMN_NAME: 'payload',
    DATA_TYPE: 'json',
    IS_NULLABLE: 'YES',
  },
];

const table = {
  source: 'sensor_readings',
  target: 'pyroguard_sensor_readings',
  key: 'id',
};

const row = {
  id: 123,
  temperature: null,
  flame_detected: null,
  payload: {
    actual: 'submitted',
    values: [1, 2],
  },
  additional_actual_field: 'kept',
};

function fakeDb({
  fail = false,
  corrupt = false,
  corruptArchive = false,
  corruptArchiveHash = false,
} = {}) {
  let typed = null;
  let archive = null;

  const calls = [];

  return {
    calls,

    async beginTransaction() {
      calls.push('begin');
    },

    async commit() {
      calls.push('commit');
    },

    async rollback() {
      calls.push('rollback');
    },

    async execute(sql, args = []) {
      const statement = sql.trim().replace(/\s+/g, ' ');

      // Simulate the typed MySQL table INSERT.
      if (/^INSERT INTO `[^`]+`/i.test(statement)) {
        if (fail) {
          throw new Error('write failed');
        }

        const columnSection = statement.slice(
          statement.indexOf('(') + 1,
          statement.indexOf(')')
        );

        const names = [
          ...columnSection.matchAll(/`([^`]+)`/g),
        ].map((match) => match[1]);

        typed = Object.fromEntries(
          names.map((name, index) => [
            name,
            args[index],
          ])
        );

        return [{ affectedRows: 1 }];
      }

      // Simulate the typed MySQL read-back.
      // This also recognizes CAST(json AS CHAR).
      if (
        /^SELECT /i.test(statement) &&
        /FROM `pyroguard_sensor_readings`/i.test(statement)
      ) {
        if (!typed) {
          return [[]];
        }

        return [[{
          ...typed,
          temperature: corrupt
            ? '999'
            : typed.temperature,
        }]];
      }

      // Simulate the archive INSERT with payload_raw.
      if (
        /^INSERT INTO pyroguard_local_source_records/i.test(
          statement
        )
      ) {
        assert.equal(
          args.length,
          5,
          'Archive INSERT must provide five parameters'
        );

        assert.equal(args[0], table.source);
        assert.equal(args[1], String(row.id));

        const [
          sourceTable,
          sourceKey,
          payload,
          payloadRaw,
          payloadHash,
        ] = args;

        assert.equal(
          payloadRaw,
          payload,
          'Raw archive must preserve the serialized source'
        );

        archive = {
          source_table: sourceTable,
          source_key: String(sourceKey),
          payload,
          payload_raw: corruptArchive
            ? `${payloadRaw} `
            : payloadRaw,
          payload_hash: corruptArchiveHash
            ? '0'.repeat(64)
            : payloadHash,
        };

        return [{ affectedRows: 1 }];
      }

      // Simulate the exact source archive read-back.
      if (
        /^SELECT payload_raw, payload_hash FROM pyroguard_local_source_records/i.test(
          statement
        )
      ) {
        if (!archive) {
          return [[]];
        }

        if (
          String(args[0]) !== archive.source_table ||
          String(args[1]) !== archive.source_key
        ) {
          return [[]];
        }

        return [[{
          payload_raw: archive.payload_raw,
          payload_hash: archive.payload_hash,
        }]];
      }

      throw new Error(`Unexpected SQL: ${statement}`);
    },
  };
}

test(
  'typed and complete JSON read-back preserve null measurements and extra source fields',
  async () => {
    const db = fakeDb();

    const result = await mirrorRow(
      db,
      table,
      row,
      columns
    );

    assert.deepEqual(
      db.calls,
      ['begin', 'commit']
    );

    assert.deepEqual(
      result.archiveOnlyFields,
      ['additional_actual_field']
    );

    assert.equal(
      result.hash,
      digest(business(row))
    );
  }
);

test(
  'failed write rolls back and cannot be reported verified',
  async () => {
    const db = fakeDb({
      fail: true,
    });

    await assert.rejects(
      mirrorRow(db, table, row, columns),
      /write failed/
    );

    assert.deepEqual(
      db.calls,
      ['begin', 'rollback']
    );
  }
);

test(
  'unknown target-only sensor fields do not inherit fake defaults',
  async () => {
    const db = fakeDb();

    const missing = {
      COLUMN_NAME: 'unknown_smoke_status',
      DATA_TYPE: 'text',
      IS_NULLABLE: 'YES',
      COLUMN_DEFAULT: 'SAFE',
    };

    await mirrorRow(
      db,
      table,
      row,
      [...columns, missing]
    );

    assert.deepEqual(
      db.calls,
      ['begin', 'commit']
    );

    await assert.rejects(
      mirrorRow(
        fakeDb(),
        table,
        row,
        [
          ...columns,
          {
            ...missing,
            IS_NULLABLE: 'NO',
          },
        ]
      ),
      /lacks source value/
    );
  }
);

test(
  'read-back mismatch rolls back',
  async () => {
    const db = fakeDb({
      corrupt: true,
    });

    await assert.rejects(
      mirrorRow(db, table, row, columns),
      /read-back mismatch/
    );

    assert.deepEqual(
      db.calls,
      ['begin', 'rollback']
    );
  }
);

test(
  'decimal comparison preserves precision; zero and false do not replace null',
  () => {
    const decimal = {
      DATA_TYPE: 'decimal',
    };

    assert.equal(
      equalColumn(
        '123456789012345678.1200',
        '123456789012345678.12',
        decimal
      ),
      true
    );

    assert.equal(
      equalColumn(
        '123456789012345679.12',
        '123456789012345678.12',
        decimal
      ),
      false
    );

    assert.equal(
      convert(null, {
        COLUMN_NAME: 'temperature',
        DATA_TYPE: 'decimal',
        IS_NULLABLE: 'YES',
      }),
      null
    );

    assert.equal(
      convert(false, {
        DATA_TYPE: 'tinyint',
      }),
      0
    );

    assert.throws(
      () =>
        convert(
          9007199254740992,
          {
            DATA_TYPE: 'bigint',
          }
        ),
      /Unsafe bigint/
    );
  }
);

test(
  'business hash ignores sync bookkeeping but detects actual source edits',
  () => {
    assert.equal(
      digest(
        business({
          ...row,
          mysql_synced: false,
          updated_at: 'old',
        })
      ),
      digest(
        business({
          ...row,
          mysql_synced: true,
          updated_at: 'new',
        })
      )
    );

    assert.notEqual(
      digest(business(row)),
      digest(
        business({
          ...row,
          temperature: 31,
        })
      )
    );

    assert.equal(
      stable({
        b: 2,
        a: 1,
      }),
      stable({
        a: 1,
        b: 2,
      })
    );
  }
);

test(
  'keyset pagination handles an API cap and defers inserts beyond the high-water key',
  async () => {
    const rows = [
      { id: 1 },
      { id: 2 },
      { id: 3 },
      { id: 4 },
    ];

    let first = true;

    const sb = {
      from: () => {
        let descending = false;
        let last = -1;
        let upper = Infinity;

        const query = {
          select: () => query,

          order: (key, options) => {
            descending = !options.ascending;
            return query;
          },

          limit: () => query,

          lte: (key, value) => {
            upper = value;
            return query;
          },

          gt: (key, value) => {
            last = value;
            return query;
          },

          then: (resolve, reject) => {
            const result = descending
              ? [rows.at(-1)]
              : rows
                  .filter(
                    (item) =>
                      item.id > last &&
                      item.id <= upper
                  )
                  .slice(0, 2);

            if (!descending && first) {
              first = false;
              rows.push({ id: 5 });
            }

            return Promise.resolve({
              data: result,
              error: null,
            }).then(resolve, reject);
          },
        };

        return query;
      },
    };

    const copied = [];

    for await (const batch of pages(
      sb,
      table,
      500
    )) {
      copied.push(...batch);
    }

    assert.deepEqual(
      copied.map((item) => item.id),
      [1, 2, 3, 4]
    );
  }
);

// Additional integrity tests for the new raw archive.

test(
  'corrupted raw archive rolls back',
  async () => {
    const db = fakeDb({
      corruptArchive: true,
    });

    await assert.rejects(
      mirrorRow(db, table, row, columns),
      /raw payload read-back mismatch/
    );

    assert.deepEqual(
      db.calls,
      ['begin', 'rollback']
    );
  }
);

test(
  'corrupted archive hash rolls back',
  async () => {
    const db = fakeDb({
      corruptArchiveHash: true,
    });

    await assert.rejects(
      mirrorRow(db, table, row, columns),
      /archive hash mismatch/
    );

    assert.deepEqual(
      db.calls,
      ['begin', 'rollback']
    );
  }
);

test(
  'longitude precision compatibility does not weaken exact raw archive verification',
  async () => {
    const jsonColumn = {
      DATA_TYPE: 'json',
    };

    const source = {
      home_longitude: 120.123456789123,
      status: 'safe',
    };

    const mysql = {
      home_longitude: 120.123456789124,
      status: 'safe',
    };

    assert.equal(
      equalColumn(
        JSON.stringify(mysql),
        JSON.stringify(source),
        jsonColumn
      ),
      true
    );

    const alteredStatus = {
      ...mysql,
      status: 'warning',
    };

    assert.equal(
      equalColumn(
        JSON.stringify(alteredStatus),
        JSON.stringify(source),
        jsonColumn
      ),
      false
    );

    assert.notEqual(
      stable(mysql),
      stable(source)
    );
  }
);

test('geographic latitude JSON may differ by less than 1e-9 without changing meaning', () => {
  const json = { COLUMN_NAME: 'payload', DATA_TYPE: 'json', IS_NULLABLE: 'YES' };
  assert.equal(equalColumn('{"latitude":14.5995000001}', { latitude:14.5995 }, json), true);
  assert.equal(equalColumn('{"latitude":14.6}', { latitude:14.5995 }, json), false);
  assert.equal(equalColumn('{"temperature":14.5995000001}', { temperature:14.5995 }, json), false);
  assert.equal(equalColumn('{"latitude":95.0000000001}', { latitude:95 }, json), false);
  assert.equal(equalColumn('{"nested":{"home_latitude":14.5995000001}}', { nested:{home_latitude:14.5995} }, json), true);
});

import { pages as pagesFn, alreadyMirrored as mirroredFn, digest as digestFn } from '../core.mjs';

test('append-only tables are compared by hash even during a full check', () => {
  const row = { id: 'a', v: 1 };
  const known = new Map([['a', digestFn(row)]]);
  assert.equal(mirroredFn(known, row, { key: 'id', append_only: true }, true), true);
  assert.equal(mirroredFn(known, row, { key: 'id' }, true), false);
});

test('pages applies the incremental since-window to every query', async () => {
  const calls = [];
  const rows = [{ id: '1' }, { id: '2' }];
  const query = () => {
    const q = { filters: [] };
    q.select = () => q;
    q.gte = (c, v) => { q.filters.push(['gte', c, v]); return q; };
    q.lte = () => q; q.gt = (c, v) => { q.filters.push(['gt', c, v]); return q; };
    q.order = () => q;
    q.limit = (n) => { q.n = n; return q; };
    q.then = (resolve) => { calls.push(q.filters); resolve({ data: q.n === 1 ? [rows[1]] : (q.filters.some(f => f[0] === 'gt') ? [] : rows), error: null }); };
    return q;
  };
  const sb = { from: () => query() };
  const seen = [];
  for await (const batch of pagesFn(sb, { source: 't', key: 'id' }, 500, { column: 'received_at', value: '2026-11-04T00:00:00Z' })) seen.push(...batch);
  assert.equal(seen.length, 2);
  assert.ok(calls.every(f => f.some(x => x[0] === 'gte' && x[1] === 'received_at')));
});
