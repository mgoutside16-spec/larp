import { openDB, type IDBPDatabase } from 'idb';
import { type Asset, type Draft, type Game, type Material, KINDS, now, title, requireValue, mediaPath, sha256 } from './types';
import { validateTemplate, type PrintTemplate } from './print-layout';

export function allocateCode(reserved: string[]): string {
  const occupied = new Set(reserved);
  requireValue(occupied.size < 90000, 'Диапазон кодов исчерпан: все 90 000 кодов уже использованы.');
  const random = new Uint32Array(1), limit = Math.floor(2 ** 32 / 90000) * 90000;
  for (let tries = 0; tries < 64; tries++) {
    crypto.getRandomValues(random);
    if (random[0] >= limit) continue;
    const candidate = String(10000 + random[0] % 90000);
    if (!occupied.has(candidate)) return candidate;
  }
  const free = Array.from({length:90000},(_,i)=>String(i+10000)).filter(c=>!occupied.has(c));
  crypto.getRandomValues(random);
  return free[random[0] % free.length];
}

export async function stageMedia(file: File): Promise<Asset> {
  requireValue(file.size <= 512 * 1024 ** 2, 'Один медиафайл должен быть меньше 512 МиБ.');
  const ext = file.name.split('.').pop()?.toLowerCase();
  requireValue(ext && /^[a-z0-9]{1,12}$/.test(ext), 'У файла должно быть обычное расширение: png, mp3, mp4 и т. п.');
  const path = `media/${await sha256(await file.arrayBuffer())}.${ext}`;
  mediaPath(path);
  return {path,blob:file,name:file.name,mime:file.type || 'application/octet-stream'};
}

export class Storage {
  private constructor(private db: IDBPDatabase) {}
  static async open(name = 'larp-studio') {
    const db = await openDB(name, 1, {
      upgrade(db) {
        if (!db.objectStoreNames.contains('games')) db.createObjectStore('games', {keyPath:'id'});
        if (!db.objectStoreNames.contains('media')) {
          const media = db.createObjectStore('media', {keyPath:['projectId','path']});
          media.createIndex('projectId','projectId');
        }
        if (!db.objectStoreNames.contains('preferences')) db.createObjectStore('preferences');
      },
      blocking() { db.close(); },
    });
    return new Storage(db);
  }
  close() { this.db.close(); }
  async list(): Promise<Game[]> { return (await this.db.getAll('games')).sort((a,b)=>b.modified.localeCompare(a.modified)); }
  async game(id: string): Promise<Game> {
    const game = await this.db.get('games', id);
    requireValue(game, 'Проект не найден. Выберите другой проект.');
    return game;
  }
  async playerVersion(id:string):Promise<number> {return (await this.game(id)).version;}
  async media(projectId: string, path: string): Promise<Asset> {
    mediaPath(path);
    const asset = await this.db.get('media',[projectId,path]);
    requireValue(asset, 'Медиафайл отсутствует. Восстановите его из резервной копии.');
    return asset;
  }
  async preference(key: string, value?: string) {
    if (value !== undefined) return this.db.put('preferences',value,key);
    return this.db.get('preferences',key);
  }
  async create(name: string, description = ''): Promise<Game> {
    const id=crypto.randomUUID();
    const game: Game = {id,packageId:id,name:title(name),description,created:now(),modified:now(),
      version:0,records:[],locations:[],reserved_codes:[],builds:[]};
    await this.db.add('games',game);
    await this.preference('last-game',id);
    return game;
  }
  async update(id: string, mutate: (game: Game) => void): Promise<Game> {
    const tx=this.db.transaction('games','readwrite');
    const done=tx.done; done.catch(()=>{});
    try {
      const game: Game=await tx.store.get(id);
      requireValue(game,'Проект не найден.');
      mutate(game);game.modified=now();
      await tx.store.put(game);await done;
      return game;
    } catch (error) { try {tx.abort();} catch {} await done.catch(()=>{}); throw error; }
  }
  async rename(id: string, name: string, description: string) {
    return this.update(id,game=>{game.name=title(name);game.description=description;});
  }
  async addLocation(id: string, name: string): Promise<number> {
    name=title(name); let locationId=0;
    await this.update(id,game=>{
      requireValue(!game.locations.some(l=>l.name===name),'Группа с таким названием уже есть.');
      locationId=Math.max(0,...game.locations.map(l=>l.id))+1;
      game.locations.push({id:locationId,name});
    });return locationId;
  }
  async renameLocation(id: string, loc: number, name: string) {
    name=title(name);
    return this.update(id,game=>{
      requireValue(!game.locations.some(l=>l.id!==loc && l.name===name),'Группа с таким названием уже есть.');
      const item=game.locations.find(l=>l.id===loc); requireValue(item,'Группа не найдена.');item.name=name;
    });
  }
  async deleteLocation(id: string, loc: number) {
    return this.update(id,game=>{
      game.locations=game.locations.filter(l=>l.id!==loc);
      game.records.forEach(r=>{if(r.location_id===loc)r.location_id=null;});
    });
  }
  async addGroup(id:string,name:string){return this.addLocation(id,name);}
  async renameGroup(id:string,group:number,name:string){return this.renameLocation(id,group,name);}
  async deleteGroup(id:string,group:number){return this.deleteLocation(id,group);}
  async savePrintTemplate(id:string,scope:string,template:PrintTemplate,asset?:Asset) {
    validateTemplate(template);
    requireValue(scope==='all'||scope==='none'||/^[1-9][0-9]*$/.test(scope),'Неизвестная группа шаблона.');
    const tx=this.db.transaction(['games','media'],'readwrite'),done=tx.done;done.catch(()=>{});
    try{
      const game:Game=await tx.objectStore('games').get(id);requireValue(game,'Проект не найден.');
      if(asset){requireValue(asset.path===template.imagePath,'Файл не соответствует шаблону.');await tx.objectStore('media').put({...asset,projectId:id});}
      requireValue(await tx.objectStore('media').get([id,template.imagePath]),'Файл шаблона не найден.');
      game.printTemplates={...game.printTemplates,[scope]:structuredClone(template)};game.modified=now();
      await tx.objectStore('games').put(game);await done;return game;
    }catch(error){try{tx.abort();}catch{}await done.catch(()=>{});throw error;}
  }
  async cacheSnapshot(game:Game,assets:Asset[]=[]) {
    const tx=this.db.transaction(['games','media'],'readwrite');await tx.objectStore('games').put(game);
    for(const asset of assets)await tx.objectStore('media').put({...asset,projectId:game.id});await tx.done;
  }
  async allMedia(id:string):Promise<Asset[]> {return this.db.getAllFromIndex('media','projectId',id);}
  async saveRecord(id: string, draft: Draft, assets: Asset[]=[]): Promise<Material> {
    const recordTitle=title(draft.title);
    const tx=this.db.transaction(['games','media'],'readwrite'),done=tx.done;done.catch(()=>{});
    try {
      const game: Game=await tx.objectStore('games').get(id);requireValue(game,'Проект не найден.');
      requireValue(draft.location_id===null || game.locations.some(l=>l.id===draft.location_id),'Выбранная группа удалена. Выберите другую.');
      for (const asset of assets) {
        mediaPath(asset.path);
        await tx.objectStore('media').put({...asset,projectId:id});
      }
      for (const block of draft.blocks) {
        requireValue(Object.hasOwn(KINDS,block.kind) && typeof block.value==='string','Некорректный блок.');
        if(block.kind!=='text') {
          mediaPath(block.value);
          requireValue(await tx.objectStore('media').get([id,block.value]),'Медиафайл отсутствует. Добавьте его повторно.');
        }
      }
      const existing=draft.id ? game.records.find(r=>r.id===draft.id) : undefined;
      if(draft.id) {
        requireValue(existing,'Запись удалена в другой вкладке.');
        requireValue(existing.revision===draft.revision,'Запись изменена в другой вкладке. Закройте редактор и откройте её заново.');
      }
      const row: Material={id:existing?.id || crypto.randomUUID(),code:existing?.code || allocateCode(game.reserved_codes),
        title:recordTitle,location_id:draft.location_id,blocks:structuredClone(draft.blocks),modified:now(),revision:(existing?.revision || 0)+1};
      if(existing)game.records[game.records.indexOf(existing)]=row;
      else {game.records.push(row);game.reserved_codes.push(row.code);}
      game.modified=now();await tx.objectStore('games').put(game);await done;return row;
    } catch(error) { try {tx.abort();} catch {} await done.catch(()=>{});throw error; }
  }
  async deleteRecord(id: string, recordId: string) { return this.update(id,game=>{game.records=game.records.filter(r=>r.id!==recordId);}); }
  async addImported(game: Game, assets: Asset[]) {
    const tx=this.db.transaction(['games','media'],'readwrite'),done=tx.done;done.catch(()=>{});
    try {
      await tx.objectStore('games').add(game);
      for(const asset of assets)await tx.objectStore('media').add({...asset,projectId:game.id});
      await done;await this.preference('last-game',game.id);return game;
    } catch(error) {try{tx.abort();}catch{}await done.catch(()=>{});throw error;}
  }
  async copy(id: string) {
    const source=await this.game(id),copy=structuredClone(source),newId=crypto.randomUUID();
    copy.id=newId;copy.packageId=newId;copy.name+=' — копия';copy.version=0;copy.builds=[];copy.created=now();copy.modified=now();
    const assets: Asset[]=await this.db.getAllFromIndex('media','projectId',id);
    return this.addImported(copy,assets);
  }
  async deleteGame(id: string) {
    const tx=this.db.transaction(['games','media'],'readwrite');
    await tx.objectStore('games').delete(id);
    for(const key of await tx.objectStore('media').index('projectId').getAllKeys(id))await tx.objectStore('media').delete(key);
    await tx.done;
  }
}

export type WorkshopStorage=Pick<Storage,keyof Storage>;
