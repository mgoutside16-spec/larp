// Run from web/: node --import tsx ../mobile/test/core/fixtures/generate_web.mts
import '../../../../web/node_modules/fake-indexeddb/auto/index.mjs';
import { writeFile } from 'node:fs/promises';
import { Storage, stageMedia } from '../../../../web/src/storage.ts';
import { makePackage } from '../../../../web/src/packages.ts';
const store = await Storage.open(`fixture-${crypto.randomUUID()}`);
const game = await store.create('Русская игра');
const media = await stageMedia(new File(['image'], 'photo.png', {type:'image/png'}));
await store.saveRecord(game.id, {title:'Запись',location_id:null,blocks:[
  {kind:'text',value:'<p>Привет</p>'},{kind:'image',value:media.path},
]},[media]);
await writeFile(new URL('./web.rpgpack',import.meta.url),await makePackage(store,game.id));
store.close();
