import {CloudStorage,backendMessage} from './cloud-storage';
import {makePackage,readPackage} from './packages';
import {requireValue,sha256} from './types';

export interface PlayerRelease {
  game_id:string;name:string;version:number;sha256:string;size:number;download_path:string;created_at:string;
}

export function playerGameLink(gameId:string){
  requireValue(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(gameId),'Некорректный идентификатор игры.');
  return `https://mgoutside16-spec.github.io/larp/?game=${gameId.toLowerCase()}`;
}

function publicationError(error:{message?:string;code?:string}|null){
  if(error?.code==='PGRST202'||error?.code==='42P01')return new Error('Онлайн-обновления ещё не настроены. Администратору нужно выполнить backend/player-updates.sql в Supabase.');
  return backendMessage(error);
}

function canonical(value:unknown):string {
  if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
  if(value&&typeof value==='object')return '{'+Object.entries(value).sort(([a],[b])=>a.localeCompare(b)).map(([key,item])=>JSON.stringify(key)+':'+canonical(item)).join(',')+'}';
  return JSON.stringify(value);
}

/** Publish the exact portable archive. CAS never silently rebuilds after upload. */
export async function publishPlayerUpdate(store:CloudStorage,projectId:string):Promise<PlayerRelease>{
  const original=await store.game(projectId);
  // Diagnose an unapplied additive migration before building/uploading a package.
  const {error:setupError}=await store.client.rpc('get_player_release',{p_game_id:original.packageId});
  if(setupError)throw publicationError(setupError);
  const bytes=await makePackage(store,projectId),snapshot=store.publicationSnapshot(projectId);
  const {manifest}=await readPackage(bytes),game=snapshot.document;
  requireValue(canonical({id:game.packageId,name:game.name,description:game.description})===canonical(manifest.game)
    &&game.version===manifest.version&&canonical(game.locations)===canonical(manifest.locations)
    &&canonical(game.records.map(({revision,...row})=>row))===canonical(manifest.records)
    &&canonical(game.reserved_codes)===canonical(manifest.reserved_codes),
  'Проект изменился во время сборки. Повторите публикацию.');
  const digest=await sha256(bytes),path=`${projectId}/${manifest.version}/${digest}.rpgpack`;
  const {error:uploadError}=await store.client.storage.from('player-releases').upload(path,new Blob([new Uint8Array(bytes)],{type:'application/octet-stream'}),{upsert:false,contentType:'application/octet-stream',cacheControl:'0'});
  if(uploadError)throw publicationError(uploadError);
  const {data,error}=await store.client.rpc('publish_player_release',{
    p_project_id:projectId,p_expected_revision:snapshot.revision,p_version:manifest.version,
    p_path:path,p_sha256:digest,p_size:bytes.length,
  });
  if(error)throw publicationError(error);
  const release=data as PlayerRelease;
  requireValue(typeof release?.game_id==='string'&&release.game_id.toLowerCase()===manifest.game.id.toLowerCase()&&release.name===manifest.game.name&&release.version===manifest.version
    &&release.sha256===digest&&release.size===bytes.length&&release.download_path===path
    &&typeof release.created_at==='string'&&Number.isFinite(Date.parse(release.created_at)),
  'Сервер вернул некорректную публикацию. Обновите страницу и проверьте опубликованную версию.');
  return release;
}
