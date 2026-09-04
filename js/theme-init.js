/**
 * theme-init.js
 * Early theme initialization — load BEFORE DOM renders to prevent FOUC
 * Place in <head>, BEFORE any other scripts
 */

(function() {
  'use strict';

  const themes = {
    obsidian: {
      black: '#000000',
      surface: '#070707',
      surface2: '#0d0d0d',
      gold: '#d4af37',
      goldLight: '#f5d76e',
      white: '#ffffff',
      gray: '#a5a5a5',
      border: 'rgba(212, 175, 55, 0.20)'
    },
    light: {
      black: '#f6f8fc',
      surface: '#ffffff',
      surface2: '#f8f9fd',
      gold: '#6d5dfc',
      goldLight: '#4f46e5',
      white: '#171923',
      gray: '#667085',
      border: 'rgba(109, 93, 252, 0.24)'
    },
    aurora: {
      black: '#07110f',
      surface: '#07110f',
      surface2: '#0e1d19',
      gold: '#62e6c4',
      goldLight: '#b5fff0',
      white: '#f5fffd',
      gray: '#9cb6b0',
      border: 'rgba(98, 230, 196, 0.26)'
    },
    neo: {
      black: '#0a0710',
      surface: '#0a0710',
      surface2: '#171020',
      gold: '#ff4fd8',
      goldLight: '#8df7ff',
      white: '#ffffff',
      gray: '#b8afc2',
      border: 'rgba(255, 79, 216, 0.28)'
    },
    sunset: {
      black: '#120806',
      surface: '#120806',
      surface2: '#21100c',
      gold: '#ff8a5b',
      goldLight: '#ffd166',
      white: '#fff8f3',
      gray: '#c4aaa0',
      border: 'rgba(255, 138, 91, 0.28)'
    },
    ocean: {
      black: '#030b16',
      surface: '#030b16',
      surface2: '#071827',
      gold: '#22d3ee',
      goldLight: '#60a5fa',
      white: '#f3fbff',
      gray: '#9ab5c5',
      border: 'rgba(34, 211, 238, 0.28)'
    },
    lavender: {
      black: '#090812',
      surface: '#090812',
      surface2: '#151327',
      gold: '#a78bfa',
      goldLight: '#d8ccff',
      white: '#ffffff',
      gray: '#aaa7bb',
      border: 'rgba(167, 139, 250, 0.28)'
    },
    candy: {
      black: '#12070d',
      surface: '#12070d',
      surface2: '#1f0d17',
      gold: '#fb7185',
      goldLight: '#f9a8d4',
      white: '#fff7fb',
      gray: '#c7aab7',
      border: 'rgba(251, 113, 133, 0.28)'
    },
    warmCream: {
      black: '#FFF8F3',
      surface: '#FFFBF7',
      surface2: '#F7EBE1',
      gold: '#D9531E',
      goldLight: '#F2815B',
      white: '#2C1A1D',
      gray: '#7A6666',
      border: 'rgba(217, 83, 30, 0.15)'
    }
  };

  function applyTheme(themeName) {
    if (!themes[themeName]) themeName = 'obsidian';
    const t = themes[themeName];
    const r = document.documentElement;
    r.style.setProperty('--black', t.black);
    r.style.setProperty('--surface', t.surface);
    r.style.setProperty('--surface-2', t.surface2);
    r.style.setProperty('--gold', t.gold);
    r.style.setProperty('--gold-light', t.goldLight);
    r.style.setProperty('--white', t.white);
    r.style.setProperty('--gray', t.gray);
    r.style.setProperty('--border', t.border);
    r.setAttribute('data-theme', themeName);
    try { localStorage.setItem('xag-theme', themeName); } catch (e) {}
  }

  function getDefaultTheme() {
    try {
      const saved = localStorage.getItem('xag-theme');
      if (saved && themes[saved]) return saved;
    } catch (e) {}
    const path = window.location.pathname;
    if (path.includes('/pages/admin')) return 'warmCream';
    return 'obsidian';
  }

  applyTheme(getDefaultTheme());
})();