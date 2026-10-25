import assert from 'node:assert/strict';
import { test } from 'node:test';
import { templateRecords, checkTemplateExportBudget } from '../src/template-panel';
import type { Material } from '../src/types';
const rows = [{code:'30000',location_id:2},{code:'10000',location_id:null},{code:'20000',location_id:1}] as Material[];
test('template selection prints only the selected group, including ungrouped records',()=>{
  assert.deepEqual(templateRecords(rows,'1').map(row=>row.code),['20000']);
  assert.deepEqual(templateRecords(rows,'none').map(row=>row.code),['10000']);
  assert.deepEqual(templateRecords(rows,'all').map(row=>row.code),['10000','20000','30000']);
  assert.deepEqual(templateRecords(rows,'3'),[]);
  assert.deepEqual(rows.map(row=>row.code),['30000','10000','20000']);
});
test('ZIP generation refuses empty groups, over 500 cards and its memory budget without truncation',()=>{
  assert.throws(()=>checkTemplateExportBudget(0,761,916,0),/нет записей/i);
  assert.throws(()=>checkTemplateExportBudget(501,761,916,0),/500/);
  assert.throws(()=>checkTemplateExportBudget(10,12000,3333,0),/256/);
  assert.throws(()=>checkTemplateExportBudget(10,761,916,90*1024**2),/256/);
  assert.doesNotThrow(()=>checkTemplateExportBudget(500,761,916,30*1024**2));
});
