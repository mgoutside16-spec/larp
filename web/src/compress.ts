import type {Kind} from './types';

// Уменьшение материалов для телефонов игроков. Оригиналы на диске не меняются:
// в проект попадает сжатая копия, если она действительно меньше исходного файла.

export interface DesktopBridge {
  transcode(kind:'video'|'audio',name:string,bytes:ArrayBuffer,onProgress:(percent:number)=>void):Promise<{name:string;bytes:ArrayBuffer}|null>;
  version?:string;
}
declare global { interface Window { larpDesktop?: DesktopBridge } }

export const desktop=()=>typeof window!=='undefined'&&!!window.larpDesktop;
const KEY='larp-compress-media';
export function compressionEnabled(){try{return localStorage.getItem(KEY)!=='off';}catch{return true;}}
export function setCompression(on:boolean){try{localStorage.setItem(KEY,on?'on':'off');}catch{/* настройка необязательна */}}

const IMAGE_LIMIT=2048;
const mb=(n:number)=>(n/1024**2).toFixed(1).replace('.',',');
const stem=(name:string)=>name.replace(/\.[^.]+$/,'')||'image';

async function encode(canvas:HTMLCanvasElement,type:string,quality?:number):Promise<Blob>{
  return new Promise((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(new Error('Не удалось сжать изображение.')),type,quality));
}

function hasTransparency(ctx:CanvasRenderingContext2D,w:number,h:number){
  const data=ctx.getImageData(0,0,w,h).data;
  for(let i=3;i<data.length;i+=4)if(data[i]<255)return true;
  return false;
}

export async function shrinkImage(file:File):Promise<File>{
  const type=file.type.toLowerCase();
  if(!['image/png','image/jpeg','image/webp','image/bmp'].includes(type))return file;
  const bitmap=await createImageBitmap(file);
  try{
    const scale=Math.min(1,IMAGE_LIMIT/Math.max(bitmap.width,bitmap.height));
    if(scale===1&&file.size<=1.5*1024**2)return file;
    const w=Math.max(1,Math.round(bitmap.width*scale)),h=Math.max(1,Math.round(bitmap.height*scale));
    const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
    const ctx=canvas.getContext('2d',{willReadFrequently:true})!;
    ctx.imageSmoothingQuality='high';ctx.drawImage(bitmap,0,0,w,h);
    const transparent=type!=='image/jpeg'&&hasTransparency(ctx,w,h);
    let blob:Blob,ext:string;
    if(transparent){blob=await encode(canvas,'image/png');ext='png';}
    else{
      if(type!=='image/jpeg'){ctx.globalCompositeOperation='destination-over';ctx.fillStyle='#ffffff';ctx.fillRect(0,0,w,h);}
      blob=await encode(canvas,'image/jpeg',0.85);ext='jpg';
    }
    if(blob.size>=file.size)return file;
    return new File([blob],`${stem(file.name)}.${ext}`,{type:blob.type});
  }finally{bitmap.close();}
}

function audioNeedsWork(file:File){
  const ext=file.name.split('.').pop()?.toLowerCase()||'';
  return ['wav','flac','aif','aiff'].includes(ext)||file.size>8*1024**2;
}

async function videoAlreadySmall(file:File):Promise<boolean>{
  const url=URL.createObjectURL(file);
  try{
    const video=document.createElement('video');video.preload='metadata';video.muted=true;
    const loaded=new Promise<boolean>(res=>{video.onloadedmetadata=()=>res(true);video.onerror=()=>res(false);});
    video.src=url;
    const ok=await Promise.race([loaded,new Promise<boolean>(res=>setTimeout(()=>res(false),8000))]);
    if(!ok||!video.duration||!video.videoWidth)return false;
    const bitrate=file.size*8/video.duration;
    return Math.max(video.videoWidth,video.videoHeight)<=1280&&bitrate<=2_500_000;
  }finally{URL.revokeObjectURL(url);}
}

export async function prepareForPlayers(file:File,kind:Kind,status:(message:string)=>void,force=false):Promise<File>{
  if(!force&&!compressionEnabled())return file;
  try{
    if(kind==='image'){
      status(`Уменьшаем «${file.name}»…`);
      const out=await shrinkImage(file);
      status(out===file?'':`«${file.name}»: ${mb(file.size)} → ${mb(out.size)} МБ`);
      return out;
    }
    const bridge=window.larpDesktop;
    if(!bridge)return file;
    if(kind==='video'&&await videoAlreadySmall(file)){status('');return file;}
    if(kind==='video'||(kind==='audio'&&audioNeedsWork(file))){
      status(`Сжимаем «${file.name}» для телефонов… 0%`);
      const result=await bridge.transcode(kind,file.name,await file.arrayBuffer(),p=>status(`Сжимаем «${file.name}» для телефонов… ${Math.round(p)}%`));
      if(!result||result.bytes.byteLength>=file.size){status('');return file;}
      const type=result.name.endsWith('.m4a')?'audio/mp4':'video/mp4';
      const out=new File([result.bytes],result.name,{type});
      status(`«${file.name}»: ${mb(file.size)} → ${mb(out.size)} МБ`);
      return out;
    }
  }catch(error){
    status(`Не удалось сжать «${file.name}», добавлен исходный файл. ${(error as Error).message||''}`.trim());
  }
  return file;
}
