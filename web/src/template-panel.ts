import { stageMedia, type WorkshopStorage } from './storage';
import { type Asset, type Material, requireValue } from './types';
import { canvasPosition, drawCode, pngWithDpi, validateTemplate, type PrintTemplate } from './print-layout';

export function templateRecords(records:Material[],scope:string):Material[] {
  return records.filter(row=>scope==='all'||(scope==='none'?row.location_id===null:String(row.location_id)===scope))
    .sort((a,b)=>a.code.localeCompare(b.code));
}

export function checkTemplateExportBudget(count:number,width:number,height:number,pngBytes:number):void {
  requireValue(count>0,'В выбранной группе нет записей. Добавьте записи или выберите другую группу.');
  requireValue(count<=500,'За один раз можно выгрузить до 500 карточек. Выберите меньшую группу.');
  // Decoded source, preview and output RGBA buffers, plus ZIP packing copies.
  requireValue(width*height*12+pngBytes*3<=256*1024**2,
    'Выгрузка превысит бюджет памяти 256 МиБ. Уменьшите изображение или выберите меньшую группу.');
}

/** The caller imports template-panel.css once and calls the disposer before replacing the page. */
export async function mountTemplatePanel(root:HTMLElement,store:WorkshopStorage,gameId:string,onSaved?:()=>Promise<void>):Promise<()=>void> {
  let disposed=false,version=0,busy=false,dirty=false;
  let game=await store.game(gameId),scope='all',config:PrintTemplate|undefined,asset:Asset|undefined;
  let image:HTMLImageElement|undefined,imageUrl:string|undefined;
  const events=new AbortController(),urls=new Set<string>(),timers=new Set<ReturnType<typeof setTimeout>>();
  root.classList.add('tpl-panel');
  root.innerHTML=`<div class="tpl-heading"><h2>Карточки по своему шаблону</h2><p>Загрузите фон, поставьте код на нужное место и скачайте отдельную карточку для каждой записи.</p></div>
    <div class="tpl-layout"><div class="tpl-controls">
      <label class="tpl-field">Группы<select class="tpl-scope" aria-label="Группы для карточек"></select></label>
      <label class="tpl-field">Изображение шаблона<input class="tpl-file" type="file" accept="image/png,image/jpeg,image/webp"></label>
      <button class="tpl-example" type="button">Пример «Сновидение»</button>
      <p class="tpl-hint">PNG, JPEG или WebP, от 32 × 32 px, до 40 Мп и 12 000 px по стороне. Используйте исходное изображение для печати. Если цифры шире карточки, их размер уменьшится автоматически.</p>
      <fieldset class="tpl-style"><legend>Оформление кода</legend>
        <label class="tpl-field">Размер цифр, px<input class="tpl-size" type="number" required step="1" min="1" value="37"></label>
        <label class="tpl-field">Цвет<input class="tpl-color" type="color" value="#000000"></label>
        <label class="tpl-field">Шрифт<select class="tpl-font"><option value="sans">Без засечек</option><option value="serif">С засечками</option><option value="mono">Моноширинный</option></select></label>
        <label class="tpl-check"><input class="tpl-bold" type="checkbox" checked> Жирный</label>
      </fieldset>
      <div class="tpl-actions"><button class="tpl-save" type="button">Сохранить шаблон группы</button><button class="tpl-export tpl-primary" type="button">Скачать карточки ZIP</button></div>
      <p class="tpl-summary"></p><p class="tpl-status" role="status" aria-live="polite"></p>
      <p class="tpl-hint">В ZIP — PNG с кодами в исходном разрешении, 300 dpi. До 500 карточек за раз; объём ограничен памятью браузера. Настройки можно проверить и скачать до сохранения.</p>
    </div><div class="tpl-preview"><p class="tpl-empty">Выберите изображение или откройте пример.</p><canvas class="tpl-canvas" hidden tabindex="0" role="img" aria-label="Шаблон карточки. Перетащите код или перемещайте его стрелками."></canvas><p class="tpl-hint">Нажмите на изображение или перетащите код. Стрелки сдвигают код на 1 px, Shift + стрелки — на 10 px.</p></div></div>`;
  const get=<T extends HTMLElement>(selector:string)=>root.querySelector<T>(selector)!;
  const select=get<HTMLSelectElement>('.tpl-scope'),picker=get<HTMLInputElement>('.tpl-file');
  const size=get<HTMLInputElement>('.tpl-size'),color=get<HTMLInputElement>('.tpl-color');
  const font=get<HTMLSelectElement>('.tpl-font'),bold=get<HTMLInputElement>('.tpl-bold');
  const style=get<HTMLFieldSetElement>('.tpl-style'),save=get<HTMLButtonElement>('.tpl-save');
  const exportButton=get<HTMLButtonElement>('.tpl-export'),example=get<HTMLButtonElement>('.tpl-example');
  const canvas=get<HTMLCanvasElement>('.tpl-canvas'),empty=get('.tpl-empty'),summary=get('.tpl-summary'),status=get('.tpl-status');
  select.add(new Option('Все группы','all'));select.add(new Option('Без группы','none'));
  for(const group of game.locations)select.add(new Option(group.name,String(group.id)));
  const revoke=(url:string|undefined)=>{if(url){URL.revokeObjectURL(url);urls.delete(url);}};
  const makeUrl=(blob:Blob)=>{const url=URL.createObjectURL(blob);urls.add(url);return url;};
  const message=(text:string,error=false)=>{if(disposed)return;status.textContent=text;status.classList.toggle('tpl-error',error);};
  const fail=(error:unknown)=>message(error instanceof Error?error.message:'Не удалось выполнить действие. Повторите попытку.',true);
  const rows=()=>templateRecords(game.records,scope);
  const update=()=>{
    if(disposed)return;
    root.dataset.dirty=String(dirty);
    root.dataset.busy=String(busy);
    const ready=!!config&&!!image;
    select.disabled=busy;picker.disabled=busy;example.disabled=busy;style.disabled=busy||!ready;
    save.disabled=busy||!ready;exportButton.disabled=busy||!ready;
    canvas.hidden=!ready;empty.hidden=ready;canvas.setAttribute('aria-disabled',String(busy||!ready));
    const count=rows().length;
    summary.textContent=`Записей для печати: ${count}${config?` · ${config.width} × ${config.height} px · ${(config.width/300*25.4).toFixed(1)} × ${(config.height/300*25.4).toFixed(1)} мм при 300 dpi`:''}${dirty?' · Есть несохранённые изменения':''}`;
  };
  const render=()=>{
    if(disposed||!config||!image)return;
    drawCode(canvas,image,config,rows()[0]?.code||'12345');
    canvas.setAttribute('aria-label',`Предпросмотр карточки с кодом ${rows()[0]?.code||'12345'}. Перемещайте код мышью или стрелками.`);
  };
  const syncStyle=()=>{if(config){size.min=String(Math.ceil(config.height*.005));size.max=String(Math.floor(config.height*.5));size.value=String(Math.round(config.height*config.fontSize));color.value=config.color;font.value=config.font;bold.checked=config.bold;}};
  const changed=()=>{dirty=true;message('');render();update();};
  const decode=async(blob:Blob)=>{
    const url=makeUrl(blob),next=new Image();
    try{await new Promise<void>((resolve,reject)=>{next.onload=()=>resolve();next.onerror=()=>reject(new Error('Не удалось открыть изображение. Выберите исправный PNG, JPEG или WebP.'));next.src=url;});}
    catch(error){revoke(url);throw error;}
    finally{next.onload=null;next.onerror=null;}
    if(disposed){revoke(url);throw new Error('Просмотр закрыт.');}
    return {next,url};
  };
  const replaceImage=async(nextAsset:Asset,saved?:PrintTemplate,token=version)=>{
    const decoded=await decode(nextAsset.blob);
    try{
      const nextConfig:PrintTemplate=saved?{...saved}:{imagePath:nextAsset.path,width:decoded.next.naturalWidth,height:decoded.next.naturalHeight,x:.52,y:.196,fontSize:.04,color:'#000000',font:'sans',bold:true};
      validateTemplate(nextConfig);
      requireValue(nextConfig.width===decoded.next.naturalWidth&&nextConfig.height===decoded.next.naturalHeight,'Размеры сохранённого шаблона не совпадают с изображением. Загрузите фон заново.');
      if(disposed||token!==version){revoke(decoded.url);return false;}
      revoke(imageUrl);imageUrl=decoded.url;image=decoded.next;config=nextConfig;asset=nextAsset;
      syncStyle();render();return true;
    }catch(error){revoke(decoded.url);throw error;}
  };
  const loadScope=async()=>{
    const token=++version;busy=true;config=undefined;image=undefined;asset=undefined;dirty=false;revoke(imageUrl);imageUrl=undefined;
    message('Загрузка шаблона…');update();
    try{
      const latest=await store.game(gameId);if(disposed||token!==version)return;game=latest;
      const saved=game.printTemplates?.[scope]||game.printTemplates?.all;
      if(saved){const source=await store.media(gameId,saved.imagePath);if(disposed||token!==version)return;await replaceImage(source,saved,token);}
      if(disposed||token!==version)return;
      message(saved?(game.printTemplates?.[scope]?'Шаблон группы загружен.':'Используется общий шаблон. Сохраните изменения, чтобы задать шаблон этой группе.'):'Загрузите изображение для этой группы или откройте пример.');
    }catch(error){if(token===version)fail(error);}
    finally{if(!disposed&&token===version){busy=false;update();}}
  };
  const chooseFile=async(file:File)=>{
    const token=++version;busy=true;message('Открываю изображение…');update();
    try{
      requireValue(['image/png','image/jpeg','image/webp'].includes(file.type),'Выберите PNG, JPEG или WebP.');
      const staged=await stageMedia(file);if(disposed||token!==version)return;
      if(await replaceImage(staged,undefined,token)){dirty=true;message('Изображение открыто. Переместите код на нужное место.');}
    }catch(error){if(token===version)fail(error);}
    finally{if(!disposed&&token===version){busy=false;picker.value='';update();}}
  };
  select.addEventListener('change',()=>{
    if(dirty&&!window.confirm('В шаблоне есть несохранённые изменения. Переключить группу и сбросить их?')){select.value=scope;return;}
    scope=select.value;void loadScope();
  },{signal:events.signal});
  picker.addEventListener('change',()=>{if(picker.files?.[0])void chooseFile(picker.files[0]);},{signal:events.signal});
  example.addEventListener('click',async()=>{
    busy=true;message('Загружаю пример…');update();const token=++version;
    try{
      const response=await fetch(new URL(`${import.meta.env.BASE_URL}templates/snovidenie.png`,location.href),{signal:events.signal});
      requireValue(response.ok,'Не удалось загрузить пример. Загрузите свой шаблон или повторите попытку.');
      const blob=await response.blob();if(disposed||token!==version)return;
      await chooseFile(new File([blob],'snovidenie.png',{type:'image/png'}));
    }catch(error){if(!disposed&&token===version){fail(error);busy=false;update();}}
  },{signal:events.signal});
  size.addEventListener('input',()=>{
    if(!config||busy)return;
    if(!size.checkValidity()||!Number.isFinite(size.valueAsNumber))return;
    config.fontSize=size.valueAsNumber/config.height;changed();
  },{signal:events.signal});
  color.addEventListener('input',()=>{if(config&&!busy){config.color=color.value;changed();}},{signal:events.signal});
  font.addEventListener('change',()=>{if(config&&!busy){config.font=font.value as PrintTemplate['font'];changed();}},{signal:events.signal});
  bold.addEventListener('change',()=>{if(config&&!busy){config.bold=bold.checked;changed();}},{signal:events.signal});
  let dragging:number|undefined;
  const move=(event:PointerEvent)=>{if(!config||busy)return;Object.assign(config,canvasPosition(event.clientX,event.clientY,canvas.getBoundingClientRect()));changed();};
  canvas.addEventListener('pointerdown',event=>{if(busy||!config||!event.isPrimary||event.button!==0)return;dragging=event.pointerId;canvas.setPointerCapture(event.pointerId);canvas.focus();move(event);},{signal:events.signal});
  canvas.addEventListener('pointermove',event=>{if(dragging===event.pointerId)move(event);},{signal:events.signal});
  for(const name of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(name,()=>{dragging=undefined;},{signal:events.signal});
  canvas.addEventListener('keydown',event=>{
    if(busy||!config||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key))return;
    event.preventDefault();const step=event.shiftKey?10:1;
    config.x=Math.min(1,Math.max(0,config.x+(event.key==='ArrowLeft'?-step:event.key==='ArrowRight'?step:0)/config.width));
    config.y=Math.min(1,Math.max(0,config.y+(event.key==='ArrowUp'?-step:event.key==='ArrowDown'?step:0)/config.height));changed();
  },{signal:events.signal});
  save.addEventListener('click',async()=>{
    if(busy||!config||!image)return;
    if(!size.reportValidity())return;
    busy=true;message('Сохраняю шаблон…');update();
    try{game=await store.savePrintTemplate(gameId,scope,{...config},asset);if(disposed)return;dirty=false;message('Шаблон группы сохранён.');await onSaved?.();}
    catch(error){fail(error);}
    finally{if(!disposed){busy=false;update();}}
  },{signal:events.signal});
  exportButton.addEventListener('click',async()=>{
    if(busy||!config||!image)return;
    if(!size.reportValidity())return;
    busy=true;message('Подготовка карточек…');update();
    const snapshot={...config},source=image,output=document.createElement('canvas');
    try{
      game=await store.game(gameId);if(disposed)return;
      const selected=rows();checkTemplateExportBudget(selected.length,snapshot.width,snapshot.height,0);
      const files:Record<string,Uint8Array>={};let bytes=0;
      for(let index=0;index<selected.length;index++){
        if(disposed)return;
        drawCode(output,source,snapshot,selected[index].code);
        const blob=await new Promise<Blob>((resolve,reject)=>output.toBlob(value=>value?resolve(value):reject(new Error('Браузер не смог создать PNG. Уменьшите размер шаблона.')),'image/png'));
        if(disposed)return;
        // Check before allocating another encoded buffer; never silently omit a card.
        checkTemplateExportBudget(selected.length,snapshot.width,snapshot.height,bytes+blob.size+21);
        const png=pngWithDpi(new Uint8Array(await blob.arrayBuffer()));bytes+=png.length;files[`${selected[index].code}.png`]=png;
        message(`Готовлю карточки: ${index+1} из ${selected.length}…`);
        await new Promise<void>(resolve=>setTimeout(resolve,0));
      }
      output.width=0;output.height=0;
      message('Собираю ZIP…');const {zip}=await import('fflate');if(disposed)return;
      const archive=await new Promise<Uint8Array>((resolve,reject)=>zip(files,{level:0},(error,data)=>error?reject(error):resolve(data)));
      if(disposed)return;
      const url=makeUrl(new Blob([new Uint8Array(archive)],{type:'application/zip'})),link=document.createElement('a');
      link.href=url;link.download=`карточки-${scope==='all'?'все':scope==='none'?'без-группы':`группа-${scope}`}.zip`;link.click();
      const timer=setTimeout(()=>{revoke(url);timers.delete(timer);},60000);timers.add(timer);
      message(`ZIP готов: ${selected.length} карточек PNG, 300 dpi. Загрузка началась.`);
    }catch(error){fail(error);}
    finally{output.width=0;output.height=0;if(!disposed){busy=false;update();}}
  },{signal:events.signal});
  await loadScope();
  return ()=>{disposed=true;version++;events.abort();for(const timer of timers)clearTimeout(timer);for(const url of urls)URL.revokeObjectURL(url);urls.clear();canvas.width=0;canvas.height=0;image=undefined;asset=undefined;};
}
