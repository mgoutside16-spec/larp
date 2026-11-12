import type {SaveProgress} from './transfers';
import './style.css';
import './template-panel.css';
import './account.css';
import {mountTemplatePanel} from './template-panel';
import {Storage,stageMedia,type WorkshopStorage} from './storage';
import { importPackage, makePackage, readPackage, mime, makePublication, markPublished } from './packages';
import { download, excel, pdf, types, locationName } from './exports';
import { type Asset, type Block, type Game, type Kind, type Material, KINDS } from './types';
import { escapeHtml as e, safeHtml } from './richtext';
import { icon } from './icons';
import {prepareForPlayers,desktop,compressionEnabled,setCompression} from './compress';

const app=document.querySelector<HTMLDivElement>('#app')!;
let store:WorkshopStorage,game:Game|null=null,games:Game[]=[],page='materials',query='',location='all',sort='modified',direction=-1,editorDirty=false;
interface LocalRuntime{identity:{user_id:string;email:string;display_name:string;is_admin:boolean}}
let account:LocalRuntime|null=null,templateDispose:(()=>void)|undefined,templateTicket=0;
const publishing=false;
const templateDirty=()=>{const panel=document.querySelector<HTMLElement>('#template-panel');return panel?.dataset.dirty==='true'||panel?.dataset.busy==='true';};
const hasWork=()=>publishing||editorDirty||templateDirty()||!!document.querySelector('dialog[open]')||!!document.activeElement?.matches('input,textarea,select,[contenteditable=true]');
const channel=typeof BroadcastChannel!=='undefined'?new BroadcastChannel('larp-studio-updates'):null;
const $=<T extends HTMLElement=HTMLElement>(selector:string,root:ParentNode=document)=>root.querySelector<T>(selector)!;
const btn=(text:string,action:string,kind='',ico='')=>`<button type="button" class="button ${kind}" data-action="${action}">${ico?icon(ico):''}${text}</button>`;
const date=(value:string)=>new Date(value).toLocaleString('ru-RU',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'});
let toastTimer:ReturnType<typeof setTimeout>;
function toast(message:string,error=false){const box=$('#toast');box.textContent=message;box.className=error?'visible error':'visible';clearTimeout(toastTimer);toastTimer=setTimeout(()=>box.className='',error?9000:5000);}
async function perform(action:()=>Promise<unknown>){try{await action();}catch(error){toast(error instanceof Error?error.message:'Не удалось выполнить действие. Повторите попытку.',true);}}
async function refresh(background=false){const source=store,rows=await source.list();if(source!==store||!account||(background&&hasWork()))return;games=rows;game=games.find(g=>g.id===game?.id)||games[0]||null;render();}
async function changed(){channel?.postMessage(game?.id);await refresh();}
function needGame():Game{if(!game)throw new Error('Сначала создайте или откройте игру.');return game;}

function render(){
  if(!account)return;
  templateDispose?.();templateDispose=undefined;templateTicket++;
  app.innerHTML=`<aside class="sidebar">
    <a class="brand brand-long" href="#" aria-label="Мир Снов для Граней">${icon('layers')}<span>Мир Снов<span class="brand-light"> для Граней</span></span></a>
    <p class="brand-caption">Мастерская ролевых игр</p>
    <nav aria-label="Разделы мастерской">${[
      ['overview','folder','Игровые проекты'],['materials','file','Материалы'],['groups','layers','Группы'],
      ['print','print','Коды и печать'],['builds','box','Сборки и версии'],
    ].map(([id,ico,label])=>`<button type="button" data-page="${id}" class="nav-item ${page===id?'active':''}">${icon(ico)}${label}${id==='materials'&&game?`<span class="nav-count">${game.records.length}</span>`:''}</button>`).join('')}</nav>
    <div class="sidebar-bottom"><button type="button" class="nav-item ${page==='help'?'active':''}" data-page="help">${icon('help')}О мастерской и данных</button><div class="brand-group"><img src="${new URL(`${import.meta.env.BASE_URL}brand/bez-pravil.png`,window.location.href).href}" alt="Эмблема Без правил"><div><strong>Без правил</strong><small>Мастерская группа</small></div></div><div class="version">Мир Снов для Граней <span>1.1.0</span></div></div>
  </aside><div class="workspace"><header class="topbar"><div class="game-switch"><label for="project-switch">Текущая игра</label><select id="project-switch" aria-label="Текущая игра">${!games.length?'<option>Создайте первый проект</option>':games.map(g=>`<option value="${g.id}" ${game?.id===g.id?'selected':''}>${e(g.name)}</option>`).join('')}</select></div>${btn('Новый проект','new-project','secondary','plus')}</header>
    <main id="content"></main><footer class="workspace-footer"><span>${icon('lock')}Игры хранятся на этом компьютере</span><button type="button" data-page="help">О данных и резервных копиях</button></footer></div>`;
  $('#project-switch').addEventListener('change',()=>perform(async()=>{if(templateDirty()&&!await confirmAction('Сменить проект?','Есть несохранённые изменения шаблона или выгрузка ещё готовится.','Переключить')){$<HTMLSelectElement>('#project-switch').value=game?.id||'';return;}game=await store.game($<HTMLSelectElement>('#project-switch').value);query='';location='all';await store.preference('last-game',game.id);render();}));
  renderPage();
}

function heading(title:string,description:string,actions=''){return `<div class="page-heading"><div><h1>${title}</h1><p>${description}</p></div><div class="page-actions">${actions}</div></div>`;}
function renderPage(){
  templateDispose?.();templateDispose=undefined;const ticket=++templateTicket;
  const content=$('#content');
  if(page==='help'){content.innerHTML=helpPage();return;}
  if(!game){content.innerHTML=`<section class="welcome"><div class="welcome-mark">${icon('layers')}</div><h1>Создайте первую игру</h1><p>Соберите тексты, фотографии, звук и видео.<br>Мастерская выдаст коды и подготовит материалы для полигона.</p><div class="welcome-actions">${btn('Создать игровой проект','new-project','primary','plus')}${btn('Открыть .rpgpack','import','','upload')}</div><div class="welcome-note">Игры и медиа хранятся на этом компьютере, интернет для работы не нужен. Для игроков создайте игровой пакет .rpgpack в разделе «Сборки и версии».</div></section>`;return;}
  if(page==='overview'){content.innerHTML=overviewPage();return;}
  if(page==='groups'){content.innerHTML=locationsPage();return;}
  if(page==='print'){content.innerHTML=printPage()+`<div id="template-panel"></div>`;void perform(async()=>{const dispose=await mountTemplatePanel($('#template-panel'),store,game!.id);if(ticket!==templateTicket)dispose();else templateDispose=dispose;});return;}
  if(page==='builds'){content.innerHTML=buildsPage();return;}
  content.innerHTML=heading('Материалы игры','Каждая запись — находка, история или подсказка для игрока.',btn('Новая запись','new-record','primary','plus'))+
    `<section class="materials-panel"><div class="table-toolbar"><label class="search">${icon('search')}<input id="search" type="search" placeholder="Название, код или группа" aria-label="Поиск записей" value="${e(query)}"></label><select id="location-filter" aria-label="Фильтр по группе"><option value="all">Все группы</option><option value="none" ${location==='none'?'selected':''}>Без группы</option>${game.locations.map(l=>`<option value="${l.id}" ${location===String(l.id)?'selected':''}>${e(l.name)}</option>`).join('')}</select><span id="record-count" class="record-count"></span></div><div class="table-scroll"><table class="records"><thead><tr>${[['code','Код'],['title','Название записи'],['location','Группа'],['types','Материалы'],['modified','Изменено']].map(([key,label])=>`<th><button type="button" data-sort="${key}">${label}${sort===key?` <span>${direction===1?'↑':'↓'}</span>`:''}</button></th>`).join('')}<th><span class="sr-only">Действия</span></th></tr></thead><tbody id="record-rows"></tbody></table></div><div id="table-empty"></div></section><div class="storage-note">${icon('check')}<div><strong>Работайте в своём темпе.</strong> Проекты сохраняются в аккаунте, доступны на других компьютерах и участникам команды. <button type="button" data-action="package">Скачать резервную копию</button></div></div>`;
  $('#search').addEventListener('input',()=>{query=$<HTMLInputElement>('#search').value;renderRows();});
  $('#location-filter').addEventListener('change',()=>{location=$<HTMLSelectElement>('#location-filter').value;renderRows();});renderRows();
}

function renderRows(){
  const g=needGame(),q=query.trim().toLocaleLowerCase('ru'),rows=g.records.filter(r=>{
    const loc=locationName(g,r);return `${r.code} ${r.title} ${loc}`.toLocaleLowerCase('ru').includes(q)
      &&(location==='all'||location==='none'&&r.location_id===null||String(r.location_id)===location);
  }).sort((a,b)=>{
    const value=(r:Material)=>sort==='location'?locationName(g,r):sort==='types'?types(r).join(','):String(r[sort as keyof Material]??'');
    return value(a).localeCompare(value(b),'ru')*direction;
  });
  $('#record-count').textContent=`${rows.length} из ${g.records.length}`;
  $('#record-rows').innerHTML=rows.map(r=>`<tr data-record="${r.id}"><td><button type="button" class="code-pill" data-action="copy-code" data-id="${r.id}" title="Скопировать код ${r.code}">${r.code}${icon('copy')}</button></td><td><button type="button" class="record-title" data-action="edit-record" data-id="${r.id}">${e(r.title)}</button><span class="block-count">${r.blocks.length} ${plural(r.blocks.length,'блок','блока','блоков')}</span></td><td>${r.location_id!==null?`<span class="location-name">${icon('pin')}${e(locationName(g,r))}</span>`:'<span class="muted">Без группы</span>'}</td><td><div class="badges">${types(r).length?types(r).map(t=>`<span class="badge">${t}</span>`).join(''):'<span class="muted">Нет блоков</span>'}</div></td><td class="date-cell">${date(r.modified)}</td><td class="row-actions"><button type="button" class="icon-button" data-action="preview" data-id="${r.id}" title="Предпросмотр" aria-label="Предпросмотр ${e(r.title)}">${icon('eye')}</button><button type="button" class="icon-button" data-action="delete-record" data-id="${r.id}" title="Удалить запись" aria-label="Удалить ${e(r.title)}">${icon('trash')}</button></td></tr>`).join('');
  $('#table-empty').innerHTML=rows.length?'':`<div class="empty-table">${icon('file')}<h2>${g.records.length?'Ничего не найдено':'Добавьте первый материал'}</h2><p>${g.records.length?'Измените запрос или выберите другую группу.':'Создайте запись, добавьте содержимое — код появится автоматически.'}</p>${g.records.length?'':btn('Новая запись','new-record','primary','plus')}</div>`;
}

function plural(n:number,one:string,few:string,many:string){const v=n%100;return v>=11&&v<=14?many:n%10===1?one:n%10>=2&&n%10<=4?few:many;}
function overviewPage(){const g=needGame(),canManage=true;return heading('Игровые проекты','Каждая игра — отдельный набор материалов, групп и постоянных кодов.',btn('Импортировать .rpgpack','import','','upload'))+
  `<div class="project-grid">${games.map(p=>`<article class="project-card ${p.id===g.id?'current':''}"><div class="project-card-top">${icon('folder')}<span>Игровой проект</span></div><h2>${e(p.name)}</h2><p>${e(p.description||'Описание пока не добавлено.')}</p><div class="project-meta"><span>${p.records.length} ${plural(p.records.length,'запись','записи','записей')}</span><span>${p.locations.length} ${plural(p.locations.length,'группа','группы','групп')}</span></div><div class="project-card-actions"><button type="button" class="button ${p.id===g.id?'secondary':'primary'}" data-action="open-project" data-id="${p.id}">${p.id===g.id?'К материалам':'Открыть'}</button>${p.id===g.id?`${btn('Параметры','edit-project','quiet')}${btn('Копия','copy-project','quiet')}`:''}</div></article>`).join('')}<button type="button" class="new-project-card" data-action="new-project">${icon('plus')}<strong>Новый проект</strong><span>Для следующей истории</span></button></div>${canManage?`<div class="section-bottom">${btn('Удалить текущий проект','delete-project','text-danger','trash')}</div>`:''}`;}
function locationsPage(){const g=needGame();return heading('Группы','Разделяйте видения по типам: сны, ЭП и другие группы вашего проекта.',btn('Добавить группу','add-group','primary','plus'))+
  `<div class="locations-list">${g.locations.map(l=>`<article class="location-row"><div class="location-symbol">${icon('pin')}</div><div><h2>${e(l.name)}</h2><p>${g.records.filter(r=>r.location_id===l.id).length} ${plural(g.records.filter(r=>r.location_id===l.id).length,'запись','записи','записей')}</p></div><div class="location-actions"><button type="button" class="button quiet" data-action="rename-group" data-id="${l.id}">Переименовать</button><button type="button" class="icon-button" data-action="delete-group" data-id="${l.id}" aria-label="Удалить группу ${e(l.name)}">${icon('trash')}</button></div></article>`).join('')||'<div class="empty-table"><h2>Какие видения получат игроки?</h2><p>Добавьте группы, например «Сны» или «ЭП».</p></div>'}</div>`;}
function printPage(){const g=needGame();return heading('Коды и печать','Подготовьте карточки для полигона и список материалов для мастерской.')+
  `<div class="export-grid"><section class="export-option"><div class="export-symbol">${icon('print')}</div><h2>Карточки для полигона</h2><p>Крупный пятизначный код. Восемь карточек на листе A4, сгруппированных по группам.</p><div class="sample-card"><span>Пример карточки</span><strong>${g.records[0]?.code||'12345'}</strong><small>Пять цифр — одна находка</small></div><label class="checkbox"><input type="checkbox" id="pdf-title">Печатать название записи</label><label class="checkbox"><input type="checkbox" id="pdf-location">Печатать группу</label><p class="small muted">Названия могут содержать спойлеры. По умолчанию печатается только код.</p>${btn('Скачать карточки PDF','pdf','primary','download')}</section><section class="export-option"><div class="export-symbol">${icon('file')}</div><h2>Список для мастерской</h2><p>Все коды, названия, группы и типы материалов в таблице Excel. Удобно распределять и проверять раскладку.</p><div class="sheet-example"><div>Код<span>Название</span></div>${g.records.slice(0,3).map(r=>`<div><b>${r.code}</b><span>${e(r.title)}</span></div>`).join('')||'<div><b>12345</b><span>Название записи</span></div>'}</div>${btn('Скачать таблицу Excel','excel','','download')}</section></div>`;}
function buildsPage(){const g=needGame();return heading('Сборки и версии','Игровой пакет .rpgpack — это вся игра одним файлом: для игроков и для резервной копии.',btn('Создать игровой пакет','package','primary','box'))+
  publishPanel(g)+`<section class="package-intro"><div class="package-symbol">${icon('download')}</div><div><h2>${desktop()?'Запасной способ: файл игры':'Как передать игру игрокам'}</h2><p>Нажмите «Создать игровой пакет» и отправьте файл .rpgpack игрокам любым способом: мессенджер, облачный диск, флешка. В приложении игрока: «Импортировать» → выбрать файл. После этого игра работает без интернета. Если вы изменили материалы, создайте новый пакет и разошлите его снова — коды не меняются.</p><div class="inline-actions"><a class="button primary" href="https://mgoutside16-spec.github.io/larp/games/app/Mir-Snov-arm64.apk">${icon('download')}Приложение игрока · 22 МБ</a><a class="button" href="https://mgoutside16-spec.github.io/larp/games/app/Mir-Snov.apk">Совместимая версия для старых телефонов</a></div><div class="player-qr"><img src="${import.meta.env.BASE_URL}player/qr-download.png" width="180" height="180" alt="QR-код для скачивания приложения игрока"><div><strong>Скачать на телефон</strong><p>Наведите камеру телефона. Код остаётся прежним после обновлений.</p><a href="https://mgoutside16-spec.github.io/larp/player/">Страница скачивания</a> · <a href="${import.meta.env.BASE_URL}player/qr-download.png" download="LARP-QR.png">Скачать QR-код</a></div></div></div></section>`+
  (desktop()?`<section class="package-intro"><div class="package-symbol">${icon('video')}</div><div><h2>Уменьшить материалы для телефонов</h2><p>Сожмёт уже добавленные видео, большие картинки и WAV в этой игре: видео — до 720p. Коды и тексты не меняются. Новые файлы сжимаются автоматически при добавлении, если включена галочка в окне записи.</p><div class="inline-actions">${btn('Сжать материалы игры','compress-all','','video')}</div></div></section>`:'')+
  `<section class="package-intro"><div class="package-symbol">${icon('box')}</div><div><h2>Одна игра — один .rpgpack</h2><p>Тексты, медиа, группы и коды. Пакет подходит для резервной копии и переноса на другое устройство.</p><div class="inline-actions">${btn('Импортировать пакет','import','','upload')}${btn('Проверить пакет','check-package','quiet','check')}</div></div></section><h2 class="section-title">История сборок <span>${g.builds.length}</span></h2><section class="materials-panel"><div class="table-scroll"><table><thead><tr><th>Версия</th><th>Создана</th><th>Файл</th></tr></thead><tbody>${g.builds.map(b=>`<tr><td><span class="version-badge">v${b.version}</span></td><td>${date(b.created)}</td><td>${e(b.filename)}</td></tr>`).join('')}</tbody></table></div>${g.builds.length?'':'<div class="empty-table"><h2>Первая сборка ещё впереди</h2><p>Когда материалы готовы, создайте игровой пакет.</p></div>'}</section><p class="page-footnote">Импорт открывается отдельным проектом. Текущая игра сохраняется. Файл .rpgpack также можно открыть в приложении игрока без сети.</p>`;}
type DesktopPublish={githubStatus():Promise<{connected:boolean;site:string}>;githubConnect(token:string):Promise<boolean>;githubDisconnect():Promise<boolean>;publish(pub:unknown,onProgress:(p:{stage:string;percent:number})=>void):Promise<{version:number;live:boolean}>};
const bridge=()=>(window as unknown as {larpDesktop?:DesktopPublish}).larpDesktop;
let github:{connected:boolean;site:string}|null=null,publishStage='';
const TOKEN_URL='https://github.com/settings/personal-access-tokens/new?name=Mir+Snov+publish&description=%D0%9F%D1%83%D0%B1%D0%BB%D0%B8%D0%BA%D0%B0%D1%86%D0%B8%D1%8F+%D0%B8%D0%B3%D1%80+%C2%AB%D0%9C%D0%B8%D1%80+%D0%A1%D0%BD%D0%BE%D0%B2%C2%BB&target_name=mgoutside16-spec&expires_in=366&contents=write';
function publishPanel(g:Game){
  if(!desktop())return '';
  const last=g.builds.find(b=>b.filename==='Опубликовано для игроков');
  const body=!github?.connected
    ?`<p>Чтобы игроки получали игру и обновления через интернет, один раз подключите GitHub. После этого достаточно нажимать «Опубликовать».</p><div class="inline-actions">${btn('Подключить GitHub','github-connect','primary','lock')}</div>`
    :`<p>Нажмите «Опубликовать», когда материалы готовы. Приложения игроков сами скачают игру при подключении к интернету, обычно через 2–5 минут после публикации. После скачивания игра работает без интернета.</p>${last?`<p class="small muted">Последняя публикация: версия ${last.version}, ${date(last.created)}.</p>`:'<p class="small muted">Эта игра ещё не публиковалась.</p>'}<div class="inline-actions"><button type="button" class="button primary" data-action="publish" ${publishStage?'disabled':''}>${icon('upload')}${publishStage?'Публикуем…':'Опубликовать для игроков'}</button>${btn('Отключить GitHub','github-disconnect','quiet')}</div>${publishStage?`<p class="small" id="publish-stage">${e(publishStage)}</p>`:''}<p class="small muted">Веб-версия для iPhone: <a href="https://mgoutside16-spec.github.io/larp/play/" target="_blank">mgoutside16-spec.github.io/larp/play</a></p>`;
  return `<section class="package-intro"><div class="package-symbol">${icon('upload')}</div><div><h2>Публикация для игроков через интернет</h2>${body}</div></section>`;
}
function githubDialog(){
  const d=dialog(`<form class="dialog-form"><div class="dialog-heading"><h2>Подключить GitHub</h2></div><p>Нужен ключ доступа к вашему репозиторию <b>larp</b>. Делается один раз.</p><ol class="help-steps"><li>Откройте <a href="${TOKEN_URL}" target="_blank">страницу создания ключа на GitHub</a> и войдите в аккаунт.</li><li>В разделе <b>Repository access</b> выберите <b>Only select repositories</b> и отметьте <b>larp</b>.</li><li>Проверьте, что в разделе <b>Permissions</b> указано <b>Contents: Read and write</b>.</li><li>Нажмите внизу зелёную кнопку <b>Generate token</b> и скопируйте ключ (начинается с <code>github_pat_</code>).</li><li>Вставьте ключ сюда.</li></ol><label class="field">Ключ GitHub<input name="token" required autocomplete="off" placeholder="github_pat_…"></label><p class="small muted">Ключ хранится зашифрованным на этом компьютере. Срок действия — год, потом ключ нужно будет создать заново.</p><p class="dialog-error" role="alert"></p><div class="dialog-actions"><button type="button" class="button" data-cancel>Отмена</button><button class="button primary" type="submit">Подключить</button></div></form>`);
  $('[data-cancel]',d).addEventListener('click',()=>d.close());
  $('form',d).addEventListener('submit',async event=>{event.preventDefault();const submit=$<HTMLButtonElement>('[type=submit]',d);submit.disabled=true;$('.dialog-error',d).textContent='Проверяем ключ…';
    try{await bridge()!.githubConnect($<HTMLInputElement>('[name=token]',d).value);github=await bridge()!.githubStatus();d.close();render();toast('GitHub подключён. Теперь можно публиковать игру.');}
    catch(error){$('.dialog-error',d).textContent=((error as Error).message||'').replace(/^Error invoking remote method '[^']+': (Error: )?/,'');submit.disabled=false;}});
}
async function publishGame(g:Game){
  if(publishStage)return;
  publishStage='Готовим материалы…';render();
  try{
    const pub=await makePublication(store,g.id);
    const result=await bridge()!.publish(pub,p=>{publishStage=p.stage;const el=document.querySelector('#publish-stage');if(el)el.textContent=p.stage;});
    await markPublished(store,g.id,result.version,new Date().toISOString());
    publishStage='';await changed();
    toast(result.live?`Версия ${result.version} опубликована. Игроки получат её при подключении к интернету.`:`Версия ${result.version} отправлена. Сайт ещё обновляется — игроки получат её в течение нескольких минут.`);
  }catch(error){publishStage='';render();throw new Error(((error as Error).message||'').replace(/^Error invoking remote method '[^']+': (Error: )?/,'')||'Не удалось опубликовать игру.');}
}
function helpPage(){return heading('Мастерская «Без правил»','Подготовка игр, кодов и материалов для полигона.')+`<article class="help-content"><h2>Где хранятся игры</h2><p>Все проекты, медиа, группы и шаблоны карточек хранятся на этом компьютере. Интернет для работы не нужен. Обновление программы игры не удаляет.</p><h2>Резервная копия</h2><p>В разделе «Сборки и версии» создайте .rpgpack и сохраните его в двух местах, например на флешке и в облачном диске. Шаблоны печатных карточек в пакет не входят: сохраните исходные изображения карточек отдельно.</p><h2>Сжатие материалов</h2><p>${desktop()?'При добавлении видео, звука и картинок мастерская уменьшает их размер для телефонов: видео — до 720p, большие изображения — до 2048 пикселей по длинной стороне, WAV — в сжатый звук. Оригиналы на диске не меняются. Переключатель — в окне записи.':'Сжатие видео доступно в программе для Windows.'}</p><h2>Группы видений</h2><p>Создавайте свои группы в каждом проекте: например, «Сны» и «ЭП».</p><h2>Свои карточки для печати</h2><p>В разделе «Коды и печать» загрузите изображение карточки, выберите группу и перетащите код в нужное место. Настройте размер, цвет и шрифт. «Скачать карточки ZIP» создаст отдельные PNG с кодами в исходном разрешении и с отметкой 300 dpi.</p><h2>Постоянные коды</h2><p>Код выдаётся автоматически и не меняется при редактировании. Удалённые коды остаются в истории и не выдаются повторно.</p></article>`;}

function dialog(content:string,className=''):HTMLDialogElement {
  const d=document.createElement('dialog');d.className=className;d.innerHTML=content;document.body.append(d);
  d.addEventListener('close',()=>d.remove(),{once:true});d.showModal();return d;
}
async function confirmAction(title:string,text:string,confirm='Удалить'):Promise<boolean>{return new Promise(resolve=>{
  const d=dialog(`<form class="dialog-form"><div class="dialog-heading"><h2>${e(title)}</h2><button type="button" class="icon-button" data-cancel aria-label="Закрыть">${icon('close')}</button></div><p>${e(text)}</p><div class="dialog-actions"><button type="button" class="button" data-cancel>Отмена</button><button type="submit" class="button danger">${e(confirm)}</button></div></form>`);
  d.addEventListener('close',()=>resolve(false),{once:true});d.querySelectorAll('[data-cancel]').forEach(b=>b.addEventListener('click',()=>d.close()));
  $('form',d).addEventListener('submit',ev=>{ev.preventDefault();resolve(true);d.close();});
});}
function projectDialog(edit=false){
  const current=edit?needGame():null;
  const d=dialog(`<form class="dialog-form"><div class="dialog-heading"><h2>${edit?'Параметры игры':'Новый игровой проект'}</h2><button type="button" class="icon-button" data-cancel aria-label="Закрыть">${icon('close')}</button></div><label class="field">Название игры<input name="name" required autofocus placeholder="Например, «Остров Лафей»" value="${e(current?.name||'')}"></label><label class="field">Описание<textarea name="description" rows="4" placeholder="Заметка для мастеров об этой игре">${e(current?.description||'')}</textarea></label><p class="dialog-error" role="alert"></p><div class="dialog-actions"><button type="button" class="button" data-cancel>Отмена</button><button class="button primary" type="submit">${edit?'Сохранить параметры':'Создать проект'}</button></div></form>`);
  $('[data-cancel]',d).addEventListener('click',()=>d.close());
  $('form',d).addEventListener('submit',async event=>{event.preventDefault();const submit=$<HTMLButtonElement>('[type=submit]',d);submit.disabled=true;try{
    const name=$<HTMLInputElement>('[name=name]',d).value,description=$<HTMLTextAreaElement>('[name=description]',d).value;
    game=current?await store.rename(current.id,name,description):await store.create(name,description);page='materials';query='';location='all';d.close();await changed();toast(edit?'Параметры сохранены.':'Проект создан. Можно добавлять материалы.');
  }catch(error){$('.dialog-error',d).textContent=(error as Error).message;}finally{submit.disabled=false;}});
}
function locationDialog(id?:number){
  const g=needGame(),loc=g.locations.find(l=>l.id===id);
  const d=dialog(`<form class="dialog-form"><div class="dialog-heading"><h2>${loc?'Название группы':'Новая группа'}</h2></div><label class="field">Название<input name="name" required autofocus value="${e(loc?.name||'')}" placeholder="Например, «Сны»"></label><p class="dialog-error" role="alert"></p><div class="dialog-actions"><button type="button" class="button" data-cancel>Отмена</button><button type="submit" class="button primary">Сохранить группу</button></div></form>`);
  $('[data-cancel]',d).addEventListener('click',()=>d.close());$('form',d).addEventListener('submit',async ev=>{ev.preventDefault();try{
    const name=$<HTMLInputElement>('[name=name]',d).value;if(loc)await store.renameGroup(g.id,loc.id,name);else await store.addGroup(g.id,name);d.close();await changed();toast('Группа сохранена.');
  }catch(error){$('.dialog-error',d).textContent=(error as Error).message;}});
}

async function editor(recordId?:string){
  const g=needGame(),row=recordId?g.records.find(r=>r.id===recordId):undefined;
  if(recordId&&!row)throw new Error('Запись не найдена.');
  let blocks:Block[]=structuredClone(row?.blocks||[]),pending:Asset[]=[],urls=new Map<string,string>();
  let processing=0,saving=false;
  let saveController:AbortController|undefined,savePhase:SaveProgress['phase']='checking';
  const mediaJobs=new Set<Promise<void>>();
  editorDirty=false;
  const d=dialog(`<form id="editor-form"><div class="editor-heading"><div><p class="eyebrow">Материал игры</p><h2>${row?'Редактировать запись':'Новая запись'}</h2></div><button type="button" class="icon-button" id="editor-close" aria-label="Закрыть редактор">${icon('close')}</button></div><div class="editor-scroll"><div class="editor-meta"><label class="field title-field">Название записи<input id="record-title" required placeholder="Название для мастера" value="${e(row?.title||'')}"></label><label class="field">Группа<select id="record-location"><option value="none">Без группы</option>${g.locations.map(l=>`<option value="${l.id}" ${row?.location_id===l.id?'selected':''}>${e(l.name)}</option>`).join('')}</select></label><div class="permanent-code"><span>Постоянный код</span><strong>${row?.code||'— — — — —'}</strong><small>${row?'Назначен автоматически':'Появится при сохранении'}</small></div></div><div class="blocks-heading"><div><h3>Содержимое записи</h3><p>Игрок увидит материалы в этом порядке.</p></div><span id="blocks-count"></span></div><div id="blocks"></div><div class="add-blocks"><span>Добавить блок</span>${(['text','image','audio','video'] as Kind[]).map(k=>`<button type="button" class="button" data-add="${k}">${icon(k==='text'?'file':k)}${KINDS[k]}</button>`).join('')}</div><div id="dropzone" class="dropzone">${icon('upload')}Можно перетащить фотографии, аудио и видео в это окно.</div><p class="dialog-error" role="alert"></p></div><div id="editor-transfer" class="editor-transfer" role="status" aria-live="polite" hidden><p></p><progress max="100" aria-label="Загрузка файлов"></progress></div><label class="checkbox compress-toggle"><input type="checkbox" id="compress-media" ${compressionEnabled()?'checked':''}>Сжимать новые фото, звук и видео для телефонов</label><div class="editor-footer"><button type="button" class="button" id="editor-preview">${icon('eye')}Предпросмотр</button><div><button type="button" class="button quiet" id="editor-cancel">Отмена</button><button type="submit" class="button primary" id="record-save">Сохранить запись</button></div></div></form>`,'record-editor');
  const flush=()=>d.querySelectorAll<HTMLElement>('[data-rich]').forEach(el=>{blocks[Number(el.dataset.rich)].value=safeHtml(el.innerHTML);});
  const source=async(path:string)=>{if(!urls.has(path)){const asset=pending.find(a=>a.path===path)||await store.media(g.id,path);urls.set(path,URL.createObjectURL(new Blob([asset.blob],{type:asset.mime||mime(path)})));}return urls.get(path)!;};
  async function renderBlocks(){
    $('#blocks-count',d).textContent=String(blocks.length);
    const html=await Promise.all(blocks.map(async(b,i)=>{
      const controls=`<div class="block-controls"><button type="button" class="icon-button" data-move="${i},-1" aria-label="Переместить блок ${i+1} выше" ${i===0?'disabled':''}>↑</button><button type="button" class="icon-button" data-move="${i},1" aria-label="Переместить блок ${i+1} ниже" ${i===blocks.length-1?'disabled':''}>↓</button><button type="button" class="icon-button" data-remove="${i}" aria-label="Удалить блок ${i+1}">${icon('trash')}</button></div>`;
      let body='';
      if(b.kind==='text')body=`<div class="format-toolbar"><button type="button" class="format-button" data-format="bold" title="Жирный"><b>Ж</b></button><button type="button" class="format-button" data-format="italic" title="Курсив"><i>К</i></button><button type="button" class="format-button" data-format="h2">Заголовок</button><button type="button" class="format-button" data-format="p">Абзац</button></div><div contenteditable="true" role="textbox" aria-label="Текст блока ${i+1}" data-rich="${i}" class="rich-editor" data-placeholder="Текст для игрока…">${safeHtml(b.value)}</div>`;
      else {let url='';try{url=await source(b.value);}catch{}body=url?b.kind==='image'?`<img class="block-image" alt="Изображение блока ${i+1}" src="${url}">`:`<${b.kind} class="block-media" controls preload="metadata" src="${url}"></${b.kind}>`:'<p class="dialog-error">Файл не найден. Добавьте его повторно.</p>';}
      return `<section class="content-block" data-index="${i}"><div class="block-heading"><span class="block-number">${String(i+1).padStart(2,'0')}</span><strong>${KINDS[b.kind]}</strong>${controls}</div>${body}</section>`;
    }));
    $('#blocks',d).innerHTML=html.join('')||'<div class="empty-blocks">Начните с текста или добавьте медиафайл.</div>';
  }
  await renderBlocks();
  d.addEventListener('input',()=>editorDirty=true);
  const close=async()=>{if(saving){if(savePhase!=='saving')saveController?.abort();return;}if(!editorDirty||await confirmAction('Закрыть без сохранения?','Последние изменения этой записи не сохранятся.','Закрыть'))d.close();};
  $('#editor-close',d).addEventListener('click',close);$('#editor-cancel',d).addEventListener('click',close);
  d.addEventListener('cancel',ev=>{ev.preventDefault();void close();});
  d.addEventListener('close',()=>{editorDirty=false;urls.forEach(url=>URL.revokeObjectURL(url));d.querySelectorAll<HTMLMediaElement>('audio,video').forEach(el=>el.pause());});
  $<HTMLInputElement>('#compress-media',d).addEventListener('change',ev=>setCompression((ev.target as HTMLInputElement).checked));
  async function addFiles(files:File[]){
    processing++;$<HTMLButtonElement>('#record-save',d).disabled=true;
    flush();$('.dialog-error',d).textContent='Копирование файлов…';
    try{for(const file of files){const type=file.type||mime(file.name),kind:Kind|undefined=type.startsWith('image/')?'image':type.startsWith('audio/')?'audio':type.startsWith('video/')?'video':undefined;if(!kind)throw new Error(`Формат файла «${file.name}» не поддерживается.`);const asset=await stageMedia(await prepareForPlayers(file,kind,message=>{$('.dialog-error',d).textContent=message;if(message.includes('→')||message.startsWith('Не удалось'))toast(message,message.startsWith('Не удалось'));}));pending.push(asset);blocks.push({kind,value:asset.path});editorDirty=true;}flush();await renderBlocks();$('.dialog-error',d).textContent='';}catch(error){$('.dialog-error',d).textContent=(error as Error).message;flush();await renderBlocks();}finally{processing--;$<HTMLButtonElement>('#record-save',d).disabled=saving||processing>0;}
  }
  function queueFiles(files:File[]){if(saving)return;const job=addFiles(files);mediaJobs.add(job);void job.finally(()=>mediaJobs.delete(job));}
  d.addEventListener('dragover',ev=>{ev.preventDefault();$('#dropzone',d).classList.add('dragging');});
  d.addEventListener('dragleave',()=>$('#dropzone',d).classList.remove('dragging'));
  d.addEventListener('drop',ev=>{ev.preventDefault();$('#dropzone',d).classList.remove('dragging');queueFiles([...ev.dataTransfer!.files]);});
  d.addEventListener('paste',ev=>{const target=ev.target as HTMLElement;if(target.isContentEditable){ev.preventDefault();document.execCommand('insertText',false,ev.clipboardData?.getData('text/plain')||'');}});
  d.addEventListener('mousedown',ev=>{if((ev.target as Element).closest('[data-format]'))ev.preventDefault();});
  d.addEventListener('click',ev=>{const target=(ev.target as Element).closest<HTMLElement>('button');if(!target)return;
    if(saving)return;
    if(target.dataset.add){flush();const kind=target.dataset.add as Kind;if(kind==='text'){blocks.push({kind:'text',value:''});editorDirty=true;void renderBlocks();}else{const input=document.createElement('input');input.type='file';input.multiple=true;input.hidden=true;input.accept=`${kind}/*`;input.setAttribute('data-media-picker','');d.append(input);input.addEventListener('change',()=>{queueFiles([...input.files!]);input.remove();});input.click();}}
    if(target.dataset.move){flush();const [index,offset]=target.dataset.move.split(',').map(Number),to=index+offset;if(to>=0&&to<blocks.length){[blocks[index],blocks[to]]=[blocks[to],blocks[index]];editorDirty=true;void renderBlocks();}}
    if(target.dataset.remove){flush();blocks.splice(Number(target.dataset.remove),1);editorDirty=true;void renderBlocks();}
    if(target.dataset.format){const cmd=target.dataset.format;if(cmd==='bold'||cmd==='italic')document.execCommand(cmd);else document.execCommand('formatBlock',false,cmd);editorDirty=true;}
  });
  $('#editor-preview',d).addEventListener('click',()=>perform(async()=>{flush();await preview(blocks,g,pending);}));
  $('#editor-form',d).addEventListener('submit',async ev=>{
    ev.preventDefault();if(saving)return;
    const save=$<HTMLButtonElement>('#record-save',d),cancel=$<HTMLButtonElement>('#editor-cancel',d),
      closeButton=$<HTMLButtonElement>('#editor-close',d),previewButton=$<HTMLButtonElement>('#editor-preview',d),
      area=$<HTMLElement>('.editor-scroll',d),notice=$<HTMLElement>('#editor-transfer',d),
      bar=$<HTMLProgressElement>('progress',notice);
    saving=true;savePhase='checking';saveController=new AbortController();
    save.disabled=true;area.inert=true;previewButton.disabled=true;
    cancel.textContent='Остановить загрузку';notice.hidden=false;bar.hidden=false;
    const progress=(state:SaveProgress)=>{
      savePhase=state.phase;const percentage=state.total?Math.min(100,Math.round(state.loaded/state.total*100)):0;
      const mb=(value:number)=>(value/1024**2).toLocaleString('ru-RU',{maximumFractionDigits:1});
      const label=state.phase==='checking'?'Проверяем запись перед загрузкой…':
        state.phase==='saving'?'Файлы загружены. Сохраняем запись…':
        percentage===100?'Файл передан. Ждём подтверждения хранилища…':
        `Загружаем «${state.name}»: ${mb(state.loaded)} из ${mb(state.total)} МБ (${percentage}%). Не закрывайте вкладку.`;
      $('p',notice).textContent=label;
      if(state.phase==='upload')bar.value=percentage;else bar.removeAttribute('value');
      save.textContent=state.phase==='upload'?'Загружаем файлы…':'Сохраняем…';
      cancel.disabled=closeButton.disabled=state.phase==='saving';
    };
    progress({phase:'checking',loaded:0,total:0});$('.dialog-error',d).textContent='';
    try{
      await Promise.all([...mediaJobs]);flush();
      await store.saveRecord(g.id,{id:row?.id,revision:row?.revision,title:$<HTMLInputElement>('#record-title',d).value,
        location_id:$<HTMLSelectElement>('#record-location',d).value==='none'?null:Number($<HTMLSelectElement>('#record-location',d).value),
        blocks:structuredClone(blocks)},pending,{signal:saveController.signal,onProgress:progress});
      editorDirty=false;d.close();await changed();toast('Запись сохранена.');
    }catch(error){
      const message=(error as Error).message;$('.dialog-error',d).textContent=message;$('p',notice).textContent=message;bar.hidden=true;
    }finally{
      saving=false;saveController=undefined;area.inert=false;save.disabled=processing>0;save.textContent='Сохранить запись';
      cancel.disabled=false;cancel.textContent='Отмена';closeButton.disabled=false;previewButton.disabled=false;
    }
  });
}

async function preview(blocks:Block[],g:Game,pending:Asset[]=[]){
  const urls:string[]=[];
  const html=await Promise.all(blocks.map(async b=>{
    if(b.kind==='text')return `<section class="player-text">${safeHtml(b.value)}</section>`;
    try{const asset=pending.find(a=>a.path===b.value)||await store.media(g.id,b.value),url=URL.createObjectURL(new Blob([asset.blob],{type:asset.mime||mime(b.value)}));urls.push(url);
      return b.kind==='image'?`<img src="${url}" alt="Игровое изображение">`:`<${b.kind} src="${url}" controls preload="metadata"></${b.kind}>`;
    }catch{return '<p class="dialog-error">Медиафайл не найден.</p>';}
  }));
  const d=dialog(`<div class="preview-toolbar"><span>${icon('eye')}Просмотр игрока</span><button type="button" class="icon-button" aria-label="Закрыть предпросмотр">${icon('close')}</button></div><div class="player-content">${html.join('')||'<p>В записи пока нет материалов.</p>'}</div>`,'preview-dialog');
  $('button',d).addEventListener('click',()=>d.close());d.addEventListener('close',()=>{d.querySelectorAll<HTMLMediaElement>('audio,video').forEach(el=>el.pause());urls.forEach(url=>URL.revokeObjectURL(url));});
}

async function pickPackage(checkOnly=false){
  const input=document.createElement('input');input.type='file';input.accept='.rpgpack';input.setAttribute('data-package-picker','');input.hidden=true;document.body.append(input);
  input.addEventListener('cancel',()=>input.remove());input.addEventListener('change',()=>perform(async()=>{try{const file=input.files?.[0];if(!file)return;toast('Проверяем игровой пакет…');const bytes=new Uint8Array(await file.arrayBuffer());if(checkOnly){const {manifest}=await readPackage(bytes);toast(`«${manifest.game.name}», версия ${manifest.version}. Все контрольные суммы совпадают.`);}else{game=await importPackage(store,bytes);page='materials';query='';location='all';await changed();toast('Игра импортирована отдельным проектом.');}}finally{input.remove();}}));input.click();
}

app.addEventListener('click',ev=>{
  const target=(ev.target as Element).closest<HTMLElement>('[data-action],[data-page],[data-sort]');if(!target)return;
  if(target.dataset.page){void perform(async()=>{if(templateDirty()&&!await confirmAction('Перейти в другой раздел?','Есть несохранённые изменения шаблона или выгрузка ещё готовится.','Перейти'))return;page=target.dataset.page!;render();});return;}
  if(target.dataset.sort){if(sort===target.dataset.sort)direction*=-1;else{sort=target.dataset.sort;direction=1;}renderPage();return;}
  void perform(async()=>{
    const id=target.dataset.id,action=target.dataset.action;
    if(action==='new-project'){projectDialog();return;}
    if(action==='edit-project'){projectDialog(true);return;}
    if(action==='import'){await pickPackage();return;}
    if(action==='check-package'){await pickPackage(true);return;}
    if(action==='add-group'){locationDialog();return;}
    if(action==='rename-group'){locationDialog(Number(id));return;}
    if(action==='new-record'){await editor();return;}
    if(action==='edit-record'){await editor(id);return;}
    if(action==='persist'){const persistent=await navigator.storage?.persist?.();toast(persistent?'Браузер выделил постоянное хранилище.':'Браузер принимает это решение автоматически. Продолжайте сохранять резервные пакеты.');return;}
    const g=needGame();
    if(action==='open-project'){game=await store.game(id!);await store.preference('last-game',game.id);page='materials';query='';location='all';render();return;}
    if(action==='copy-project'){game=await store.copy(g.id);await changed();toast('Создана независимая копия игры.');return;}
    if(action==='delete-project'){if(await confirmAction('Удалить игровой проект?',`«${g.name}» и его материалы будут удалены из аккаунта. Сначала скачайте резервную копию, если игра ещё нужна.`)){try{await store.deleteGame(g.id);}catch(error){await refresh();throw error;}game=(await store.list())[0]||null;await changed();toast('Проект удалён.');}return;}
    if(action==='delete-group'){if(await confirmAction('Удалить группу?','Записи сохранятся и перейдут в «Без группы».')){await store.deleteGroup(g.id,Number(id));location='all';await changed();}return;}
    const row=g.records.find(r=>r.id===id);
    if(action==='copy-code'){await navigator.clipboard.writeText(row!.code);toast(`Код ${row!.code} скопирован.`);return;}
    if(action==='preview'){await preview(row!.blocks,g);return;}
    if(action==='delete-record'){if(await confirmAction('Удалить запись?',`«${row!.title}» будет удалена. Код ${row!.code} останется в резерве этой игры.`)){await store.deleteRecord(g.id,id!);await changed();toast('Запись удалена, код сохранён в резерве.');}return;}
    if(action==='compress-all'){target.setAttribute('disabled','');try{await compressGame(g);}finally{target.removeAttribute('disabled');}return;}
    if(action==='github-connect'){githubDialog();return;}
    if(action==='github-disconnect'){if(await confirmAction('Отключить GitHub?','Ключ будет удалён с этого компьютера. Опубликованные игры останутся доступны игрокам.','Отключить')){await bridge()!.githubDisconnect();github=await bridge()!.githubStatus();render();}return;}
    if(action==='publish'){await publishGame(g);return;}
    if(action==='package'){target.setAttribute('disabled','');try{toast('Собираем игровой пакет…');const bytes=await makePackage(store,g.id);await changed();download(bytes,`${g.name}-v${game!.version}.rpgpack`);toast('Пакет подготовлен. Сохраните его в надёжном месте.');}finally{target.removeAttribute('disabled');}return;}
    if(action==='excel'){download(await excel(g),`${g.name}-коды.xlsx`,'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');toast('Таблица подготовлена для скачивания.');return;}
    if(action==='pdf'){download(await pdf(g,$<HTMLInputElement>('#pdf-title').checked,$<HTMLInputElement>('#pdf-location').checked),`${g.name}-карточки.pdf`,'application/pdf');toast('Карточки подготовлены для скачивания.');return;}
  });
});

async function storageInfo(){const estimate=await navigator.storage?.estimate?.();const el=$('#storage-estimate');if(el)el.textContent=estimate?.quota?`Использовано ${((estimate.usage||0)/1024**2).toFixed(1)} МиБ из ${(estimate.quota/1024**3).toFixed(1)} ГиБ, доступных программе.`:'Объём зависит от свободного места на диске.';}
channel?.addEventListener('message',()=>{if(account&&!hasWork())void perform(()=>refresh(true));});
window.addEventListener('beforeunload',event=>{if(editorDirty||templateDirty()){event.preventDefault();event.returnValue='';}});


async function compressGame(g:Game){
  const kinds=new Map<string,Kind>();for(const r of g.records)for(const b of r.blocks)if(b.kind!=='text')kinds.set(b.value,b.kind);
  if(!kinds.size){toast('В этой игре нет медиафайлов.');return;}
  const replaced=new Map<string,Asset>();let before=0,after=0,index=0;
  for(const [path,kind] of kinds){
    index++;const asset=await store.media(g.id,path);
    const file=new File([asset.blob],asset.name&&/\.[a-z0-9]+$/i.test(asset.name)?asset.name:path.split('/').pop()!,{type:asset.mime||mime(path)});
    const out=await prepareForPlayers(file,kind,message=>{if(message)toast(`Файл ${index} из ${kinds.size}. ${message}`);},true);
    if(out!==file&&out.size<file.size){replaced.set(path,await stageMedia(out));before+=file.size;after+=out.size;}
  }
  if(!replaced.size){toast('Все материалы уже достаточно компактны.');return;}
  for(const r of g.records){
    if(!r.blocks.some(b=>replaced.has(b.value)))continue;
    const blocks=r.blocks.map(b=>replaced.has(b.value)?{...b,value:replaced.get(b.value)!.path}:b);
    const assets=[...new Set(r.blocks.filter(b=>replaced.has(b.value)).map(b=>replaced.get(b.value)!))];
    await store.saveRecord(g.id,{id:r.id,title:r.title,location_id:r.location_id,blocks,revision:r.revision},assets);
  }
  await changed();
  const mbs=(n:number)=>(n/1024**2).toFixed(1).replace('.',',');
  toast(`Готово: ${replaced.size} файл(ов), ${mbs(before)} → ${mbs(after)} МБ. Коды не изменились.`);
}

async function start(){
  account={identity:{user_id:'local',email:'',display_name:'Мастер',is_admin:true}};
  try{github=await bridge()?.githubStatus()??null;}catch{github=null;}
  store=await Storage.open('larp-studio');games=await store.list();const last=await store.preference('last-game');game=games.find(g=>g.id===last)||games[0]||null;
  query='';location='all';page='materials';render();
}
void start().catch(error=>{app.innerHTML=`<main class="startup-error"><h1>Не удалось открыть мастерскую</h1><p>${e(error.message)}</p><button class="button primary" onclick="window.location.reload()">Повторить</button></main>`;});
