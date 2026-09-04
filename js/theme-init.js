/**
 * XAG global theme initialization.
 * Must run in <head> before page styles/scripts to prevent theme flash.
 */
(function () {
  'use strict';

  const themes = {
    warmCream: { black:'#FAF5EF', surface:'#FFFBF7', surface2:'#F7EBE1', gold:'#D9531E', goldLight:'#F2815B', white:'#2C1A1D', gray:'#7A6666', border:'rgba(217,83,30,.15)' },
    obsidian: { black:'#000000', surface:'#070707', surface2:'#0d0d0d', gold:'#d4af37', goldLight:'#f5d76e', white:'#ffffff', gray:'#a5a5a5', border:'rgba(212,175,55,.20)' },
    cyber: { black:'#07131d', surface:'rgba(15,32,45,.78)', surface2:'rgba(20,43,58,.92)', gold:'#16e0ff', goldLight:'#75f4ff', white:'#f7fbff', gray:'#9fb1bf', border:'rgba(22,224,255,.22)' },
    vapor: { black:'#160d2b', surface:'rgba(44,20,75,.72)', surface2:'rgba(55,24,92,.90)', gold:'#ff48d7', goldLight:'#65efff', white:'#fff7ff', gray:'#c5b7d5', border:'rgba(255,72,215,.28)' },
    emerald: { black:'#061816', surface:'rgba(10,47,39,.72)', surface2:'rgba(14,62,50,.90)', gold:'#2ee99b', goldLight:'#a1ffd8', white:'#f5fffd', gray:'#9cb6b0', border:'rgba(46,233,155,.25)' },
    gold: { black:'#100d08', surface:'rgba(49,32,15,.72)', surface2:'rgba(62,41,19,.90)', gold:'#ffd66b', goldLight:'#fff0ae', white:'#fff8e8', gray:'#cbbda5', border:'rgba(255,214,107,.27)' },
    mughal: { black:'#210d0b', surface:'rgba(86,30,23,.72)', surface2:'rgba(105,38,28,.90)', gold:'#d79a4b', goldLight:'#ffe2a0', white:'#fff8f0', gray:'#c9aaa0', border:'rgba(228,189,102,.30)' },
    rajasthani: { black:'#061b22', surface:'rgba(12,73,61,.72)', surface2:'rgba(17,88,71,.90)', gold:'#e2b953', goldLight:'#ffe4a0', white:'#f7fffc', gray:'#a7c3bb', border:'rgba(226,185,83,.27)' },
    kalamkari: { black:'#ead8b7', surface:'rgba(255,248,233,.72)', surface2:'rgba(255,249,235,.94)', gold:'#a9472d', goldLight:'#c7773b', white:'#2a1912', gray:'#756052', border:'rgba(112,57,39,.25)' },
    light: { black:'#f6f8fc', surface:'rgba(255,255,255,.72)', surface2:'rgba(255,255,255,.94)', gold:'#5b45e8', goldLight:'#8b73ff', white:'#161b2a', gray:'#647084', border:'rgba(55,65,95,.16)' },
    kawaii: { black:'#fff4f8', surface:'rgba(255,255,255,.72)', surface2:'rgba(255,255,255,.94)', gold:'#ee72ad', goldLight:'#8b7cff', white:'#30253d', gray:'#786c82', border:'rgba(180,117,183,.22)' }
  };

  function applyTheme(name) {
    if (!themes[name]) name = 'warmCream';
    const t = themes[name], r = document.documentElement;
    r.dataset.theme = name;
    [['--black',t.black],['--surface',t.surface],['--surface-2',t.surface2],['--gold',t.gold],
     ['--gold-light',t.goldLight],['--white',t.white],['--gray',t.gray],['--border',t.border]]
      .forEach(([k,v]) => r.style.setProperty(k,v));
    try { localStorage.setItem('xag-theme', name); } catch (_) {}
  }

  let saved = null;
  try { saved = localStorage.getItem('xag-theme'); } catch (_) {}
  applyTheme(themes[saved] ? saved : 'warmCream');
})();
