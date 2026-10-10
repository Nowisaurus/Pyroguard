import test from 'node:test';
import assert from 'node:assert/strict';
import {mirrorRow,stable,digest,business,equalColumn,convert,pages} from '../core.mjs';
const columns=[
 {COLUMN_NAME:'id',DATA_TYPE:'bigint',IS_NULLABLE:'NO',EXTRA:'auto_increment'},
 {COLUMN_NAME:'temperature',DATA_TYPE:'decimal',IS_NULLABLE:'YES'},
 {COLUMN_NAME:'flame_detected',DATA_TYPE:'tinyint',IS_NULLABLE:'YES'},
 {COLUMN_NAME:'payload',DATA_TYPE:'json',IS_NULLABLE:'YES'},
];
function fakeDb({fail=false,corrupt=false}={}) {
 let typed,archive;
 const calls=[];
 return {calls,beginTransaction:async()=>calls.push('begin'),commit:async()=>calls.push('commit'),rollback:async()=>calls.push('rollback'),
 execute:async(sql,args)=>{
   if(sql.startsWith('INSERT INTO `')){if(fail)throw new Error('write failed');const names=[...sql.slice(sql.indexOf('('),sql.indexOf(')')).matchAll(/`([^`]+)`/g)].map(m=>m[1]);typed=Object.fromEntries(names.map((n,i)=>[n,args[i]]));return [{}];}
   if(sql.startsWith('SELECT `'))return [[{...typed,temperature:corrupt?'999':typed.temperature}]];
   if(sql.startsWith('INSERT INTO pyroguard_local_source_records')){archive={payload:args[2],payload_hash:args[3]};return [{}];}
   if(sql.startsWith('SELECT payload'))return [[archive]];
   throw new Error('Unexpected SQL');
 }};
}
const table={source:'sensor_readings',target:'pyroguard_sensor_readings',key:'id'};
const row={id:123,temperature:null,flame_detected:null,payload:{actual:'submitted',values:[1,2]},additional_actual_field:'kept'};
test('typed and complete JSON read-back preserve null measurements and extra source fields',async()=>{
 const db=fakeDb();const result=await mirrorRow(db,table,row,columns);
 assert.deepEqual(db.calls,['begin','commit']);assert.deepEqual(result.archiveOnlyFields,['additional_actual_field']);assert.equal(result.hash,digest(business(row)));
});
test('failed write rolls back and cannot be reported verified',async()=>{
 const db=fakeDb({fail:true});await assert.rejects(mirrorRow(db,table,row,columns));assert.deepEqual(db.calls,['begin','rollback']);
});
test('unknown target-only sensor fields do not inherit fake defaults',async()=>{
 const db=fakeDb();const missing={COLUMN_NAME:'unknown_smoke_status',DATA_TYPE:'text',IS_NULLABLE:'YES',COLUMN_DEFAULT:'SAFE'};
 await mirrorRow(db,table,row,[...columns,missing]);assert.deepEqual(db.calls,['begin','commit']);
 await assert.rejects(mirrorRow(fakeDb(),table,row,[...columns,{...missing,IS_NULLABLE:'NO'}]),/lacks source value/);
});
test('read-back mismatch rolls back',async()=>{
 const db=fakeDb({corrupt:true});await assert.rejects(mirrorRow(db,table,row,columns),/read-back mismatch/);assert.deepEqual(db.calls,['begin','rollback']);
});
test('decimal comparison preserves precision; zero and false do not replace null',()=>{
 const decimal={DATA_TYPE:'decimal'};assert.equal(equalColumn('123456789012345678.1200','123456789012345678.12',decimal),true);
 assert.equal(equalColumn('123456789012345679.12','123456789012345678.12',decimal),false);
 assert.equal(convert(null,{COLUMN_NAME:'temperature',DATA_TYPE:'decimal',IS_NULLABLE:'YES'}),null);
 assert.equal(convert(false,{DATA_TYPE:'tinyint'}),0);
 assert.throws(()=>convert(9007199254740992,{DATA_TYPE:'bigint'}),/Unsafe bigint/);
});
test('business hash ignores sync bookkeeping but detects actual source edits',()=>{
 assert.equal(digest(business({...row,mysql_synced:false,updated_at:'old'})),digest(business({...row,mysql_synced:true,updated_at:'new'})));
 assert.notEqual(digest(business(row)),digest(business({...row,temperature:31})));
 assert.equal(stable({b:2,a:1}),stable({a:1,b:2}));
});
test('keyset pagination handles an API cap and defers inserts beyond the high-water key',async()=>{
 let rows=[{id:1},{id:2},{id:3},{id:4}];let first=true;
 const sb={from:()=>{let descending=false,last=-1,upper=Infinity,selection='*';const q={select:s=>{selection=s;return q},order:(k,o)=>{descending=!o.ascending;return q},limit:()=>q,lte:(k,v)=>{upper=v;return q},gt:(k,v)=>{last=v;return q},then:resolve=>{
  let result=descending?[rows.at(-1)]:rows.filter(r=>r.id>last&&r.id<=upper).slice(0,2);
  if(!descending&&first){first=false;rows.push({id:5});}
  return Promise.resolve({data:result,error:null}).then(resolve);
 }};return q;}};
 const copied=[];for await(const batch of pages(sb,table,500))copied.push(...batch);
 assert.deepEqual(copied.map(r=>r.id),[1,2,3,4]);
});
