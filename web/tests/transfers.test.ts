import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {createServer} from 'node:http';
import {Transfers} from '../src/transfers.ts';

async function server(){
  const requests:string[]=[];
  const http=createServer((req,res)=>{
    requests.push(req.url!);
    if(req.url==='/wait')return;
    if(req.url==='/partial'){res.writeHead(200,{'content-type':'application/json'});res.write('{\"ok\":');return;}
    res.writeHead(200,{'content-type':'application/json'});res.end('{"ok":true}');
  });
  await new Promise<void>(resolve=>http.listen(0,'127.0.0.1',resolve));
  const address=http.address() as {port:number};
  return {http,requests,url:`http://127.0.0.1:${address.port}`,
    close:async()=>{http.closeAllConnections();await new Promise<void>(resolve=>http.close(()=>resolve()));}};
}
test('workshop fetch bounds an unresponsive real HTTP request',async()=>{
  const api=await server();
  try{
    await assert.rejects(new Transfers(100,100).fetch(api.url+'/wait'),/долго не отвечает/);
    assert.deepEqual(api.requests,['/wait']);
  }finally{await api.close();}
});
test('workshop fetch preserves successful responses and caller abort signals',async()=>{
  const api=await server();const transfers=new Transfers(100,5000);
  try{
    assert.deepEqual(await (await transfers.fetch(api.url+'/ok')).json(),{ok:true});
    const controller=new AbortController();controller.abort();
    await assert.rejects(transfers.fetch(api.url+'/wait',{signal:controller.signal}),{name:'AbortError'});
    assert.deepEqual(api.requests,['/ok']);
  }finally{await api.close();}
});


test('workshop fetch times out when headers arrive but the JSON body stalls',{timeout:2000},async()=>{
  const api=await server();
  try{
    const response=await new Transfers(100,100).fetch(api.url+'/partial');
    const outcome=await Promise.race([response.json().then(()=>'',error=>error.message),new Promise<string>(resolve=>setTimeout(()=>resolve('body still pending'),400))]);
    assert.match(outcome,/долго не отвечает/);
  }
  finally{await api.close();}
});
