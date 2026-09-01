
(function(){
  const themes={
    obsidian:{accent:"#d4af37",accent2:"#f5d76e",surface:"#070707",surface2:"#0d0d0d",text:"#fff",muted:"#a5a5a5",border:"rgba(212,175,55,.24)",black:"#000"},
    light:{accent:"#6d5dfc",accent2:"#4f46e5",surface:"#fff",surface2:"#f8f9fd",text:"#171923",muted:"#667085",border:"rgba(109,93,252,.24)",black:"#f4f6fb"},
    aurora:{accent:"#62e6c4",accent2:"#b5fff0",surface:"#07110f",surface2:"#0e1d19",text:"#f5fffd",muted:"#9cb6b0",border:"rgba(98,230,196,.26)",black:"#04100d"},
    neo:{accent:"#ff4fd8",accent2:"#8df7ff",surface:"#0a0710",surface2:"#171020",text:"#fff",muted:"#b8afc2",border:"rgba(255,79,216,.28)",black:"#06030a"},
    sunset:{accent:"#ff8a5b",accent2:"#ffd166",surface:"#120806",surface2:"#21100c",text:"#fff8f3",muted:"#c4aaa0",border:"rgba(255,138,91,.28)",black:"#090403"},
    ocean:{accent:"#22d3ee",accent2:"#60a5fa",surface:"#030b16",surface2:"#071827",text:"#f3fbff",muted:"#9ab5c5",border:"rgba(34,211,238,.28)",black:"#020711"},
    lavender:{accent:"#a78bfa",accent2:"#d8ccff",surface:"#090812",surface2:"#151327",text:"#fff",muted:"#aaa7bb",border:"rgba(167,139,250,.28)",black:"#05040b"},
    candy:{accent:"#fb7185",accent2:"#f9a8d4",surface:"#12070d",surface2:"#1f0d17",text:"#fff7fb",muted:"#c7aab7",border:"rgba(251,113,133,.28)",black:"#090308"}
  };

  function applyTheme(name){
    const t=themes[name]||themes.obsidian, r=document.documentElement;
    [["--black",t.black],["--surface",t.surface],["--surface-2",t.surface2],["--gold",t.accent],
     ["--gold-light",t.accent2],["--white",t.text],["--gray",t.muted],["--border",t.border]]
     .forEach(([k,v])=>r.style.setProperty(k,v));
    r.dataset.theme=name;
    document.querySelectorAll(".xag-theme-swatch").forEach(b=>b.classList.toggle("active",b.dataset.theme===name));
    localStorage.setItem("xag-theme",name);
  }

  function applyZoom(v){
    v=Math.max(85,Math.min(120,v));
    document.documentElement.style.setProperty("--xag-font-scale",(v/100).toFixed(2));
    document.body.style.fontSize=v+"%";
    const out=document.getElementById("xagFontValue");
    if(out) out.textContent=v+"%";
    localStorage.setItem("xag-zoom",String(v));
  }

  document.addEventListener("DOMContentLoaded",function(){
    document.querySelectorAll(".xag-theme-swatch").forEach(b=>b.addEventListener("click",()=>applyTheme(b.dataset.theme)));
    const minus=document.getElementById("xagZoomOut"), plus=document.getElementById("xagZoomIn");
    if(minus) minus.addEventListener("click",()=>applyZoom((parseInt(localStorage.getItem("xag-zoom")||"100",10))-5));
    if(plus) plus.addEventListener("click",()=>applyZoom((parseInt(localStorage.getItem("xag-zoom")||"100",10))+5));
    applyTheme(localStorage.getItem("xag-theme")||"obsidian");
    applyZoom(parseInt(localStorage.getItem("xag-zoom")||"100",10));
  });
})();
