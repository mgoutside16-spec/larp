import fontUrl from '../../src/larp_studio/assets/DejaVuSans.ttf?url';
import { type Game, type Material, KINDS } from './types';

const fontBytes=fetch(fontUrl).then(response=>{if(!response.ok)throw new Error('Не удалось загрузить шрифт PDF. Обновите страницу.');return response.arrayBuffer();});
fontBytes.catch(()=>{});
export const locationName=(game:Game,row:Material)=>game.locations.find(l=>l.id===row.location_id)?.name || '';
export const types=(row:Material)=>Object.entries(KINDS).filter(([kind])=>row.blocks.some(b=>b.kind===kind)).map(([,name])=>name);
export const ordered=(game:Game)=>[...game.records].sort((a,b)=>locationName(game,a).localeCompare(locationName(game,b),'ru')||a.title.localeCompare(b.title,'ru'));

export function download(bytes:Uint8Array|ArrayBuffer|Blob,filename:string,mime='application/octet-stream') {
  const blob=bytes instanceof Blob?bytes:new Blob([bytes instanceof Uint8Array?new Uint8Array(bytes):bytes],{type:mime});
  const url=URL.createObjectURL(blob),link=document.createElement('a');
  link.href=url;link.download=filename.replace(/[<>:"/\\|?*\x00-\x1f]/g,'_');link.click();
  setTimeout(()=>URL.revokeObjectURL(url),60000);
}

export async function excel(game:Game):Promise<Uint8Array> {
  const {default:ExcelJS}=await import('exceljs');
  const book=new ExcelJS.Workbook(),sheet=book.addWorksheet('Коды');
  sheet.columns=[{header:'Код',key:'code',width:14},{header:'Название',key:'title',width:42},
    {header:'Локация',key:'location',width:30},{header:'Содержимое',key:'types',width:30},{header:'Изменено',key:'modified',width:26}];
  for(const row of ordered(game))sheet.addRow({code:row.code,title:row.title,location:locationName(game,row),types:types(row).join(', '),modified:row.modified});
  sheet.getRow(1).eachCell(cell=>{cell.font={bold:true,color:{argb:'FFFFFFFF'}};cell.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF193348'}};});
  sheet.views=[{state:'frozen',ySplit:1}];sheet.autoFilter={from:'A1',to:`E${sheet.rowCount}`};
  return new Uint8Array(await book.xlsx.writeBuffer());
}

export async function pdf(game:Game,showTitle=false,showLocation=false):Promise<ArrayBuffer> {
  const {jsPDF}=await import('jspdf');
  const bytes=new Uint8Array(await fontBytes);
  let binary='';for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));
  const doc=new jsPDF({unit:'mm',format:'a4'});
  doc.addFileToVFS('DejaVuSans.ttf',btoa(binary));doc.addFont('DejaVuSans.ttf','LARP','normal');doc.setFont('LARP');
  const rows=ordered(game),margin=12,gap=5,w=(210-margin*2-gap)/2,h=(297-margin*2-gap*3)/4;
  for(let i=0;i<rows.length;i++) {
    if(i && i%8===0)doc.addPage();
    const row=rows[i],index=i%8,x=margin+(index%2)*(w+gap),y=margin+Math.floor(index/2)*(h+gap);
    doc.setDrawColor(196,205,216);doc.rect(x,y,w,h);
    doc.setTextColor(25,51,72);doc.setFontSize(37);doc.text(row.code,x+w/2,y+h/2,{align:'center'});
    doc.setFontSize(9);
    if(showTitle)doc.text(doc.splitTextToSize(row.title,w-12).slice(0,2),x+w/2,y+h-17,{align:'center'});
    if(showLocation)doc.text(doc.splitTextToSize(locationName(game,row)||'Без локации',w-12).slice(0,1),x+w/2,y+h-6,{align:'center'});
  }
  if(!rows.length){doc.setFontSize(13);doc.text('В проекте пока нет записей.',margin,25);}
  return doc.output('arraybuffer');
}
