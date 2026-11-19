import { createHash } from 'node:crypto';

export const syncFields = new Set([
  'mysql_synced',
  'mysql_synced_at',
  'last_sync_error',
  'updated_at',
]);

export function canonical(value) {
  if (value instanceof Date) {
    return value.toISOString();
  }

  if (Buffer.isBuffer(value)) {
    return value.toString('utf8');
  }

  if (Array.isArray(value)) {
    return value.map(canonical);
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])])
    );
  }

  return value;
}

export function stable(value) {
  const serialized = JSON.stringify(canonical(value));

  if (serialized === undefined) {
    throw new Error('Cannot serialize undefined value');
  }

  return serialized;
}

export function digest(value) {
  return createHash('sha256')
    .update(stable(value))
    .digest('hex');
}

export function business(row) {
  return Object.fromEntries(
    Object.entries(row).filter(
      ([key]) => !syncFields.has(key)
    )
  );
}

export function identifier(name) {
  if (!/^[a-z_][a-z0-9_]*$/i.test(name)) {
    throw new Error(`Invalid SQL identifier: ${name}`);
  }

  return `\`${name}\``;
}

function dataType(column) {
  return String(column.DATA_TYPE ?? '').toLowerCase();
}

function mysqlPrecision(column) {
  const precision = Number(column.DATETIME_PRECISION ?? 0);

  return Number.isInteger(precision)
    ? Math.max(0, Math.min(6, precision))
    : 0;
}

function normalizeDecimal(value) {
  let text = String(value).trim();

  if (!/^[+-]?\d+(?:\.\d+)?$/.test(text)) {
    return text;
  }

  const negative = text.startsWith('-');

  text = text.replace(/^[+-]/, '');

  const [whole, fraction = ''] = text.split('.');

  const normalizedWhole =
    whole.replace(/^0+(?=\d)/, '') || '0';

  const normalizedFraction =
    fraction.replace(/0+$/, '');

  const normalized = normalizedFraction
    ? `${normalizedWhole}.${normalizedFraction}`
    : normalizedWhole;

  return negative && normalized !== '0'
    ? `-${normalized}`
    : normalized;
}

function normalizeTimestamp(value, precision) {
  if (value instanceof Date) {
    value = value.toISOString();
  }

  const text = String(value)
    .trim()
    .replace('T', ' ')
    .replace(/Z$/, '');

  const match = text.match(
    /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.(\d+))?$/
  );

  if (!match) {
    return text;
  }

  const base = match[1];
  const fraction = match[2] ?? '';

  if (precision === 0) {
    return base;
  }

  return (
    `${base}.` +
    fraction.padEnd(precision, '0').slice(0, precision)
  );
}

function normalizeDate(value) {
  if (value instanceof Date) {
    return value.toISOString().slice(0, 10);
  }

  return String(value).slice(0, 10);
}

function readText(value) {
  return Buffer.isBuffer(value)
    ? value.toString('utf8')
    : value;
}

function parseJsonValue(value) {
  value = readText(value);

  return typeof value === 'string'
    ? JSON.parse(value)
    : value;
}

function jsonType(value) {
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  if (Buffer.isBuffer(value)) return 'buffer';
  if (Array.isArray(value)) return 'array';

  return typeof value;
}

// Tolerance applies only to geographic latitude/longitude
// fields in MySQL's typed JSON representation.
//
// It does not apply to payload_raw or SHA-256
// verification, which remain exact.

const COORDINATE_TOLERANCE = 1e-9;

const COORDINATE_FIELDS = new Set([
  'latitude',
  'home_latitude',
  'longitude',
  'home_longitude',
]);

function coordinateBounds(path) {
  if (!Array.isArray(path) || path.length === 0) {
    return null;
  }

  const field = path[path.length - 1];
  if (field === 'latitude' || field === 'home_latitude') {
    return 90;
  }
  return COORDINATE_FIELDS.has(field) ? 180 : null;
}

function numbersEquivalent(actual, expected, path) {
  if (
    typeof actual !== 'number' ||
    typeof expected !== 'number'
  ) {
    return false;
  }

  if (Object.is(actual, expected)) {
    return true;
  }

  if (
    !Number.isFinite(actual) ||
    !Number.isFinite(expected)
  ) {
    return false;
  }

  const bound = coordinateBounds(path);
  if (bound === null) {
    return false;
  }

  if (
    actual < -bound ||
    actual > bound ||
    expected < -bound ||
    expected > bound
  ) {
    return false;
  }

  return (
    Math.abs(actual - expected) <=
    COORDINATE_TOLERANCE
  );
}

function compareJsonValues(
  actual,
  expected,
  path = [],
  allowLongitudeTolerance = false
) {
  if (Object.is(actual, expected)) {
    return true;
  }

  if (
    typeof actual === 'number' &&
    typeof expected === 'number'
  ) {
    return (
      allowLongitudeTolerance &&
      numbersEquivalent(actual, expected, path)
    );
  }

  if (actual === null || expected === null) {
    return actual === expected;
  }

  if (
    Array.isArray(actual) ||
    Array.isArray(expected)
  ) {
    if (
      !Array.isArray(actual) ||
      !Array.isArray(expected) ||
      actual.length !== expected.length
    ) {
      return false;
    }

    return actual.every(
      (item, index) =>
        compareJsonValues(
          item,
          expected[index],
          [...path, index],
          allowLongitudeTolerance
        )
    );
  }

  if (
    actual &&
    expected &&
    typeof actual === 'object' &&
    typeof expected === 'object'
  ) {
    const actualKeys = Object.keys(actual);
    const expectedKeys = Object.keys(expected);

    if (actualKeys.length !== expectedKeys.length) {
      return false;
    }

    for (const key of actualKeys) {
      if (!Object.hasOwn(expected, key)) {
        return false;
      }

      if (
        !compareJsonValues(
          actual[key],
          expected[key],
          [...path, key],
          allowLongitudeTolerance
        )
      ) {
        return false;
      }
    }

    return true;
  }

  return actual === expected;
}

function jsonEquivalent(actual, expected) {
  try {
    return compareJsonValues(
      parseJsonValue(actual),
      parseJsonValue(expected),
      [],
      true
    );
  } catch {
    return false;
  }
}

function describeJson(value) {
  try {
    const parsed = parseJsonValue(value);

    return {
      transportType: jsonType(value),
      jsonType: jsonType(parsed),
      hash: digest(parsed),
    };
  } catch (error) {
    return {
      transportType: jsonType(value),
      parseError: error.name,
    };
  }
}

function getJsonDifferences(actual, expected) {
  const differences = [];

  function walk(a, b, path, keys) {
    if (differences.length >= 30) {
      return;
    }

    if (compareJsonValues(a, b, keys, true)) {
      return;
    }

    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) {
        differences.push(`${path} [array length differs]`);
      }

      const length = Math.max(a.length, b.length);

      for (
        let i = 0;
        i < length && differences.length < 30;
        i++
      ) {
        if (i >= a.length) {
          differences.push(
            `${path}[${i}] [missing in MySQL]`
          );
        } else if (i >= b.length) {
          differences.push(
            `${path}[${i}] [extra in MySQL]`
          );
        } else {
          walk(
            a[i],
            b[i],
            `${path}[${i}]`,
            [...keys, i]
          );
        }
      }

      return;
    }

    if (
      a &&
      b &&
      typeof a === 'object' &&
      typeof b === 'object' &&
      !Array.isArray(a) &&
      !Array.isArray(b)
    ) {
      const keysUnion = new Set([
        ...Object.keys(a),
        ...Object.keys(b),
      ]);

      for (const key of keysUnion) {
        if (differences.length >= 30) {
          break;
        }

        const next = `${path}.${key}`;

        if (!Object.hasOwn(a, key)) {
          differences.push(
            `${next} [missing in MySQL]`
          );
        } else if (!Object.hasOwn(b, key)) {
          differences.push(
            `${next} [extra in MySQL]`
          );
        } else {
          walk(
            a[key],
            b[key],
            next,
            [...keys, key]
          );
        }
      }

      return;
    }

    differences.push(
      `${path} [${jsonType(a)} != ${jsonType(b)}]`
    );
  }

  walk(actual, expected, '$', []);

  return differences;
}

export function convert(value, column) {
  const name = column.COLUMN_NAME;
  const type = dataType(column);

  if (value === undefined) {
    throw new Error(`Missing source field: ${name}`);
  }

  if (value === null) {
    if (column.IS_NULLABLE === 'NO') {
      throw new Error(
        `Source null violates MySQL column: ${name}`
      );
    }

    return null;
  }

  if (type === 'json') {
    return stable(value);
  }

  if (
    ['datetime', 'timestamp', 'date'].includes(type)
  ) {
    const date = new Date(value);

    if (Number.isNaN(date.getTime())) {
      throw new Error(`Invalid source date: ${name}`);
    }

    if (type === 'date') {
      return date.toISOString().slice(0, 10);
    }

    return normalizeTimestamp(
      date.toISOString(),
      mysqlPrecision(column)
    );
  }

  if (
    [
      'tinyint',
      'smallint',
      'mediumint',
      'int',
      'bigint',
      'decimal',
      'float',
      'double',
    ].includes(type)
  ) {
    if (typeof value === 'boolean') {
      return value ? 1 : 0;
    }

    if (!/^-?\d+(?:\.\d+)?$/.test(String(value))) {
      throw new Error(`Invalid numeric source: ${name}`);
    }

    if (
      type === 'bigint' &&
      typeof value === 'number' &&
      !Number.isSafeInteger(value)
    ) {
      throw new Error(`Unsafe bigint source: ${name}`);
    }

    return String(value);
  }

  if (typeof value === 'object') {
    throw new Error(
      `Object source requires JSON column: ${name}`
    );
  }

  if (
    column.CHARACTER_MAXIMUM_LENGTH &&
    String(value).length >
      Number(column.CHARACTER_MAXIMUM_LENGTH)
  ) {
    throw new Error(`Source too long for column: ${name}`);
  }

  return value;
}

export function equalColumn(actual, expected, column) {
  if (expected === null) {
    return actual === null;
  }

  if (actual === null || actual === undefined) {
    return false;
  }

  const type = dataType(column);

  if (type === 'json') {
    return jsonEquivalent(actual, expected);
  }

  if (
    [
      'tinyint',
      'smallint',
      'mediumint',
      'int',
      'bigint',
      'decimal',
    ].includes(type)
  ) {
    return (
      normalizeDecimal(actual) ===
      normalizeDecimal(expected)
    );
  }

  if (['float', 'double'].includes(type)) {
    const a = Number(actual);
    const b = Number(expected);

    if (
      !Number.isFinite(a) ||
      !Number.isFinite(b)
    ) {
      return false;
    }

    const tolerance =
      type === 'float' ? 1e-6 : 1e-12;

    return (
      Math.abs(a - b) <=
      tolerance *
      Math.max(1, Math.abs(a), Math.abs(b))
    );
  }

  if (['datetime', 'timestamp'].includes(type)) {
    const precision = mysqlPrecision(column);

    return (
      normalizeTimestamp(actual, precision) ===
      normalizeTimestamp(expected, precision)
    );
  }

  if (type === 'date') {
    return (
      normalizeDate(actual) ===
      normalizeDate(expected)
    );
  }

  if (
    [
      'binary',
      'varbinary',
      'blob',
      'tinyblob',
      'mediumblob',
      'longblob',
    ].includes(type)
  ) {
    const a = Buffer.isBuffer(actual)
      ? actual
      : Buffer.from(actual);

    const b = Buffer.isBuffer(expected)
      ? expected
      : Buffer.from(expected);

    return a.equals(b);
  }

  return String(actual) === String(expected);
}

function buildReadbackSelect(fields) {
  return fields
    .map((column) => {
      const name = identifier(column.COLUMN_NAME);

      if (dataType(column) === 'json') {
        return `CAST(${name} AS CHAR) AS ${name}`;
      }

      return name;
    })
    .join(',');
}

function compareFields(savedRow, fields, values) {
  return fields
    .map((column, index) => ({
      column: column.COLUMN_NAME,
      type: dataType(column),
      actual: savedRow[column.COLUMN_NAME],
      expected: values[index],
      matches: equalColumn(
        savedRow[column.COLUMN_NAME],
        values[index],
        column
      ),
    }))
    .filter((result) => !result.matches);
}

function mismatchMessage(table, mismatches) {
  const lines = [
    `MySQL typed read-back mismatch: ${table.source}`,
  ];

  for (const mismatch of mismatches) {
    lines.push(
      `Column: ${mismatch.column} | Type: ${mismatch.type}`
    );

    if (mismatch.type !== 'json') {
      continue;
    }

    const actualInfo = describeJson(mismatch.actual);
    const expectedInfo = describeJson(mismatch.expected);

    lines.push(
      `  MySQL transport type: ${actualInfo.transportType}`
    );

    lines.push(
      `  MySQL JSON type: ${actualInfo.jsonType ?? 'unavailable'}`
    );

    lines.push(
      `  Source JSON type: ${expectedInfo.jsonType ?? 'unavailable'}`
    );

    lines.push(
      `  MySQL hash: ${actualInfo.hash ?? 'unavailable'}`
    );

    lines.push(
      `  Source hash: ${expectedInfo.hash ?? 'unavailable'}`
    );

    try {
      const differences = getJsonDifferences(
        parseJsonValue(mismatch.actual),
        parseJsonValue(mismatch.expected)
      );

      lines.push('  Differing JSON paths:');

      for (const difference of differences) {
        lines.push(`    ${difference}`);
      }
    } catch (error) {
      lines.push(
        `  JSON inspection error: ${error.name}`
      );
    }
  }

  return lines.join('\n');
}

function validateArchive(
  archive,
  payload,
  expectedHash,
  table
) {
  if (archive.length !== 1) {
    throw new Error(
      `MySQL archive read-back failed: ${table.source}`
    );
  }

  const saved = archive[0];

  const raw = readText(saved.payload_raw);

  const storedHash = String(
    readText(saved.payload_hash) ?? ''
  ).trim();

  if (typeof raw !== 'string') {
    throw new Error(
      `MySQL raw archive is not text: ${table.source}`
    );
  }

  const actualRawHash = createHash('sha256')
    .update(raw)
    .digest('hex');

  if (raw !== payload) {
    throw new Error(
      `MySQL raw payload read-back mismatch: ${table.source}\n` +
      `  Expected raw SHA-256: ${expectedHash}\n` +
      `  Actual raw SHA-256: ${actualRawHash}`
    );
  }

  if (storedHash !== expectedHash) {
    throw new Error(
      `MySQL archive hash mismatch: ${table.source}\n` +
      `  Expected: ${expectedHash}\n` +
      `  Actual: ${storedHash}`
    );
  }

  if (actualRawHash !== expectedHash) {
    throw new Error(
      `MySQL raw archive integrity failed: ${table.source}`
    );
  }

  return true;
}

export async function mirrorRow(db, table, row, columns) {
  const key = String(row[table.key] ?? '');

  if (!key) {
    throw new Error(
      `Stable source key is missing for ${table.source}`
    );
  }

  const fields = columns.filter(
    (column) =>
      (
        Object.hasOwn(row, column.COLUMN_NAME) ||
        column.IS_NULLABLE === 'YES'
      ) &&
      !/GENERATED/i.test(column.EXTRA ?? '')
  );

  if (
    !fields.some(
      (column) => column.COLUMN_NAME === table.key
    )
  ) {
    throw new Error(
      `MySQL source-key column missing: ${table.source}`
    );
  }

  for (const column of columns) {
    if (
      !Object.hasOwn(row, column.COLUMN_NAME) &&
      column.IS_NULLABLE === 'NO' &&
      !/auto_increment|GENERATED/i.test(
        column.EXTRA ?? ''
      )
    ) {
      throw new Error(
        `Required MySQL column lacks source value: ${column.COLUMN_NAME}`
      );
    }
  }

  const values = fields.map((column) =>
    convert(
      Object.hasOwn(row, column.COLUMN_NAME)
        ? row[column.COLUMN_NAME]
        : null,
      column
    )
  );

  const names = fields.map((column) =>
    identifier(column.COLUMN_NAME)
  );

  const payload = stable(row);
  const expectedHash = digest(row);

  const placeholders = values
    .map(() => '?')
    .join(',');

  const updates = names
    .map((name) => `${name}=VALUES(${name})`)
    .join(',');

  await db.beginTransaction();

  try {
    await db.execute(
      `INSERT INTO ${identifier(table.target)}
       (${names.join(',')})
       VALUES (${placeholders})
       ON DUPLICATE KEY UPDATE
       ${updates}`,
      values
    );

    const selectFields = buildReadbackSelect(fields);

    const [saved] = await db.execute(
      `SELECT ${selectFields}
       FROM ${identifier(table.target)}
       WHERE ${identifier(table.key)}=?`,
      [row[table.key]]
    );

    if (saved.length !== 1) {
      throw new Error(
        `MySQL typed read-back failed: ${table.source}\n` +
        `  Expected 1 record; received ${saved.length}`
      );
    }

    const mismatches = compareFields(
      saved[0],
      fields,
      values
    );

    if (mismatches.length > 0) {
      throw new Error(
        mismatchMessage(table, mismatches)
      );
    }

    await db.execute(
      `INSERT INTO pyroguard_local_source_records
       (
         source_table,
         source_key,
         payload,
         payload_raw,
         payload_hash,
         is_deleted,
         synced_at
       )
       VALUES (?, ?, ?, ?, ?, FALSE, UTC_TIMESTAMP(3))
       ON DUPLICATE KEY UPDATE
         payload=VALUES(payload),
         payload_raw=VALUES(payload_raw),
         payload_hash=VALUES(payload_hash),
         is_deleted=FALSE,
         synced_at=VALUES(synced_at)`,
      [
        table.source,
        key,
        payload,
        payload,
        expectedHash,
      ]
    );

    const [archive] = await db.execute(
      `SELECT payload_raw, payload_hash
       FROM pyroguard_local_source_records
       WHERE source_table=?
         AND source_key=?`,
      [
        table.source,
        key,
      ]
    );

    validateArchive(
      archive,
      payload,
      expectedHash,
      table
    );

    await db.commit();

    return {
      key,
      hash: digest(business(row)),
      archiveOnlyFields: Object.keys(row).filter(
        (field) =>
          !fields.some(
            (column) =>
              column.COLUMN_NAME === field
          )
      ),
    };
  } catch (error) {
    try {
      await db.rollback();
    } catch (rollbackError) {
      throw new AggregateError(
        [error, rollbackError],
        `MySQL transaction and rollback failed for ${table.source}`
      );
    }

    throw error;
  }
}

// `since` = { column, value }: only rows with column >= value (incremental
// window for large append-only telemetry tables). Omit for a full scan.
export async function* pages(sb, table, pageSize = 500, since = null) {
  const windowed = (query) =>
    since?.column && since?.value ? query.gte(since.column, since.value) : query;

  const {
    data: top,
    error: topError,
  } = await windowed(sb
    .from(table.source)
    .select(table.key))
    .order(table.key, { ascending: false })
    .limit(1);

  if (topError) {
    throw new Error(
      `Cannot read source table ${table.source} ` +
      `(${topError.code ?? 'query'})`
    );
  }

  if (!top?.length) {
    return;
  }

  const upper = top[0][table.key];

  let last = null;

  while (true) {
    let query = windowed(sb
      .from(table.source)
      .select('*'))
      .order(table.key, { ascending: true })
      .lte(table.key, upper)
      .limit(pageSize);

    if (last !== null) {
      query = query.gt(table.key, last);
    }

    const { data, error } = await query;

    if (error) {
      throw new Error(
        `Cannot read source table ${table.source} ` +
        `(${error.code ?? 'query'})`
      );
    }

    if (!data?.length) {
      return;
    }

    yield data;

    const next = data.at(-1)[table.key];

    if (next === last || next == null) {
      throw new Error('Pagination did not advance');
    }

    last = next;
  }
}

export function alreadyMirrored(
  knownHashes,
  row,
  table,
  fullCheck
) {
  // Append-only telemetry is compared by hash even during a full check;
  // re-copying hundreds of thousands of unchanged readings made a full
  // check run for hours, so the cycle never finished.
  if (fullCheck && !table.append_only) {
    return false;
  }

  const key = String(row[table.key] ?? '');

  return (
    key !== '' &&
    knownHashes.get(key) === digest(row)
  );
}