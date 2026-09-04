(function(){
  const themes={
    warmCream:{accent:"#D9531E",accent2:"#F2815B",surface:"#FFFBF7",surface2:"#F7EBE1",text:"#2C1A1D",muted:"#7A6666",border:"rgba(217,83,30,.15)",black:"#FAF5EF"},
    obsidian:{accent:"#d4af37",accent2:"#f5d76e",surface:"#070707",surface2:"#0d0d0d",text:"#fff",muted:"#a5a5a5",border:"rgba(212,175,55,.24)",black:"#000"},
    cyber:{accent:"#16e0ff",accent2:"#75f4ff",surface:"rgba(15,32,45,.78)",surface2:"rgba(20,43,58,.92)",text:"#f7fbff",muted:"#9fb1bf",border:"rgba(22,224,255,.22)",black:"#07131d"},
    vapor:{accent:"#ff48d7",accent2:"#65efff",surface:"rgba(44,20,75,.72)",surface2:"rgba(55,24,92,.9)",text:"#fff7ff",muted:"#c5b7d5",border:"rgba(255,72,215,.28)",black:"#160d2b"},
    emerald:{accent:"#2ee99b",accent2:"#a1ffd8",surface:"rgba(10,47,39,.72)",surface2:"rgba(14,62,50,.9)",text:"#f5fffd",muted:"#9cb6b0",border:"rgba(46,233,155,.25)",black:"#061816"},
    gold:{accent:"#ffd66b",accent2:"#fff0ae",surface:"rgba(49,32,15,.72)",surface2:"rgba(62,41,19,.9)",text:"#fff8e8",muted:"#cbbda5",border:"rgba(255,214,107,.27)",black:"#100d08"},
    mughal:{accent:"#d79a4b",accent2:"#ffe2a0",surface:"rgba(86,30,23,.72)",surface2:"rgba(105,38,28,.9)",text:"#fff8f0",muted:"#c9aaa0",border:"rgba(228,189,102,.3)",black:"#210d0b"},
    rajasthani:{accent:"#e2b953",accent2:"#ffe4a0",surface:"rgba(12,73,61,.72)",surface2:"rgba(17,88,71,.9)",text:"#f7fffc",muted:"#a7c3bb",border:"rgba(226,185,83,.27)",black:"#061b22"},
    kalamkari:{accent:"#a9472d",accent2:"#c7773b",surface:"rgba(255,248,233,.72)",surface2:"rgba(255,249,235,.94)",text:"#2a1912",muted:"#756052",border:"rgba(112,57,39,.25)",black:"#ead8b7"},
    light:{accent:"#5b45e8",accent2:"#8b73ff",surface:"rgba(255,255,255,.72)",surface2:"rgba(255,255,255,.94)",text:"#161b2a",muted:"#647084",border:"rgba(55,65,95,.16)",black:"#f6f8fc"},
    kawaii:{accent:"#ee72ad",accent2:"#8b7cff",surface:"rgba(255,255,255,.72)",surface2:"rgba(255,255,255,.94)",text:"#30253d",muted:"#786c82",border:"rgba(180,117,183,.22)",black:"#fff4f8"}
  };
  function applyTheme(name){
    const t=themes[name]||themes.warmCream,r=document.documentElement;
    [['--black',t.black],['--bg',t.black],['--surface',t.surface],['--surface-2',t.surface2],['--gold',t.accent],
     ['--primary',t.accent],['--gold-light',t.accent2],['--secondary',t.accent2],['--white',t.text],['--text',t.text],['--gray',t.muted],['--muted',t.muted],['--border',t.border]]
      .forEach(([k,v])=>r.style.setProperty(k,v));
    r.dataset.theme=name;
    document.querySelectorAll('.xag-theme-swatch,.swatch').forEach(b=>b.classList.toggle('active',b.dataset.theme===name));
    try{localStorage.setItem('xag-theme',name)}catch(_){}
  }
  function applyZoom(v){
    v=Math.max(85,Math.min(120,v));
    document.documentElement.style.setProperty('--xag-font-scale',(v/100).toFixed(2));
    document.documentElement.style.fontSize=v+'%';
    const out=document.getElementById('xagFontValue')||document.getElementById('fontSize');
    if(out)out.textContent=v+'%';
    try{localStorage.setItem('xag-zoom',String(v));localStorage.setItem('xag-font-size',String(v))}catch(_){}
  }
  document.addEventListener('DOMContentLoaded',function(){
    document.querySelectorAll('.xag-theme-swatch,.swatch').forEach(b=>b.addEventListener('click',()=>applyTheme(b.dataset.theme)));
    const minus=document.getElementById('xagZoomOut')||document.getElementById('zoomOut');
    const plus=document.getElementById('xagZoomIn')||document.getElementById('zoomIn');
    if(minus)minus.addEventListener('click',()=>applyZoom((parseInt(localStorage.getItem('xag-zoom')||localStorage.getItem('xag-font-size')||'100',10))-5));
    if(plus)plus.addEventListener('click',()=>applyZoom((parseInt(localStorage.getItem('xag-zoom')||localStorage.getItem('xag-font-size')||'100',10))+5));
    let saved='warmCream';try{saved=localStorage.getItem('xag-theme')||'warmCream'}catch(_){}
    applyTheme(themes[saved]?saved:'warmCream');
    let zoom=100;try{zoom=parseInt(localStorage.getItem('xag-zoom')||localStorage.getItem('xag-font-size')||'100',10)}catch(_){}
    applyZoom(zoom);
  });
})();
