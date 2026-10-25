export interface BackendConfig {supabaseUrl:string;supabasePublishableKey:string}

export function validateBackendConfig(value:unknown):BackendConfig {
  const config=value as Partial<BackendConfig>;
  if(!config?.supabaseUrl||!config.supabasePublishableKey)throw new Error('Подключение мастерской ещё не настроено.');
  let url:URL;
  try{url=new URL(config.supabaseUrl);}catch{throw new Error('Некорректный адрес хранилища.');}
  if(url.protocol!=='https:'&&!(url.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(url.hostname)))throw new Error('Для хранилища требуется HTTPS.');
  if(url.username||url.password||url.search||url.hash||url.pathname!=='/')throw new Error('Укажите адрес хранилища без дополнительных путей.');
  const key=config.supabasePublishableKey.trim();let isPublic=key.startsWith('sb_publishable_');
  if(!isPublic&&key.split('.').length===3){try{const part=key.split('.')[1].replace(/-/g,'+').replace(/_/g,'/');isPublic=JSON.parse(atob(part)).role==='anon';}catch{}}
  if(!isPublic)throw new Error('В браузере допустим только публичный Publishable key или anon. Секретный ключ использовать нельзя.');
  return {supabaseUrl:url.origin,supabasePublishableKey:key};
}

export function authMessage(error:{message?:string}|unknown):string {
  const message=(error as {message?:string})?.message||'Не удалось выполнить действие.';
  if(/email not confirmed/i.test(message))return 'Подтвердите почту по ссылке из письма, затем войдите в мастерскую.';
  if(/invalid login credentials|invalid_credentials/i.test(message))return 'Проверьте почту и пароль.';
  if(/rate limit|too many requests|over_email_send_rate_limit/i.test(message))return 'Слишком много попыток. Попробуйте позже.';
  if(/fetch|network|connection/i.test(message))return 'Не удалось связаться с сервером. Проверьте интернет и повторите попытку.';
  if(/password.*(short|least|weak)/i.test(message))return 'Используйте пароль длиной не менее 8 символов.';
  if(/email.*invalid/i.test(message))return 'Проверьте адрес электронной почты.';
  return message;
}
