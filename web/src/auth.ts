import {Transfers} from './transfers';
import {createClient,type Session} from '@supabase/supabase-js';
import {AccountService,CloudStorage,type Identity} from './cloud-storage';
import {validateBackendConfig,authMessage} from './auth-config';
import {escapeHtml as e} from './richtext';
import './account.css';

export interface AccountRuntime {identity:Identity;service:AccountService;store:CloudStorage;logout:()=>Promise<void>}

export async function startAccounts(onReady:(runtime:AccountRuntime)=>Promise<void>,onLogout:()=>void) {
  const root=document.querySelector<HTMLElement>('#app')!;
  const base=new URL(import.meta.env.BASE_URL,location.href),logo=new URL('brand/bez-pravil.png',base).href;
  const loading=(message:string)=>{root.innerHTML=`<section class="auth-shell"><div class="auth-card"><img class="auth-logo" src="${logo}" alt="Без правил"><h1>Без правил</h1><p>${e(message)}</p></div></section>`;};
  loading('Открываем личный кабинет…');
  const response=await fetch(new URL('config.json',base),{cache:'no-store'});
  if(!response.ok)throw new Error('Не удалось загрузить подключение к мастерской.');
  const config=validateBackendConfig(await response.json());
  const transfers=new Transfers();
  const client=createClient(config.supabaseUrl,config.supabasePublishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true},global:{fetch:transfers.fetch}});
  const service=new AccountService(client);
  let current:AccountRuntime|undefined,pendingUser='',generation=0,mode:'login'|'signup'|'recover'|'reset'='login';

  function form(message='',error=false){
    const recovery=mode==='recover',reset=mode==='reset',signup=mode==='signup';
    root.innerHTML=`<section class="auth-shell"><div class="auth-intro"><img src="${logo}" alt="Эмблема Без правил"><h1>Без правил</h1><p>Мастерская историй,<br>которые становятся игрой.</p><span>LARP Studio</span></div><div class="auth-card"><span class="auth-overline">Личный кабинет мастерской</span><h2>${signup?'Создать аккаунт':recovery?'Восстановить пароль':reset?'Новый пароль':'Вход в мастерскую'}</h2><p class="auth-caption">${signup?'Ваши проекты и совместная работа с командой.':recovery?'Отправим ссылку для восстановления на вашу почту.':reset?'Задайте пароль для следующих входов.':'Откройте свои игры с любого компьютера.'}</p><form id="account-form">
      ${signup?'<label class="field">Ваше имя<input name="display-name" autocomplete="name" required maxlength="100"></label>':''}
      ${reset?'':'<label class="field">Электронная почта<input name="email" type="email" autocomplete="email" required></label>'}
      ${recovery?'':`<label class="field">Пароль<input name="password" type="password" minlength="${signup||reset?8:1}" autocomplete="${signup||reset?'new-password':'current-password'}" required></label>`}
      <p class="auth-message ${error?'auth-error':''}" role="status">${e(message)}</p><button type="submit" class="button primary auth-submit">${signup?'Зарегистрироваться':recovery?'Отправить ссылку':reset?'Сохранить пароль':'Войти'}</button></form>
      <div class="auth-links">${mode==='login'?'<button type="button" data-mode="signup">Создать аккаунт</button><button type="button" data-mode="recover">Забыли пароль?</button>':'<button type="button" data-mode="login">Вернуться ко входу</button>'}</div><p class="auth-note">Проекты доступны владельцу, приглашённым участникам и администратору. Группы и шаблоны карточек сохраняются вместе с проектом.</p></div></section>`;
    root.querySelectorAll<HTMLElement>('[data-mode]').forEach(button=>button.addEventListener('click',()=>{mode=button.dataset.mode as typeof mode;form();}));
    root.querySelector('form')!.addEventListener('submit',async event=>{
      event.preventDefault();const button=root.querySelector<HTMLButtonElement>('[type=submit]')!;button.disabled=true;
      const fields=new FormData(event.target as HTMLFormElement),email=String(fields.get('email')||'').trim(),password=String(fields.get('password')||'');
      const notice=root.querySelector<HTMLElement>('.auth-message')!;
      try{
        if(signup){const {data,error}=await client.auth.signUp({email,password,options:{data:{display_name:String(fields.get('display-name')||'').trim()},emailRedirectTo:base.href}});if(error)throw error;
          if(data.session)await enter(data.session);else{mode='login';form('Подтвердите почту по ссылке из письма. Затем войдите с заданным паролем.');}}
        else if(recovery){const {error}=await client.auth.resetPasswordForEmail(email,{redirectTo:base.href});if(error)throw error;notice.classList.remove('auth-error');notice.textContent='Если аккаунт с этой почтой существует, письмо для восстановления отправлено.';}
        else if(reset){const {error}=await client.auth.updateUser({password});if(error)throw error;mode='login';const {data}=await client.auth.getSession();if(data.session)await enter(data.session,true);}
        else{const {data,error}=await client.auth.signInWithPassword({email,password});if(error)throw error;await enter(data.session);}
      }catch(error){notice.classList.add('auth-error');notice.textContent=authMessage(error);}
      finally{button.disabled=false;}
    });
  }

  async function enter(session:Session|null,force=false){
    const userId=session?.user.id;
    if(!userId){generation++;pendingUser='';const old=current;current=undefined;old?.store.close();onLogout();mode='login';form();if(old)void old.store.clearPrivateCache();return;}
    if(mode==='reset'&&!force)return;
    if(!force&&(current?.identity.user_id===userId||pendingUser===userId))return;
    const ticket=++generation;pendingUser=userId;current?.store.close();current=undefined;onLogout();loading('Проверяем доступ к проектам…');
    try{
      const {error}=await client.rpc('claim_workshop_invites');if(error)throw error;
      let identity=await service.identity();if(ticket!==generation)return;
      const registeredName=session?.user.user_metadata?.display_name;
      if(!identity.display_name&&typeof registeredName==='string'&&registeredName.trim())identity=await service.profile(registeredName.trim().slice(0,100));
      if(ticket!==generation)return;
      const store=await CloudStorage.open(client,userId,transfers);if(ticket!==generation){store.close();return;}
      const runtime:AccountRuntime={identity,service,store,logout:async()=>{generation++;pendingUser='';current=undefined;onLogout();const {error}=await client.auth.signOut({scope:'local'});await store.clearPrivateCache();if(error)throw error;mode='login';form();}};
      current=runtime;pendingUser='';await onReady(runtime);
    }catch(error){if(ticket!==generation)return;pendingUser='';
      root.innerHTML=`<section class="auth-shell"><div class="auth-card"><img class="auth-logo" src="${logo}" alt="Без правил"><h1>Подключение мастерской</h1><p class="auth-message auth-error">${e(authMessage(error))}</p><button class="button primary" type="button" id="auth-retry">Повторить</button><button class="button quiet" type="button" id="auth-exit">Выйти</button></div></section>`;
      root.querySelector('#auth-retry')!.addEventListener('click',()=>void enter(session,true));root.querySelector('#auth-exit')!.addEventListener('click',()=>void client.auth.signOut());
    }
  }
  client.auth.onAuthStateChange((event,session)=>{
    if(event==='PASSWORD_RECOVERY'){mode='reset';generation++;setTimeout(()=>{onLogout();form();},0);return;}
    // Do not await other Auth calls from the SDK event's internal lock.
    if(event==='SIGNED_OUT'||event==='SIGNED_IN'||event==='INITIAL_SESSION')setTimeout(()=>void enter(session),0);
  });
  const {data,error}=await client.auth.getSession();if(error)throw error;await enter(data.session);
}
