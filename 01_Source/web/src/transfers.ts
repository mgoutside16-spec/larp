/** Keep the SDK's authentication and HTTP protocol; observe only its upload transport. */
export interface SaveProgress {phase:'checking'|'upload'|'saving';loaded:number;total:number;name?:string}
export interface SaveOptions {signal?:AbortSignal;onProgress?:(progress:SaveProgress)=>void}
interface UploadWatch {signal?:AbortSignal;progress:(ratio:number)=>void}
const cancelled=()=>new Error('Загрузка отменена. Запись не сохранена.');
const stalled=()=>new Error('Хранилище долго не отвечает. Проверьте интернет и повторите сохранение — запись осталась в редакторе.');

export class Transfers {
  private watches=new Map<string,UploadWatch>();
  constructor(private readonly idleMs=60000,private readonly requestMs=45000){}
  watch(path:string,watch:UploadWatch){
    const key='/storage/v1/object/workshop-media/'+path;
    this.watches.set(key,watch);
    return ()=>{if(this.watches.get(key)===watch)this.watches.delete(key);};
  }
  readonly fetch:typeof fetch=async(input,init)=>{
    const url=typeof input==='string'?input:input instanceof URL?input.href:input.url;
    const method=(init?.method||(input instanceof Request?input.method:'GET')).toUpperCase();
    if(typeof XMLHttpRequest!=='undefined'&&method==='POST'&&new URL(url).pathname.startsWith('/storage/v1/object/')){
      return this.upload(url,init||{});
    }
    const watch=this.watches.get(decodeURIComponent(new URL(url).pathname));
    const controller=new AbortController();
    const signals=[init?.signal||(input instanceof Request?input.signal:undefined),watch?.signal].filter((s):s is AbortSignal=>!!s);
    let timer:ReturnType<typeof setTimeout>,reader:ReadableStreamDefaultReader<Uint8Array>|undefined,
      body:ReadableStreamDefaultController<Uint8Array>|undefined,ended=false,timedOut=false;
    const cleanup=()=>{clearTimeout(timer);signals.forEach(s=>s.removeEventListener('abort',abort));};
    const error=()=>timedOut?stalled():watch?.signal?.aborted?cancelled():controller.signal.reason;
    const stopBody=()=>{
      if(ended)return;ended=true;cleanup();body?.error(error());void reader?.cancel(error()).catch(()=>{});
    };
    const abort=()=>{controller.abort(signals.find(s=>s.aborted)?.reason);if(body)stopBody();};
    const activity=()=>{clearTimeout(timer);timer=setTimeout(()=>{timedOut=true;controller.abort();if(body)stopBody();},watch?this.idleMs:this.requestMs);};
    signals.forEach(s=>s.addEventListener('abort',abort,{once:true}));
    if(signals.some(s=>s.aborted))abort();
    activity();
    try{
      const response=await globalThis.fetch(input,{...init,signal:controller.signal});
      if(!response.body){ended=true;cleanup();return response;}
      reader=response.body.getReader();
      const stream=new ReadableStream<Uint8Array>({
        start(streamController){body=streamController;activity();if(controller.signal.aborted)stopBody();},
        async pull(streamController){
          try{
            const chunk=await reader!.read();if(ended)return;
            if(chunk.done){ended=true;cleanup();streamController.close();}
            else{activity();streamController.enqueue(chunk.value);}
          }catch(cause){if(ended)return;ended=true;cleanup();streamController.error(controller.signal.aborted?error():cause);}
        },
        cancel(reason){ended=true;cleanup();controller.abort(reason);return reader!.cancel(reason);},
      });
      return new Response(stream,{status:response.status,statusText:response.statusText,headers:response.headers});
    }catch(cause){ended=true;cleanup();if(controller.signal.aborted)throw error();throw cause;}
  };

  private upload(url:string,init:RequestInit):Promise<Response>{
    const watch=this.watches.get(decodeURIComponent(new URL(url).pathname));
    return new Promise((resolve,reject)=>{
      const xhr=new XMLHttpRequest();
      let finished=false,timer:ReturnType<typeof setTimeout>;
      const signals=[init.signal,watch?.signal].filter((s):s is AbortSignal=>!!s);
      const finish=(error?:Error,response?:Response)=>{
        if(finished)return;finished=true;clearTimeout(timer);
        signals.forEach(s=>s.removeEventListener('abort',abort));
        if(error)reject(error);else resolve(response!);
      };
      const abort=()=>{finish(cancelled());xhr.abort();};
      const activity=()=>{clearTimeout(timer);timer=setTimeout(()=>{finish(stalled());xhr.abort();},this.idleMs);};
      xhr.open('POST',url);
      new Headers(init.headers).forEach((value,key)=>xhr.setRequestHeader(key,value));
      xhr.upload.onprogress=event=>{activity();if(event.lengthComputable)watch?.progress(event.loaded/event.total);};
      xhr.onprogress=activity;
      xhr.onerror=()=>finish(new Error('Нет связи с хранилищем. Проверьте интернет и повторите сохранение.'));
      xhr.onabort=()=>finish(cancelled());
      xhr.onload=()=>{
        const headers=new Headers();
        for(const line of xhr.getAllResponseHeaders().trim().split(/[\r\n]+/)){
          const colon=line.indexOf(':');if(colon>0)headers.append(line.slice(0,colon),line.slice(colon+1).trim());
        }
        if(!xhr.status){finish(new Error('Нет связи с хранилищем.'));return;}
        finish(undefined,new Response(xhr.status===204?null:xhr.responseText,{status:xhr.status,statusText:xhr.statusText,headers}));
      };
      signals.forEach(s=>s.addEventListener('abort',abort,{once:true}));
      if(signals.some(s=>s.aborted)){abort();return;}
      activity();xhr.send(init.body as XMLHttpRequestBodyInit|null|undefined);
    });
  }
}
