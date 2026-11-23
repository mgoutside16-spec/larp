const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {CardZipWriter, crc32} = require('../card-zip.cjs');

const png = Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(120,0x45)]);
function workspace(t) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cardzip-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  return dir;
}
function entries(zip) {
  const out=[];
  for(let offset=0;offset<zip.length-4;offset++){
    if(zip.readUInt32LE(offset)!==0x02014b50)continue;
    const length=zip.readUInt16LE(offset+28);
    const name=zip.subarray(offset+46,offset+46+length).toString('utf8');
    if(!/^[1-9]\d{4}\.png$/.test(name))continue;
    out.push({
      name,crc:zip.readUInt32LE(offset+16),size:zip.readUInt32LE(offset+24),
      offset:zip.readUInt32LE(offset+42),
    });
    offset+=45+length;
  }
  return out;
}
test('one-by-one printing creates valid STORED ZIP entries without holding archive in JS',t=>{
  const dir=workspace(t),target=path.join(dir,'карточки.zip');
  const writer=new CardZipWriter(target);
  for(let n=0;n<500;n++)writer.add(String(10000+n)+'.png',png);
  assert.equal(writer.finish(),target);
  const zip=fs.readFileSync(target);
  const files=entries(zip);
  assert.equal(files.length,500);
  assert.equal(zip.readUInt32LE(zip.length-22),0x06054b50);
  assert.equal(zip.readUInt16LE(zip.length-22+10),500);
  for(const item of files){
    assert.equal(item.crc,crc32(png));
    assert.equal(item.size,png.length);
    assert.equal(zip.readUInt32LE(item.offset),0x04034b50);
    assert.equal(zip.readUInt16LE(item.offset+8),0);
    assert.equal(zip.readUInt16LE(item.offset+6),0x0800);
    assert.deepEqual(zip.subarray(item.offset+30+Buffer.byteLength(item.name),item.offset+30+Buffer.byteLength(item.name)+png.length),png);
  }
});
test('abort removes incomplete temporary ZIP and never overwrites previous output',t=>{
  const dir=workspace(t),target=path.join(dir,'saved.zip');
  fs.writeFileSync(target,'previous');
  const writer=new CardZipWriter(target);
  writer.add('24980.png',png);
  assert.equal(fs.readFileSync(target,'utf8'),'previous');
  writer.abort();
  assert.equal(fs.readFileSync(target,'utf8'),'previous');
  assert.deepEqual(fs.readdirSync(dir),['saved.zip']);
});
test('invalid files, repeated codes and over 500 cards are rejected',t=>{
  const writer=new CardZipWriter(path.join(workspace(t),'cards.zip'));
  try{
    assert.throws(()=>writer.add('../24980.png',png),/имя карточки/);
    assert.throws(()=>writer.add('24980.png',Buffer.alloc(100)),/PNG/);
    writer.add('24980.png',png);
    assert.throws(()=>writer.add('24980.png',png),/Повторный код/);
    for(let code=10000;code<10499;code++)writer.add(String(code)+'.png',png);
    assert.throws(()=>writer.add('10499.png',png),/500/);
  }finally{writer.abort();}
});
