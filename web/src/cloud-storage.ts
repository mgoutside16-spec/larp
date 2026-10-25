import type { SupabaseClient } from '@supabase/supabase-js';
import { Storage, type WorkshopStorage } from './storage';
import { type Asset, type Draft, type Game, type Material, mediaPath, now, requireValue, sha256 } from './types';
import { type PrintTemplate } from './print-layout';
import { mime } from './packages';
import {deleteDB} from 'idb';

export interface Identity {user_id:string;email:string;display_name:string;is_admin:boolean}
export interface Member {user_id:string;email:string;display_name:string;is_owner:boolean}
export interface GamePlayer {participant_id:string;character_name:string;first_seen:string;last_seen:string}
interface Snapshot {id:string;owner_id:string;revision:number;document:Game;status:string}

export function backendMessage(error:{message?:string;code?:string}|null):Error {
  if(error?.code==='PGRST202'||error?.code==='42P01')return new Error('База мастерской ещё не настроена. Выполните SQL-скрипт подключения.');
  if(error?.code==='40001')return new Error('Проект изменился у другого участника. Обновите данные и повторите действие.');
  if(error?.code==='42501')return new Error('У вас нет доступа к этому проекту или действию.');
  if(/maximum.*size|too.*large|exceeded.*size/i.test(error?.message||''))return new Error('Файл слишком большой для текущего хранилища. На бесплатном тарифе Supabase используйте файлы до 50 МиБ.');
  if(/fetch|network|connection/i.test(error?.message||''))return new Error('Нет связи с хранилищем. Проверьте интернет и повторите сохранение.');
  return new Error(error?.message||'Не удалось связаться с хранилищем. Проверьте соединение.');
}

function snapshot(data:unknown):Snapshot {
  const row=(Array.isArray(data)?data[0]:data) as Snapshot;
  requireValue(row?.document&&Number.isSafeInteger(row.revision),'Хранилище вернуло некорректный проект.');
  return row;
}

export function projectMedia(game:Game):string[] {
  const paths=new Set<string>();
  for(const row of game.records)for(const block of row.blocks)if(block.kind!=='text')paths.add(block.value);
  for(const template of Object.values(game.printTemplates||{}))paths.add(template.imagePath);
  return [...paths];
}

/** Cloud writes always go through server CAS; IndexedDB is an account-scoped cache. */
export class CloudStorage implements WorkshopStorage {
  private active=true;
  private revisions=new Map<string,Snapshot>();
  private constructor(readonly client:SupabaseClient,readonly userId:string,private local:Storage){}
  static async open(client:SupabaseClient,userId:string){return new CloudStorage(client,userId,await Storage.open(`larp-studio-account-${userId}`));}
  private check(){requireValue(this.active,'Сеанс завершён. Войдите в аккаунт заново.');}
  close(){this.active=false;this.revisions.clear();this.local.close();}
  async clearPrivateCache(){this.close();await deleteDB(`larp-studio-account-${this.userId}`);}
  owner(id:string){return this.revisions.get(id)?.owner_id;}
  publicationSnapshot(id:string){
    this.check();const row=this.revisions.get(id);
    requireValue(row?.status==='active','Проект ещё не готов к публикации. Обновите страницу.');
    return {revision:row.revision,document:structuredClone(row.document)};
  }
  async preference(key:string,value?:string){this.check();return this.local.preference(key,value);}
  async list():Promise<Game[]>{
    this.check();const {data,error}=await this.client.from('workshop_projects').select('id,owner_id,revision,document,status').eq('status','active').order('updated_at',{ascending:false});
    if(error)throw backendMessage(error);this.check();
    return (data||[]).map(row=>{const item=snapshot(row);this.revisions.set(item.id,item);return item.document;});
  }
  private async fetch(id:string):Promise<Snapshot>{
    this.check();const {data,error}=await this.client.from('workshop_projects').select('id,owner_id,revision,document,status').eq('id',id).maybeSingle();
    if(error)throw backendMessage(error);this.check();requireValue(data,'Проект удалён или доступ к нему закрыт.');
    const item=snapshot(data);this.revisions.set(id,item);await this.local.cacheSnapshot(item.document);return item;
  }
  async game(id:string){return (await this.fetch(id)).document;}
  async playerVersion(id:string):Promise<number>{
    this.check();const {data,error}=await this.client.rpc('get_player_source_version',{p_project_id:id});
    this.check();
    // Older deployments can still export and publish before the additive migration.
    if(error?.code==='PGRST202')return (await this.game(id)).version;
    if(error)throw backendMessage(error);
    requireValue(Number.isSafeInteger(data)&&data>=0,'Хранилище вернуло некорректную версию материалов игрока.');
    return data;
  }
  async players(id:string):Promise<GamePlayer[]>{
    this.check();const {data,error}=await this.client.rpc('list_game_players',{p_project_id:id});this.check();
    if(error)throw backendMessage(error);
    requireValue(Array.isArray(data),'Хранилище вернуло некорректный список игроков.');
    return data.map(row=>{
      requireValue(typeof row?.participant_id==='string'&&typeof row.character_name==='string'
        &&typeof row.first_seen==='string'&&Number.isFinite(Date.parse(row.first_seen))
        &&typeof row.last_seen==='string'&&Number.isFinite(Date.parse(row.last_seen)),
      'Хранилище вернуло некорректный список игроков.');
      const {participant_id,character_name,first_seen,last_seen}=row;
      return {participant_id,character_name,first_seen,last_seen};
    });
  }
  private async save(game:Game,revision:number,activate=true){
    this.check();const {data,error}=await this.client.rpc('save_workshop_project',{p_document:game,p_expected_revision:revision,p_activate:activate});
    if(error)throw Object.assign(backendMessage(error),{backendCode:error.code});this.check();const row=snapshot(data);
    this.revisions.set(game.id,row);await this.local.cacheSnapshot(row.document);return row;
  }
  private async mutate<T>(id:string,operation:(local:Storage)=>Promise<T>,assets:Asset[]=[]):Promise<{game:Game;result:T}>{
    for(let attempt=0;attempt<4;attempt++){
      const row=await this.fetch(id),workspaceName=`larp-studio-proposal-${crypto.randomUUID()}`;
      const workspace=await Storage.open(workspaceName);let result:T,proposed:Game;
      try{
        // A proposal is never read from the account cache: reads in another tab
        // or an overlapping media fetch must not overwrite an unsent edit.
        await workspace.cacheSnapshot(row.document,assets);
        result=await operation(workspace);proposed=await workspace.game(id);
      }finally{workspace.close();await deleteDB(workspaceName);}
      try{return {game:(await this.save(proposed,row.revision)).document,result};}
      catch(error){if((error as {backendCode?:string}).backendCode!=='40001'||attempt===3)throw error;}
    }
    throw new Error('Проект часто меняется. Повторите сохранение через несколько секунд.');
  }
  async create(name:string,description=''){
    this.check();const game=await this.local.create(name,description);
    try{return (await this.save(game,0)).document;}catch(error){await this.local.deleteGame(game.id);throw error;}
  }
  async update(id:string,mutate:(game:Game)=>void){return (await this.mutate(id,local=>local.update(id,mutate))).game;}
  async rename(id:string,name:string,description:string){return (await this.mutate(id,local=>local.rename(id,name,description))).game;}
  async addLocation(id:string,name:string){return (await this.mutate(id,local=>local.addGroup(id,name))).result;}
  async renameLocation(id:string,loc:number,name:string){return (await this.mutate(id,local=>local.renameGroup(id,loc,name))).game;}
  async deleteLocation(id:string,loc:number){return (await this.mutate(id,local=>local.deleteGroup(id,loc))).game;}
  async addGroup(id:string,name:string){return this.addLocation(id,name);}
  async renameGroup(id:string,group:number,name:string){return this.renameLocation(id,group,name);}
  async deleteGroup(id:string,group:number){return this.deleteLocation(id,group);}
  async media(id:string,path:string):Promise<Asset>{
    this.check();mediaPath(path);
    // Check current access even when a media Blob is already cached locally.
    await this.fetch(id);
    try{return await this.local.media(id,path);}catch{}
    const {data,error}=await this.client.storage.from('workshop-media').download(`${id}/${path}`);
    if(error)throw backendMessage(error);this.check();requireValue(data,'Медиафайл не найден.');
    const asset:Asset={path,blob:data,name:path.slice(6),mime:data.type||mime(path)};
    await this.local.cacheSnapshot((await this.local.game(id)),[asset]);return asset;
  }
  private async upload(id:string,asset:Asset){
    this.check();mediaPath(asset.path);
    const {error}=await this.client.storage.from('workshop-media').upload(`${id}/${asset.path}`,asset.blob,{upsert:false,contentType:asset.mime||mime(asset.path)});
    if(error){
      const status=String((error as {statusCode?:string}).statusCode||'');
      if(status==='409'||/already exists|duplicate/i.test(error.message)){
        const {data,error:downloadError}=await this.client.storage.from('workshop-media').download(`${id}/${asset.path}`);
        if(downloadError||!data)throw backendMessage(downloadError);
        requireValue(await sha256(await data.arrayBuffer())===await sha256(await asset.blob.arrayBuffer()),'В хранилище найден другой файл с тем же именем.');
      }else throw backendMessage(error);
    }
    this.check();
  }
  async saveRecord(id:string,draft:Draft,assets:Asset[]=[]):Promise<Material>{
    await this.fetch(id);
    for(const asset of assets)await this.upload(id,asset);
    // Cache existing media before opening an IndexedDB transaction.
    const proposalAssets=[...assets];
    for(const block of draft.blocks)if(block.kind!=='text'&&!proposalAssets.some(a=>a.path===block.value))proposalAssets.push(await this.media(id,block.value));
    return (await this.mutate(id,local=>local.saveRecord(id,draft,proposalAssets),proposalAssets)).result;
  }
  async deleteRecord(id:string,recordId:string){return (await this.mutate(id,local=>local.deleteRecord(id,recordId))).game;}
  async savePrintTemplate(id:string,scope:string,template:PrintTemplate,asset?:Asset){
    await this.fetch(id);const source=asset||await this.media(id,template.imagePath);if(asset)await this.upload(id,asset);
    return (await this.mutate(id,local=>local.savePrintTemplate(id,scope,template,source),[source])).game;
  }
  async cacheSnapshot(game:Game,assets:Asset[]=[]){this.check();await this.fetch(game.id);await this.local.cacheSnapshot(game,assets);}
  async allMedia(id:string){const game=await this.game(id);return Promise.all(projectMedia(game).map(path=>this.media(id,path)));}
  async addImported(game:Game,assets:Asset[]=[]){
    this.check();
    const staged:Game={...structuredClone(game),records:[],reserved_codes:[],builds:[],printTemplates:undefined,version:0};
    const row=await this.save(staged,0,false);
    const uploaded:string[]=[];
    try{
      for(const asset of assets){await this.upload(game.id,asset);uploaded.push(`${game.id}/${asset.path}`);}
      return (await this.save(game,row.revision,true)).document;
    }catch(error){
      const {error:deleteError}=await this.client.rpc('delete_workshop_project',{p_id:game.id,p_expected_revision:row.revision});
      if(!deleteError)for(let i=0;i<uploaded.length;i+=100)await this.client.storage.from('workshop-media').remove(uploaded.slice(i,i+100));
      throw error;
    }
  }
  async copy(id:string){
    const original=await this.game(id),assets=await Promise.all(projectMedia(original).map(path=>this.media(id,path))),copy=structuredClone(original),newId=crypto.randomUUID();
    copy.id=newId;copy.packageId=newId;copy.name+=' — копия';copy.version=0;copy.builds=[];copy.created=now();copy.modified=now();
    return this.addImported(copy,assets);
  }
  async deleteGame(id:string){
    const row=await this.fetch(id);
    const files:string[]=[];
    for(let offset=0;;offset+=100){
      const {data,error}=await this.client.storage.from('workshop-media').list(`${id}/media`,{limit:100,offset});
      if(error)throw backendMessage(error);const page=data||[];
      for(const file of page)if(file.id)files.push(`${id}/media/${file.name}`);
      if(page.length<100)break;
    }
    const {error}=await this.client.rpc('delete_workshop_project',{p_id:id,p_expected_revision:row.revision});
    if(error)throw backendMessage(error);this.check();this.revisions.delete(id);await this.local.deleteGame(id);
    for(let offset=0;offset<files.length;offset+=100){
      const {error:removeError}=await this.client.storage.from('workshop-media').remove(files.slice(offset,offset+100));
      if(removeError)throw new Error('Проект удалён, но очистка файлов не завершена. Администратор может повторить очистку хранилища.');
    }
  }
}

export class AccountService {
  constructor(readonly client:SupabaseClient){}
  async identity():Promise<Identity>{const {data,error}=await this.client.rpc('get_workshop_identity');if(error)throw backendMessage(error);return data;}
  async profile(name:string):Promise<Identity>{const {data,error}=await this.client.rpc('set_workshop_display_name',{p_name:name});if(error)throw backendMessage(error);return data;}
  async users():Promise<Identity[]>{const {data,error}=await this.client.rpc('list_workshop_users');if(error)throw backendMessage(error);return data||[];}
  async admin(userId:string,isAdmin:boolean){const {error}=await this.client.rpc('set_workshop_admin',{p_user_id:userId,p_admin:isAdmin});if(error)throw backendMessage(error);}
  async members(projectId:string):Promise<Member[]>{const {data,error}=await this.client.rpc('list_workshop_members',{p_project_id:projectId});if(error)throw backendMessage(error);return data||[];}
  async addMember(projectId:string,email:string){const {data,error}=await this.client.rpc('add_workshop_member',{p_project_id:projectId,p_email:email});if(error)throw backendMessage(error);return data as {status:string};}
  async removeMember(projectId:string,userId:string){const {error}=await this.client.rpc('remove_workshop_member',{p_project_id:projectId,p_user_id:userId});if(error)throw backendMessage(error);}
  async invites(projectId:string):Promise<{email:string;created_at:string}[]>{const {data,error}=await this.client.rpc('list_workshop_invites',{p_project_id:projectId});if(error)throw backendMessage(error);return data||[];}
  async removeInvite(projectId:string,email:string){const {error}=await this.client.rpc('remove_workshop_invite',{p_project_id:projectId,p_email:email});if(error)throw backendMessage(error);}
}
