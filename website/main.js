// zMac: trang giới thiệu. Đổi ngôn ngữ, thông tin bản tải, demo chia cửa sổ, nút chép.
(() => {
  'use strict';

  const root = document.documentElement;
  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => Array.from(document.querySelectorAll(sel));

  // localStorage có thể bị chặn (tab ẩn danh, chặn cookie): trang vẫn chạy bình thường.
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* bỏ qua */ } },
  };

  // ---------- Ngôn ngữ ----------
  // HTML viết sẵn tiếng Việt; bản tiếng Anh nằm trong data-en (nội dung) và data-en-label / data-en-content (thuộc tính).
  let lang = 'vi';
  const original = new WeakMap();
  const remember = (node, key, value) => {
    let saved = original.get(node);
    if (!saved) { saved = {}; original.set(node, saved); }
    if (!(key in saved)) saved[key] = value;
    return saved[key];
  };
  const textNodes = $$('[data-en]');
  const attrMap = [['enLabel', 'aria-label'], ['enContent', 'content']];
  const attrNodes = $$('[data-en-label], [data-en-content]');
  const langBtn = $('#lang');

  // Ghi lại bản tiếng Việt ngay từ đầu, trước khi có gì sửa chữ trên trang.
  for (const n of textNodes) remember(n, 'html', n.innerHTML);
  for (const n of attrNodes) {
    for (const [key, attr] of attrMap) if (n.dataset[key] !== undefined) remember(n, attr, n.getAttribute(attr) || '');
  }

  function applyLang(next) {
    lang = next;
    root.lang = next;
    for (const n of textNodes) {
      const vi = remember(n, 'html', n.innerHTML);
      n.innerHTML = next === 'en' ? n.dataset.en : vi;
    }
    for (const n of attrNodes) {
      for (const [key, attr] of attrMap) {
        if (n.dataset[key] === undefined) continue;
        const vi = remember(n, attr, n.getAttribute(attr) || '');
        n.setAttribute(attr, next === 'en' ? n.dataset[key] : vi);
      }
    }
    langBtn.textContent = next === 'en' ? 'VI' : 'EN';
    langBtn.setAttribute('aria-label', next === 'en' ? 'Chuyển sang tiếng Việt' : 'Switch to English');
    renderDownload();
    renderSnap();
  }

  langBtn.addEventListener('click', () => {
    const next = lang === 'vi' ? 'en' : 'vi';
    store.set('lang', next);
    applyLang(next);
  });

  // ---------- Thông tin bản tải (download/latest.json do scripts/make-dmg.sh sinh ra) ----------
  let info = null;

  const fmtSize = (bytes) =>
    (bytes / 1e6).toLocaleString(lang === 'vi' ? 'vi-VN' : 'en-US', { maximumFractionDigits: 1 }) + ' MB';

  function archText(archs) {
    const intel = /x86_64/.test(archs);
    const arm = /arm64/.test(archs);
    if (intel && arm) return lang === 'vi' ? 'Apple Silicon và Intel' : 'Apple Silicon and Intel';
    return intel ? 'Intel' : 'Apple Silicon';
  }

  function setAll(key, value) {
    for (const n of $$(`[data-dl="${key}"]`)) n.textContent = value;
  }

  function renderDownload() {
    if (!info) return;
    if (info.version) setAll('version', (lang === 'vi' ? 'Phiên bản ' : 'Version ') + info.version);
    if (info.size) setAll('size', fmtSize(info.size));
    if (info.archs) setAll('arch', archText(info.archs));
    if (info.minimumSystemVersion) {
      const v = String(info.minimumSystemVersion).replace(/\.0$/, '');
      setAll('minos', 'macOS ' + v + (lang === 'vi' ? ' trở lên' : ' or later'));
    }
    if (info.sha256) {
      setAll('sha', info.sha256);
      $('#hash').hidden = false;
    }
  }

  fetch('download/latest.json', { cache: 'no-cache' })
    .then((r) => (r.ok ? r.json() : null))
    .then((j) => { if (j) { info = j; renderDownload(); } })
    .catch(() => { /* không có file thì giữ chữ mặc định */ });

  // ---------- Demo chia cửa sổ ----------
  // x, y, w, h tính theo % màn hình.
  const LAYOUTS = {
    left:   { key: '←', x: 0, y: 0, w: 50, h: 100, vi: 'Nửa trái', en: 'Left half' },
    right:  { key: '→', x: 50, y: 0, w: 50, h: 100, vi: 'Nửa phải', en: 'Right half' },
    top:    { key: '↑', x: 0, y: 0, w: 100, h: 50, vi: 'Nửa trên', en: 'Top half' },
    bottom: { key: '↓', x: 0, y: 50, w: 100, h: 50, vi: 'Nửa dưới', en: 'Bottom half' },
    tl:     { key: 'U', x: 0, y: 0, w: 50, h: 50, vi: 'Góc trên trái', en: 'Top left' },
    tr:     { key: 'I', x: 50, y: 0, w: 50, h: 50, vi: 'Góc trên phải', en: 'Top right' },
    bl:     { key: 'J', x: 0, y: 50, w: 50, h: 50, vi: 'Góc dưới trái', en: 'Bottom left' },
    br:     { key: 'K', x: 50, y: 50, w: 50, h: 50, vi: 'Góc dưới phải', en: 'Bottom right' },
    t1:     { key: 'D', x: 0, y: 0, w: 100 / 3, h: 100, vi: 'Phần ba đầu', en: 'First third' },
    t2:     { key: 'F', x: 100 / 3, y: 0, w: 100 / 3, h: 100, vi: 'Phần ba giữa', en: 'Center third' },
    t3:     { key: 'G', x: 200 / 3, y: 0, w: 100 / 3, h: 100, vi: 'Phần ba cuối', en: 'Last third' },
    tt1:    { key: 'E', x: 0, y: 0, w: 200 / 3, h: 100, vi: 'Hai phần ba đầu', en: 'First two thirds' },
    tt2:    { key: 'T', x: 100 / 3, y: 0, w: 200 / 3, h: 100, vi: 'Hai phần ba cuối', en: 'Last two thirds' },
    max:    { key: '↩', x: 0, y: 0, w: 100, h: 100, vi: 'Phóng to', en: 'Maximize' },
    center: { key: 'C', x: 20, y: 14, w: 60, h: 72, vi: 'Căn giữa', en: 'Center' },
  };
  // Phím thật trên bàn phím → bố cục, dùng khi đang focus trong khung demo.
  const KEYMAP = {
    ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'top', ArrowDown: 'bottom',
    u: 'tl', i: 'tr', j: 'bl', k: 'br', d: 't1', f: 't2', g: 't3', e: 'tt1', t: 'tt2', c: 'center',
  };

  const win = $('#snap-win');
  const demo = $('#snap-demo');
  const snapKey = $('#snap-key');
  const snapName = $('#snap-name');
  const keyButtons = $$('[data-snap]');
  let current = 'center';

  function renderSnap() {
    const l = LAYOUTS[current];
    snapKey.textContent = l.key;
    snapName.textContent = l[lang];
  }

  function snap(name) {
    const l = LAYOUTS[name];
    if (!l) return;
    current = name;
    win.style.setProperty('--x', l.x);
    win.style.setProperty('--y', l.y);
    win.style.setProperty('--w', l.w);
    win.style.setProperty('--h', l.h);
    for (const b of keyButtons) b.setAttribute('aria-pressed', String(b.dataset.snap === name));
    renderSnap();
  }

  for (const b of keyButtons) b.addEventListener('click', () => snap(b.dataset.snap));
  demo.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const name = KEYMAP[e.key] || KEYMAP[e.key.toLowerCase()];
    if (!name) return;
    e.preventDefault();
    snap(name);
    const btn = keyButtons.find((b) => b.dataset.snap === name);
    if (btn) btn.focus();
  });

  // ---------- Nút chép lệnh ----------
  for (const btn of $$('[data-copy]')) {
    btn.addEventListener('click', async () => {
      const target = document.getElementById(btn.dataset.copy);
      if (!target) return;
      try {
        await navigator.clipboard.writeText(target.textContent.trim());
      } catch {
        // Trình duyệt không cho ghi clipboard: chọn sẵn chữ để người dùng tự ⌘C.
        const range = document.createRange();
        range.selectNodeContents(target);
        const sel = getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        return;
      }
      btn.textContent = lang === 'en' ? 'Copied' : 'Đã chép';
      setTimeout(() => { btn.textContent = lang === 'en' ? btn.dataset.en : original.get(btn).html; }, 1500);
    });
  }

  // ---------- Khởi động ----------
  const saved = store.get('lang');
  const prefersVi = (navigator.languages || [navigator.language || '']).some((l) => /^vi\b/i.test(l));
  const initial = saved === 'vi' || saved === 'en' ? saved : prefersVi ? 'vi' : 'en';
  snap('center');
  if (initial === 'en') applyLang('en');
})();
