export function escapeHtml(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
}

export function safeHtml(value: string): string {
  const doc=new DOMParser().parseFromString(value,'text/html');
  const allowed=new Set(['P','H1','H2','H3','H4','B','STRONG','I','EM','U','BR','UL','OL','LI','BLOCKQUOTE']);
  const blocked=new Set(['SCRIPT','STYLE','IFRAME','OBJECT','EMBED','SVG','MATH','TEMPLATE']);
  function render(node:Node):string {
    if(node.nodeType===Node.TEXT_NODE)return escapeHtml(node.textContent);
    if(!(node instanceof Element) || blocked.has(node.tagName))return '';
    let inner=[...node.childNodes].map(render).join('');
    if(node.tagName==='DIV')return `<p>${inner || '<br>'}</p>`;
    if(node.tagName==='SPAN') {
      const style=(node as HTMLElement).style;
      if(style.fontWeight==='bold' || Number(style.fontWeight)>=600)inner=`<b>${inner}</b>`;
      if(style.fontStyle==='italic')inner=`<i>${inner}</i>`;
      return inner;
    }
    if(!allowed.has(node.tagName))return inner;
    const tag=node.tagName.toLowerCase();
    return tag==='br'?'<br>':`<${tag}>${inner}</${tag}>`;
  }
  return [...doc.body.childNodes].map(render).join('');
}
