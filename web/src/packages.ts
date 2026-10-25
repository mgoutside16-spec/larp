import { zip, unzip, strToU8, strFromU8, type Zippable } from 'fflate';
import { type WorkshopStorage } from './storage';
import { type Asset, type Game, type Manifest, KINDS, mediaPath, now, requireValue, sha256 } from './types';

const MAX_TOTAL=1024**3,MAX_FILE=512*1024**2;
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function checkZip(bytes: Uint8Array): string[] {
  requireValue(bytes.length>=22 && bytes.length<=MAX_TOTAL,'Файл повреждён или слишком велик.');
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  let end=bytes.length-22;
  while(end>=Math.max(0,bytes.length-65557) && view.getUint32(end,true)!==0x06054b50)end--;
  requireValue(end>=0 && view.getUint32(end,true)===0x06054b50,'Файл не является игровым ZIP-пакетом.');
  requireValue(view.getUint16(end+4,true)===0 && view.getUint16(end+6,true)===0,'Многотомные архивы не поддерживаются.');
  const count=view.getUint16(end+10,true),names:string[]=[],seen=new Set<string>();
  let offset=view.getUint32(end+16,true),total=0;
  requireValue(count<65535,'Пакет содержит слишком много файлов для браузерной версии.');
  for(let i=0;i<count;i++) {
    requireValue(offset+46<=end && view.getUint32(offset,true)===0x02014b50,'Повреждён список файлов пакета.');
    const size=view.getUint32(offset+24,true),nameLength=view.getUint16(offset+28,true),extra=view.getUint16(offset+30,true),comment=view.getUint16(offset+32,true);
    requireValue(offset+46+nameLength+extra+comment<=end,'Повреждён пакет.');
    const name=new TextDecoder('utf-8',{fatal:true}).decode(bytes.subarray(offset+46,offset+46+nameLength));
    requireValue(!seen.has(name.toLowerCase()),'Пакет содержит совпадающие имена файлов.');seen.add(name.toLowerCase());
    if(name!=='manifest.json')mediaPath(name);
    requireValue(!(view.getUint16(offset+8,true)&1),'Зашифрованные архивы не поддерживаются.');
    requireValue(((view.getUint32(offset+38,true)>>>16)&0xf000)!==0xa000,'Ссылки в архиве запрещены.');
    requireValue(size<=MAX_FILE,'Файл в пакете превышает 512 МиБ.');total+=size;
    requireValue(total<=MAX_TOTAL,'Распакованный пакет превышает 1 ГиБ.');
    if(name==='manifest.json')requireValue(size<=16*1024**2,'Описание пакета слишком велико.');
    names.push(name);offset+=46+nameLength+extra+comment;
  }
  requireValue(names.includes('manifest.json'),'В пакете нет manifest.json.');return names;
}

function validate(m: Manifest, names: string[]) {
  requireValue(m && m.format_version===1,'Версия формата пакета не поддерживается.');
  requireValue(Number.isSafeInteger(m.version) && m.version>=1,'Некорректная версия пакета.');
  requireValue(m.game && UUID.test(m.game.id) && typeof m.game.name==='string' && m.game.name.trim() && typeof m.game.description==='string');
  requireValue(typeof m.created==='string' && Number.isFinite(Date.parse(m.created)));
  requireValue(Array.isArray(m.locations) && Array.isArray(m.records) && Array.isArray(m.reserved_codes) && m.checksums && typeof m.checksums==='object');
  const locs=new Set<number>(),locNames=new Set<string>();
  for(const loc of m.locations) {
    requireValue(loc && Number.isSafeInteger(loc.id) && loc.id>0 && typeof loc.name==='string' && loc.name.trim() && !locs.has(loc.id) && !locNames.has(loc.name));
    locs.add(loc.id);locNames.add(loc.name);
  }
  requireValue(m.reserved_codes.length<=90000 && m.reserved_codes.every(c=>typeof c==='string' && /^[1-9][0-9]{4}$/.test(c)));
  const reserved=new Set(m.reserved_codes);requireValue(reserved.size===m.reserved_codes.length);
  const codes=new Set(),ids=new Set(),media=new Set<string>();
  for(const row of m.records) {
    requireValue(row && UUID.test(row.id) && !ids.has(row.id) && typeof row.code==='string' && reserved.has(row.code) && !codes.has(row.code),'Некорректные или повторяющиеся коды записей.');
    ids.add(row.id);codes.add(row.code);
    requireValue(typeof row.title==='string' && row.title.trim() && typeof row.modified==='string');
    requireValue(row.location_id===null || locs.has(row.location_id));
    requireValue(Array.isArray(row.blocks));
    for(const b of row.blocks) {
      requireValue(b && Object.keys(b).sort().join(',')==='kind,value' && Object.hasOwn(KINDS,b.kind) && typeof b.value==='string');
      if(b.kind!=='text'){mediaPath(b.value);media.add(b.value);}
    }
  }
  const checks=Object.keys(m.checksums);
  requireValue(checks.length===media.size && checks.every(n=>media.has(n) && /^[0-9a-f]{64}$/.test(m.checksums[n])),'Неполный список контрольных сумм.');
  requireValue(names.length===media.size+1 && names.every(n=>n==='manifest.json'||media.has(n)),'В пакете лишние или отсутствующие медиафайлы.');
}

export async function readPackage(bytes: Uint8Array): Promise<{manifest:Manifest;assets:Asset[]}> {
  const names=checkZip(bytes);
  let files:Record<string,Uint8Array>;
  try { files=await new Promise((resolve,reject)=>unzip(bytes,(error,data)=>error?reject(new Error('Пакет повреждён.')):resolve(data))); }
  catch {throw new Error('Пакет повреждён. Не удалось распаковать файлы.');}
  let manifest:Manifest;
  try {manifest=JSON.parse(strFromU8(files['manifest.json']));}catch{throw new Error('Пакет повреждён: не удалось прочитать manifest.json.');}
  validate(manifest,names);
  const assets:Asset[]=[];
  for(const [path,expected] of Object.entries(manifest.checksums)) {
    const digest=await sha256(files[path]);
    requireValue(digest===expected,`Не совпадает контрольная сумма файла ${path}.`);
    const embedded=/^media\/([0-9a-f]{64})\./.exec(path);
    requireValue(!embedded || embedded[1]===digest,'Имя медиафайла не соответствует его контрольной сумме.');
    assets.push({path,blob:new Blob([new Uint8Array(files[path])],{type:mime(path)}),name:path.slice(6),mime:mime(path)});
  }
  return {manifest,assets};
}

export function mime(path: string) {
  const ext=path.split('.').pop()?.toLowerCase();
  return ({png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',webp:'image/webp',gif:'image/gif',bmp:'image/bmp',mp3:'audio/mpeg',wav:'audio/wav',ogg:'audio/ogg',m4a:'audio/mp4',flac:'audio/flac',mp4:'video/mp4',webm:'video/webm',mov:'video/quicktime'} as Record<string,string>)[ext||''] || 'application/octet-stream';
}

export async function makePackage(store: WorkshopStorage,id: string): Promise<Uint8Array> {
  const game=await store.game(id);
  const playerVersion=await store.playerVersion(id),version=Math.max(game.version,playerVersion)+1;
  requireValue(Number.isSafeInteger(version),'Диапазон версий исчерпан. Создайте копию игры.');
  const files:Zippable={},checksums:Record<string,string>={};let total=0;
  for(const row of game.records)for(const block of row.blocks)if(block.kind!=='text' && !Object.hasOwn(checksums,block.value)) {
    const asset=await store.media(id,block.value);
    requireValue(asset.blob.size<=MAX_FILE,'Один медиафайл превышает 512 МиБ.');total+=asset.blob.size;
    requireValue(total<=MAX_TOTAL,'Игровой пакет превышает 1 ГиБ. Разделите его на проекты меньшего размера.');
    const bytes=new Uint8Array(await asset.blob.arrayBuffer());
    checksums[block.value]=await sha256(bytes);
    const embedded=/^media\/([0-9a-f]{64})\./.exec(block.value);
    requireValue(!embedded || embedded[1]===checksums[block.value],'Медиафайл повреждён. Восстановите его из резервной копии.');
    files[block.value]=[bytes,{level:0}];
  }
  const manifest:Manifest={format_version:1,version,created:now(),game:{id:game.packageId,name:game.name,description:game.description},
    locations:game.locations,records:game.records.map(({revision,...row})=>row),reserved_codes:game.reserved_codes,checksums};
  const description=strToU8(JSON.stringify(manifest,null,2));
  requireValue(description.length<=16*1024**2,'Описание пакета превышает 16 МиБ. Разделите игру на проекты меньшего размера.');
  requireValue(total+description.length<=MAX_TOTAL,'Игровой пакет превышает 1 ГиБ.');
  files['manifest.json']=description;validate(manifest,Object.keys(files));
  const bytes=await new Promise<Uint8Array>((resolve,reject)=>zip(files,{level:6},(error,data)=>error?reject(error):resolve(data)));
  checkZip(bytes);
  await store.update(id,current=>{
    requireValue(current.modified===game.modified && current.version===game.version,'Проект изменился во время экспорта. Повторите создание пакета.');
    current.version=manifest.version;current.builds.unshift({version:manifest.version,created:manifest.created,filename:`${game.name}-v${manifest.version}.rpgpack`});
  });
  return bytes;
}

export async function importPackage(store: WorkshopStorage,bytes:Uint8Array):Promise<Game> {
  const {manifest:m,assets}=await readPackage(bytes),id=crypto.randomUUID();
  const game:Game={id,packageId:m.game.id,name:m.game.name,description:m.game.description,created:now(),modified:now(),version:m.version,
    locations:m.locations,records:m.records.map(r=>({...r,revision:1})),reserved_codes:m.reserved_codes,
    builds:[{version:m.version,created:m.created,filename:'Импортированный пакет'}]};
  return store.addImported(game,assets);
}
