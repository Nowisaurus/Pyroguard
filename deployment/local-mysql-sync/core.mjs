import {createHash} from 'node:crypto';

export const syncFields = new Set(['mysql_synced','mysql_synced_at','last_sync_error','updated_at']);
export function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])]));
  return value;
}
export const stable = value => JSON.stringify(canonical(value));
export const digest = value => createHash('sha256').update(stable(value)).digest('hex');
export const business = row => Object.fromEntries(Object.entries(row).filter(([k])=>!syncFields.has(k)));
export function identifier(name) {
  if (!/^[a-z_][a-z0-9_]*$/i.test(name)) throw new Error('Invalid SQL identifier');
  return '`'+name+'`';
}
export function convert(value,column) {
  if (value===undefined) throw new Error('Missing source field '+column.COLUMN_NAME);
  if (value===null) {
    if(column.IS_NULLABLE==='NO') throw new Error('Source null violates MySQL column '+column.COLUMN_NAME);
    return null;
  }
  const type=column.DATA_TYPE.toLowerCase();
  if(type==='json') return stable(value);
  if(['datetime','timestamp','date'].includes(type)) {
    const date=new Date(value);
    if(Number.isNaN(date.getTime())) throw new Error('Invalid source date '+column.COLUMN_NAME);
    return type==='date'?date.toISOString().slice(0,10):date.toISOString().replace('T',' ').replace('Z','');
  }
  if(['tinyint','smallint','mediumint','int','bigint','decimal','float','double'].includes(type)) {
    if(typeof value==='boolean')return value?1:0;
    if(!/^-?\d+(\.\d+)?$/.test(String(value)))throw new Error('Invalid numeric source '+column.COLUMN_NAME);
    if(type==='bigint' && typeof value==='number' && !Number.isSafeInteger(value))throw new Error('Unsafe bigint source; precision cannot be verified');
    return String(value);
  }
  if(typeof value==='object')throw new Error('Object source requires JSON column '+column.COLUMN_NAME);
  if(column.CHARACTER_MAXIMUM_LENGTH && String(value).length>Number(column.CHARACTER_MAXIMUM_LENGTH))throw new Error('Source too long for '+column.COLUMN_NAME);
  return value;
}
export function equalColumn(actual,expected,column) {
  if(expected===null)return actual===null;
  const type=column.DATA_TYPE.toLowerCase();
  if(type==='json') {
    try{return stable(typeof actual==='string'?JSON.parse(actual):actual)===stable(JSON.parse(expected));}catch{return false;}
  }
  if(['tinyint','smallint','mediumint','int','bigint','decimal','float','double'].includes(type)) {
    // Decimal normalization is textual: never round through Number.
    const norm=v=>String(v).replace(/^(-?)0+(?=\d)/,'$1').replace(/(\.\d*?)0+$/,'$1').replace(/\.$/,'').replace(/^-0$/,'0');
    return norm(actual)===norm(expected);
  }
  if(['datetime','timestamp'].includes(type)) {
    const normalize=v=>String(v).replace('T',' ').replace(/Z$/,'').replace(/(\.\d*?)0+$/,'$1').replace(/\.$/,'');
    const precision=Number(column.DATETIME_PRECISION??0);
    const truncated=precision?expected.slice(0,20+precision):expected.slice(0,19);
    return normalize(actual)===normalize(truncated);
  }
  return String(actual)===String(expected);
}

export async function mirrorRow(db,table,row,columns) {
  const key=String(row[table.key]??'');
  if(!key)throw new Error('Stable source key is missing for '+table.source);
  const fields=columns.filter(c=>(Object.hasOwn(row,c.COLUMN_NAME) || c.IS_NULLABLE==='YES') && !/GENERATED/i.test(c.EXTRA??''));
  if(!fields.some(c=>c.COLUMN_NAME===table.key))throw new Error('MySQL source-key column missing: '+table.source);
  for(const c of columns) {
    if(!Object.hasOwn(row,c.COLUMN_NAME) && c.IS_NULLABLE==='NO' && !/auto_increment|GENERATED/i.test(c.EXTRA??''))throw new Error('Required MySQL column lacks source value: '+c.COLUMN_NAME);
  }
  // Unknown target-only values stay NULL; never let an old DEFAULT invent a
  // sensor reading, identity or status. Required unknown fields fail closed.
  const values=fields.map(c=>convert(Object.hasOwn(row,c.COLUMN_NAME)?row[c.COLUMN_NAME]:null,c));
  const names=fields.map(c=>identifier(c.COLUMN_NAME));
  const payload=stable(row);
  await db.beginTransaction();
  try {
    await db.execute(`INSERT INTO ${identifier(table.target)} (${names.join(',')}) VALUES (${values.map(()=>'?').join(',')}) ON DUPLICATE KEY UPDATE ${names.map(n=>`${n}=VALUES(${n})`).join(',')}`,values);
    const [saved]=await db.execute(`SELECT ${names.join(',')} FROM ${identifier(table.target)} WHERE ${identifier(table.key)}=?`,[row[table.key]]);
    if(saved.length!==1 || !fields.every((c,i)=>equalColumn(saved[0][c.COLUMN_NAME],values[i],c)))throw new Error('MySQL typed read-back mismatch: '+table.source);
    await db.execute(`INSERT INTO pyroguard_local_source_records (source_table,source_key,payload,payload_hash,is_deleted,synced_at) VALUES (?,?,?,?,FALSE,UTC_TIMESTAMP(3)) ON DUPLICATE KEY UPDATE payload=VALUES(payload),payload_hash=VALUES(payload_hash),is_deleted=FALSE,synced_at=VALUES(synced_at)`,[table.source,key,payload,digest(row)]);
    const [archive]=await db.execute('SELECT payload,payload_hash FROM pyroguard_local_source_records WHERE source_table=? AND source_key=?',[table.source,key]);
    const actual=typeof archive[0]?.payload==='string'?JSON.parse(archive[0].payload):archive[0]?.payload;
    if(stable(actual)!==payload || archive[0]?.payload_hash!==digest(row))throw new Error('MySQL complete payload read-back mismatch');
    await db.commit();
    return {key,hash:digest(business(row)),archiveOnlyFields:Object.keys(row).filter(k=>!fields.some(c=>c.COLUMN_NAME===k))};
  }catch(error){await db.rollback();throw error;}
}

export async function* pages(sb,table,pageSize=500) {
  const {data:top,error:topError}=await sb.from(table.source).select(table.key).order(table.key,{ascending:false}).limit(1);
  if(topError)throw new Error('Cannot read source table '+table.source+' ('+(topError.code??'query')+')');
  if(!top?.length)return;
  const upper=top[0][table.key];
  let last=null;
  while(true) {
    let query=sb.from(table.source).select('*').order(table.key,{ascending:true}).lte(table.key,upper).limit(pageSize);
    if(last!==null)query=query.gt(table.key,last);
    const {data,error}=await query;
    if(error)throw new Error('Cannot read source table '+table.source+' ('+(error.code??'query')+')');
    if(!data?.length)return;
    yield data;
    const next=data.at(-1)[table.key];
    if(next===last || next==null)throw new Error('Pagination did not advance');
    last=next;
    // Continue until an empty page, even if the API applies a smaller limit.
  }
}
