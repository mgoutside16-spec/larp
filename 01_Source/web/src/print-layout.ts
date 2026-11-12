import { mediaPath, requireValue } from './types';

export interface PrintTemplate {
  imagePath:string; width:number; height:number; x:number; y:number; fontSize:number;
  color:string; font:'sans'|'serif'|'mono'; bold:boolean;
}

export function validateTemplate(config:PrintTemplate) {
  mediaPath(config.imagePath);
  requireValue(Number.isInteger(config.width)&&Number.isInteger(config.height)&&config.width>=32&&config.height>=32
    &&config.width<=12000&&config.height<=12000&&config.width*config.height<=40000000,'Изображение должно быть не больше 40 мегапикселей.');
  requireValue(Number.isFinite(config.x)&&config.x>=0&&config.x<=1&&Number.isFinite(config.y)&&config.y>=0&&config.y<=1,'Положение кода должно быть внутри изображения.');
  requireValue(Number.isFinite(config.fontSize)&&config.fontSize>=.005&&config.fontSize<=.5,'Некорректный размер цифр.');
  requireValue(/^#[0-9a-f]{6}$/i.test(config.color)&&['sans','serif','mono'].includes(config.font)&&typeof config.bold==='boolean','Некорректное оформление цифр.');
}

export function canvasPosition(clientX:number,clientY:number,bounds:{left:number;top:number;width:number;height:number}) {
  requireValue(bounds.width>0&&bounds.height>0,'Изображение ещё не загружено.');
  return {x:Math.min(1,Math.max(0,(clientX-bounds.left)/bounds.width)),y:Math.min(1,Math.max(0,(clientY-bounds.top)/bounds.height))};
}

function crc32(bytes:Uint8Array) {
  let crc=0xffffffff;
  for(const byte of bytes){crc^=byte;for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}
  return (crc^0xffffffff)>>>0;
}

export function pngWithDpi(bytes:Uint8Array,dpi=300):Uint8Array {
  requireValue(bytes.length>=33&&bytes[0]===137&&bytes[1]===80&&bytes[2]===78&&bytes[3]===71,'Не удалось сформировать PNG.');
  const body=new Uint8Array(13);body.set(new TextEncoder().encode('pHYs'));
  const view=new DataView(body.buffer),ppm=Math.round(dpi/0.0254);
  view.setUint32(4,ppm);view.setUint32(8,ppm);body[12]=1;
  const chunk=new Uint8Array(21),chunkView=new DataView(chunk.buffer);
  chunkView.setUint32(0,9);chunk.set(body,4);chunkView.setUint32(17,crc32(body));
  const parts:Uint8Array[]=[bytes.subarray(0,8)];let offset=8,inserted=false;
  while(offset+12<=bytes.length){
    const length=new DataView(bytes.buffer,bytes.byteOffset+offset,4).getUint32(0);
    requireValue(offset+length+12<=bytes.length,'Повреждён PNG.');
    const kind=new TextDecoder().decode(bytes.subarray(offset+4,offset+8));
    if(kind!=='pHYs')parts.push(bytes.subarray(offset,offset+length+12));
    if(kind==='IHDR'){parts.push(chunk);inserted=true;}
    offset+=length+12;
  }
  requireValue(inserted&&offset===bytes.length,'Повреждён PNG.');
  const result=new Uint8Array(parts.reduce((n,p)=>n+p.length,0));let end=0;
  for(const part of parts){result.set(part,end);end+=part.length;}return result;
}

export function drawCode(canvas:HTMLCanvasElement,image:CanvasImageSource,config:PrintTemplate,code:string) {
  validateTemplate(config);requireValue(/^[1-9][0-9]{4}$/.test(code),'Некорректный код записи.');
  canvas.width=config.width;canvas.height=config.height;
  const ctx=canvas.getContext('2d');requireValue(ctx,'Браузер не поддерживает рисование карточек.');
  ctx.drawImage(image,0,0,config.width,config.height);
  const font={sans:'Arial, sans-serif',serif:'Georgia, serif',mono:'Consolas, monospace'}[config.font];
  let size=config.fontSize*config.height;ctx.font=`${config.bold?'700':'400'} ${size}px ${font}`;
  const measured=ctx.measureText(code).width;
  if(measured>config.width-4){size*=(config.width-4)/measured;ctx.font=`${config.bold?'700':'400'} ${size}px ${font}`;}
  ctx.fillStyle=config.color;ctx.textAlign='center';ctx.textBaseline='middle';
  const half=ctx.measureText(code).width/2,pad=2;
  const x=Math.min(config.width-half-pad,Math.max(half+pad,config.x*config.width));
  const y=Math.min(config.height-size/2-pad,Math.max(size/2+pad,config.y*config.height));
  ctx.fillText(code,x,y);
}
