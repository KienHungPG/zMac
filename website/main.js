// zMac: trang giới thiệu. Đổi ngôn ngữ, thông tin bản tải, demo từng module, nút chép.
(() => {
  'use strict';

  const root = document.documentElement;
  const $ = (sel, el = document) => el.querySelector(sel);
  const $$ = (sel, el = document) => Array.from(el.querySelectorAll(sel));
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const pad = (n) => String(n).padStart(2, '0');
  const SVG = 'http://www.w3.org/2000/svg';

  // localStorage có thể bị chặn (tab ẩn danh, chặn cookie): trang vẫn chạy bình thường.
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* bỏ qua */ } },
  };

  // ---------- Ngôn ngữ ----------
  // HTML viết sẵn tiếng Việt; bản tiếng Anh nằm trong data-en (nội dung) và data-en-label / -content / -placeholder (thuộc tính).
  let lang = 'vi';
  const T = (vi, en) => (lang === 'en' ? en : vi);
  const original = new WeakMap();
  const remember = (node, key, value) => {
    let saved = original.get(node);
    if (!saved) { saved = {}; original.set(node, saved); }
    if (!(key in saved)) saved[key] = value;
    return saved[key];
  };
  const textNodes = $$('[data-en]');
  const attrMap = [['enLabel', 'aria-label'], ['enContent', 'content'], ['enPlaceholder', 'placeholder']];
  const attrNodes = $$('[data-en-label], [data-en-content], [data-en-placeholder]');
  const langBtn = $('#lang');
  const langHooks = [];

  // Ghi lại bản tiếng Việt ngay từ đầu, trước khi có gì sửa chữ trên trang.
  for (const n of textNodes) remember(n, 'html', n.innerHTML);
  for (const n of attrNodes) {
    for (const [key, attr] of attrMap) if (n.dataset[key] !== undefined) remember(n, attr, n.getAttribute(attr) || '');
  }

  function applyLang(next) {
    lang = next;
    root.lang = next;
    for (const n of textNodes) n.innerHTML = next === 'en' ? n.dataset.en : original.get(n).html;
    for (const n of attrNodes) {
      for (const [key, attr] of attrMap) {
        if (n.dataset[key] === undefined) continue;
        n.setAttribute(attr, next === 'en' ? n.dataset[key] : original.get(n)[attr]);
      }
    }
    langBtn.textContent = next === 'en' ? 'VI' : 'EN';
    langBtn.setAttribute('aria-label', next === 'en' ? 'Chuyển sang tiếng Việt' : 'Switch to English');
    for (const h of langHooks) h();
  }

  langBtn.addEventListener('click', () => {
    const next = lang === 'vi' ? 'en' : 'vi';
    store.set('lang', next);
    applyLang(next);
  });

  // ---------- Giao diện sáng / tối ----------
  // Mặc định theo hệ thống; bấm nút thì ghi đè và nhớ lại (theme.js áp dụng trước khi trang hiện).
  const themeBtn = $('#theme');
  const darkMq = matchMedia('(prefers-color-scheme: dark)');
  const isDark = () => (root.dataset.theme ? root.dataset.theme === 'dark' : darkMq.matches);
  function renderTheme() {
    const dark = isDark();
    $('use', themeBtn).setAttribute('href', dark ? '#i-sun' : '#i-moon');
    const label = dark ? T('Chuyển sang giao diện sáng', 'Switch to light mode') : T('Chuyển sang giao diện tối', 'Switch to dark mode');
    themeBtn.setAttribute('aria-label', label);
    themeBtn.title = label;
  }
  themeBtn.addEventListener('click', () => {
    const next = isDark() ? 'light' : 'dark';
    root.dataset.theme = next;
    store.set('theme', next);
    renderTheme();
  });
  darkMq.addEventListener('change', renderTheme);
  langHooks.push(renderTheme);
  renderTheme();

  // ---------- Thông tin bản tải (download/latest.json do scripts/make-dmg.sh sinh ra) ----------
  let info = null;
  const fmtSize = (bytes) =>
    (bytes / 1e6).toLocaleString(lang === 'vi' ? 'vi-VN' : 'en-US', { maximumFractionDigits: 1 }) + ' MB';
  function archText(archs) {
    const intel = /x86_64/.test(archs);
    const arm = /arm64/.test(archs);
    if (intel && arm) return T('Apple Silicon và Intel', 'Apple Silicon and Intel');
    return intel ? 'Intel' : 'Apple Silicon';
  }
  function setAll(key, value) {
    for (const n of $$(`[data-dl="${key}"]`)) n.textContent = value;
  }
  function renderDownload() {
    if (!info) return;
    if (info.version) setAll('version', T('Phiên bản ', 'Version ') + info.version);
    if (info.size) setAll('size', fmtSize(info.size));
    if (info.archs) setAll('arch', archText(info.archs));
    if (info.minimumSystemVersion) {
      const v = String(info.minimumSystemVersion).replace(/\.0$/, '');
      setAll('minos', 'macOS ' + v + T(' trở lên', ' or later'));
    }
    if (info.sha256) {
      setAll('sha', info.sha256);
      $('#hash').hidden = false;
    }
  }
  // ---------- Báo lỗi / góp ý: mở issue GitHub điền sẵn mẫu theo ngôn ngữ đang xem ----------
  const REPO = 'https://github.com/KienHungPG/zMac';
  const FENCE = '```';
  const ISSUE = {
    bug: {
      label: 'bug',
      title: ['Lỗi: ', 'Bug: '],
      body: [
        `### Chuyện gì xảy ra?\n\n\n### Các bước làm lại\n1. \n2. \n\n### Đáng lẽ phải thế nào?\n\n\n### Máy\n- zMac: {v}\n- Đời Mac và macOS: \n\n<details><summary>Kết quả zMac --diagnose</summary>\n\n${FENCE}\n(dán vào đây, xoá phần không muốn công khai)\n${FENCE}\n\n</details>\n`,
        `### What happened?\n\n\n### Steps to reproduce\n1. \n2. \n\n### What did you expect?\n\n\n### Mac\n- zMac: {v}\n- Mac model and macOS: \n\n<details><summary>zMac --diagnose output</summary>\n\n${FENCE}\n(paste here, remove anything you'd rather not post)\n${FENCE}\n\n</details>\n`,
      ],
    },
    idea: {
      label: 'enhancement',
      title: ['Góp ý: ', 'Idea: '],
      body: [
        '### Bạn muốn zMac làm gì?\n\n\n### Hiện bạn dùng app nào cho việc này?\n\n\n### Ghi chú thêm\n\n',
        '### What should zMac do?\n\n\n### Which app do you use for this today?\n\n\n### Anything else\n\n',
      ],
    },
  };
  function renderIssueLinks() {
    const v = (info && info.version) || '0.1.0';
    for (const a of $$('[data-issue]')) {
      const it = ISSUE[a.dataset.issue];
      a.href = `${REPO}/issues/new?labels=${it.label}&title=${encodeURIComponent(T(...it.title))}` +
        `&body=${encodeURIComponent(T(...it.body).replace('{v}', v))}`;
    }
  }
  langHooks.push(renderDownload, renderIssueLinks);
  renderIssueLinks();
  fetch('download/latest.json', { cache: 'no-cache' })
    .then((r) => (r.ok ? r.json() : null))
    .then((j) => { if (j) { info = j; renderDownload(); renderIssueLinks(); } })
    .catch(() => { /* không có file thì giữ chữ mặc định */ });

  // =========================================================
  // Sân khấu: một màn hình, mỗi module một demo.
  // Demo chỉ chạy khi đang được chọn và đang nằm trong khung nhìn.
  // =========================================================
  const screen = $('#screen');
  const dim = $('#dim');
  const tabs = $$('.dock [role="tab"]');
  const caps = $$('.cap');
  const setDim = (v) => { dim.style.opacity = String(v); };
  let current = 'overview';
  let inView = false;

  // Kịch bản tự chạy; dừng hẳn khi người dùng chạm vào demo.
  function autoplay() {
    let token = 0;
    return {
      run(steps, loop) {
        const t = ++token;
        (async () => {
          do {
            for (const [ms, fn] of steps) {
              await sleep(ms);
              if (t !== token) return;
              fn();
            }
          } while (loop && t === token);
        })();
      },
      stop() { token++; },
    };
  }

  function makeDemo(def) {
    const d = { touched: false, loop: true, auto: autoplay(), timers: [], ...def };
    d.touch = () => { if (!d.touched) { d.touched = true; d.auto.stop(); } };
    d.every = (ms, fn) => { d.timers.push(setInterval(fn, ms)); };
    d.later = (ms, fn) => { d.timers.push(setTimeout(fn, ms)); };
    d.clear = () => { for (const id of d.timers) { clearInterval(id); clearTimeout(id); } d.timers = []; };
    return d;
  }

  const D = {};
  const startDemo = () => {
    const d = D[current];
    if (d.on) d.on();
    if (!d.touched && !reduced && d.script) d.auto.run(d.script(), d.loop);
  };
  const stopDemo = () => {
    const d = D[current];
    d.auto.stop();
    d.clear();
    if (d.off) d.off();
  };

  function activate(name, focusTab) {
    if (name !== current) {
      if (inView) stopDemo();
      $(`#demo-${current}`).classList.remove('on');
      current = name;
      screen.dataset.active = name;
      $(`#demo-${name}`).classList.add('on');
      screen.setAttribute('aria-labelledby', `tab-${name}`);
      for (const c of caps) c.hidden = c.dataset.for !== name;
      setDim(0);
      screen.classList.remove('asleep');
      if (D[name].render) D[name].render();
      if (inView) startDemo();
    }
    for (const t of tabs) {
      const on = t.dataset.demo === name;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      if (on && focusTab) t.focus();
    }
  }

  tabs.forEach((t, i) => {
    t.addEventListener('click', () => activate(t.dataset.demo));
    t.addEventListener('keydown', (e) => {
      const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
      let j = null;
      if (step) j = (i + step + tabs.length) % tabs.length;
      else if (e.key === 'Home') j = 0;
      else if (e.key === 'End') j = tabs.length - 1;
      if (j === null) return;
      e.preventDefault();
      activate(tabs[j].dataset.demo, true);
    });
  });

  const icon = (id) => {
    const s = document.createElementNS(SVG, 'svg');
    s.setAttribute('class', 'i');
    const u = document.createElementNS(SVG, 'use');
    u.setAttribute('href', '#' + id);
    s.append(u);
    return s;
  };
  const fillRange = (r) => r.style.setProperty('--p', ((r.value - r.min) / (r.max - r.min)) * 100 + '%');

  // ---------- Tổng quan: dãy icon gộp lại, popover mở ra ----------
  D.overview = makeDemo({
    on() {
      if (screen.classList.contains('intro')) return;
      screen.classList.add('intro');
      if (reduced) screen.classList.add('introdone');
      else setTimeout(() => screen.classList.add('introdone'), 1900);
    },
  });
  for (const b of $$('.pop-row')) b.addEventListener('click', () => activate(b.dataset.go));

  // ---------- Chuyển cửa sổ ----------
  D.switcher = (() => {
    const el = $('#demo-switcher');
    const wins = $$('.sw-win', el);
    const hud = $('#sw-hud');
    const items = $$('.hud-it', el);
    const title = $('#sw-title');
    const names = [
      ['Trình duyệt — zmac-website.vercel.app', 'Browser — zmac-website.vercel.app'],
      ['Ghi chú — Việc tuần này', 'Notes — This week'],
      ['Terminal — ~/zMac', 'Terminal — ~/zMac'],
      ['Thiết kế — Trang tải', 'Design — Download page'],
    ];
    let order = [0, 1, 2, 3];
    let open = false;
    let sel = 1;
    function render() {
      order.forEach((w, i) => {
        wins[w].style.zIndex = String(10 - i);
        wins[w].classList.toggle('front', i === 0);
      });
      hud.hidden = !open;
      for (const it of items) {
        const i = order.indexOf(Number(it.dataset.w));
        it.style.order = String(i);
        it.classList.toggle('sel', i === sel);
      }
      title.textContent = T(...names[order[sel]]);
    }
    const step = (dir) => {
      if (!open) { open = true; sel = dir > 0 ? 1 : order.length - 1; }
      else sel = (sel + dir + order.length) % order.length;
      render();
    };
    const raise = (w) => { order = [w, ...order.filter((x) => x !== w)]; open = false; sel = 1; render(); };
    const commit = () => { if (open) raise(order[sel]); };
    const d = makeDemo({
      render,
      script: () => [[900, () => step(1)], [700, () => step(1)], [700, () => step(1)], [800, commit], [1600, () => {}]],
      off() { open = false; render(); },
    });
    const user = (fn) => () => { d.touch(); fn(); };
    $('#sw-next').addEventListener('click', user(() => step(1)));
    $('#sw-prev').addEventListener('click', user(() => step(-1)));
    $('#sw-go').addEventListener('click', user(commit));
    for (const it of items) it.addEventListener('click', user(() => raise(Number(it.dataset.w))));
    for (const w of wins) w.addEventListener('pointerdown', user(() => raise(Number(w.dataset.w))));
    $('#sw-ctrl').addEventListener('keydown', (e) => {
      const fn = { ArrowRight: () => step(1), ArrowLeft: () => step(-1), Enter: commit, Escape: () => { open = false; render(); } }[e.key];
      if (!fn) return;
      e.preventDefault();
      d.touch();
      fn();
    });
    render();
    return d;
  })();

  // ---------- Chia cửa sổ ----------
  D.snap = (() => {
    // x, y, w, h tính theo % vùng desktop.
    const L = {
      left: { k: '←', x: 0, y: 0, w: 50, h: 100 }, right: { k: '→', x: 50, y: 0, w: 50, h: 100 },
      top: { k: '↑', x: 0, y: 0, w: 100, h: 50 }, bottom: { k: '↓', x: 0, y: 50, w: 100, h: 50 },
      tl: { x: 0, y: 0, w: 50, h: 50 }, tr: { x: 50, y: 0, w: 50, h: 50 },
      bl: { x: 0, y: 50, w: 50, h: 50 }, br: { x: 50, y: 50, w: 50, h: 50 },
      t1: { x: 0, y: 0, w: 100 / 3, h: 100 }, t2: { x: 100 / 3, y: 0, w: 100 / 3, h: 100 }, t3: { x: 200 / 3, y: 0, w: 100 / 3, h: 100 },
      tt1: { x: 0, y: 0, w: 200 / 3, h: 100 }, tt2: { x: 100 / 3, y: 0, w: 200 / 3, h: 100 },
      max: { x: 0, y: 0, w: 100, h: 100 }, center: { x: 20, y: 14, w: 60, h: 72 },
    };
    const KEYMAP = {
      ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'top', ArrowDown: 'bottom',
      u: 'tl', i: 'tr', j: 'bl', k: 'br', d: 't1', f: 't2', g: 't3', e: 'tt1', t: 'tt2', c: 'center',
    };
    const win = $('#snap-win');
    const zone = $('#snap-zone');
    const keys = $$('#snap-keys [data-snap]');
    let cur = 'center';
    const place = (el, l) => { for (const p of ['x', 'y', 'w', 'h']) el.style.setProperty('--' + p, l[p]); };
    function snap(name) {
      const l = L[name];
      if (!l) return;
      cur = name;
      place(zone, l);
      zone.classList.add('show');
      d.later(170, () => { place(win, l); zone.classList.remove('show'); });
      for (const b of keys) b.setAttribute('aria-pressed', String(b.dataset.snap === name));
    }
    const d = makeDemo({
      script: () => ['left', 'right', 'tl', 'br', 't1', 't2', 't3', 'tt1', 'max', 'center'].map((n) => [1100, () => snap(n)]),
      on() { place(win, L[cur]); },
      off() { zone.classList.remove('show'); place(win, L[cur]); },
    });
    for (const b of keys) b.addEventListener('click', () => { d.touch(); snap(b.dataset.snap); });
    $('#snap-keys').addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const name = KEYMAP[e.key] || KEYMAP[e.key.toLowerCase()];
      if (!name) return;
      e.preventDefault();
      d.touch();
      snap(name);
      const btn = keys.find((b) => b.dataset.snap === name);
      if (btn) btn.focus();
    });
    place(win, L.center);
    return d;
  })();

  // ---------- Clipboard ----------
  D.clipboard = (() => {
    const panel = $('#clip-panel');
    const q = $('#clip-q');
    const list = $('#clip-list');
    const out = $('#clip-out');
    const ph = $('.ph', out);
    const ITEMS = [
      { k: 'text', t: ['git push origin main', 'git push origin main'], pin: true },
      { k: 'link', t: ['https://zmac-website.vercel.app', 'https://zmac-website.vercel.app'] },
      { k: 'color', t: ['#FF8052', '#FF8052'] },
      { k: 'text', t: ['Họp thiết kế lúc 15:00, phòng 2', 'Design review at 3 pm, room 2'] },
      { k: 'image', t: ['Ảnh chụp màn hình 08.30', 'Screenshot 08.30'] },
      { k: 'text', t: ['12 Lý Thường Kiệt, Hoàn Kiếm, Hà Nội', '221B Baker Street, London'] },
      { k: 'text', t: ['defaults read com.zmac.app', 'defaults read com.zmac.app'] },
    ];
    const ICON = { text: 'i-text', link: 'i-link', image: 'i-image' };
    // Tìm không phân biệt dấu: "ha noi" khớp "Hà Nội".
    const norm = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[đĐ]/g, 'd').toLowerCase();
    const label = (it) => T(it.t[0], it.t[1]);
    let shown = [];
    let sel = 0;

    function render() {
      const query = norm(q.value.trim());
      shown = ITEMS.filter((it) => !query || norm(label(it)).includes(query));
      sel = Math.min(sel, Math.max(0, shown.length - 1));
      const rows = shown.map((it, i) => {
        const li = document.createElement('li');
        li.id = 'clip-o' + i;
        li.setAttribute('role', 'option');
        li.setAttribute('aria-selected', String(i === sel));
        if (i === sel) li.className = 'sel';
        const ck = document.createElement('span');
        ck.className = 'ck' + (it.k === 'color' ? ' sw' : it.k === 'image' ? ' img' : '');
        if (ICON[it.k] && it.k !== 'image') ck.append(icon(ICON[it.k]));
        const ct = document.createElement('span');
        ct.className = 'ct';
        ct.textContent = label(it);
        const cm = document.createElement('span');
        cm.className = 'cm';
        if (it.pin) cm.append(icon('i-pin'));
        else cm.textContent = '⌘' + (i + 1);
        li.append(ck, ct, cm);
        li.addEventListener('click', () => { d.touch(); sel = i; paste(); render(); });
        return li;
      });
      if (!rows.length) {
        const li = document.createElement('li');
        li.className = 'clip-empty';
        li.textContent = T('Không có gì khớp', 'No matches');
        rows.push(li);
      }
      list.replaceChildren(...rows);
      if (shown.length) q.setAttribute('aria-activedescendant', 'clip-o' + sel);
      else q.removeAttribute('aria-activedescendant');
    }
    function paste() {
      const it = shown[sel];
      if (!it) return;
      ph.hidden = true;
      const p = document.createElement('p');
      if (it.k === 'color') { const s = document.createElement('span'); s.className = 'swatch'; p.append(s); }
      if (it.k === 'image') { const s = document.createElement('span'); s.className = 'imgchip'; p.append(s); }
      p.append(label(it));
      out.append(p);
      while (out.querySelectorAll('p:not(.ph)').length > 6) out.querySelector('p:not(.ph)').remove();
    }
    const type = (ch) => { q.value += ch; sel = 0; render(); };
    const pick = (i) => { q.value = ''; sel = i; render(); };
    const reset = () => { q.value = ''; sel = 0; for (const p of $$('p:not(.ph)', out)) p.remove(); ph.hidden = false; render(); };
    function toggle(force) {
      const open = force ?? panel.classList.contains('closed');
      panel.classList.toggle('closed', !open);
      if (open) q.focus({ preventScroll: true });
    }
    const d = makeDemo({
      render,
      on() { if (!d.touched) reset(); },
      script: () => [
        [800, () => type('z')], [170, () => type('m')], [170, () => type('a')], [170, () => type('c')],
        [700, paste], [900, () => pick(0)], [600, () => pick(2)], [500, paste],
        [800, () => pick(3)], [500, paste], [1800, reset],
      ],
    });
    q.addEventListener('input', () => { d.touch(); sel = 0; render(); });
    q.addEventListener('pointerdown', () => d.touch());
    q.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        d.touch();
        if (shown.length) sel = (sel + (e.key === 'ArrowDown' ? 1 : -1) + shown.length) % shown.length;
        render();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        d.touch();
        paste();
      } else if (e.key === 'Escape') {
        d.touch();
        toggle(false);
      }
    });
    $('#clip-toggle').addEventListener('click', () => { d.touch(); toggle(); });
    render();
    return d;
  })();

  // ---------- Notch ----------
  D.notch = (() => {
    const notch = $('#notch');
    const TRACKS = [['Quiet Harbor', 'Lumen Drift', 185], ['Neon Rain', 'Ocean Static', 212], ['Late Bus Home', 'Paper Lanterns', 198]];
    const titleEl = $('#np-title');
    const artistEl = $('#np-artist');
    const curEl = $('#np-cur');
    const lenEl = $('#np-len');
    const progEl = $('#np-prog');
    const playUse = $('#np-play use');
    const fmt = (s) => `${Math.floor(s / 60)}:${pad(s % 60)}`;
    let track = 0;
    let pos = 42;
    let playing = true;
    let hoverT = 0;
    function renderNp() {
      const [t, a, len] = TRACKS[track];
      titleEl.textContent = t;
      artistEl.textContent = a;
      curEl.textContent = fmt(pos);
      lenEl.textContent = fmt(len);
      progEl.style.width = (pos / len) * 100 + '%';
      playUse.setAttribute('href', playing ? '#i-pause' : '#i-play');
    }
    const isOpen = () => notch.classList.contains('open');
    function setOpen(v) {
      notch.classList.toggle('open', v);
      screen.classList.toggle('notch-open', v);
    }
    function charge() {
      setOpen(false);
      notch.classList.add('charging');
      d.later(2800, () => notch.classList.remove('charging'));
    }
    const d = makeDemo({
      script: () => [[900, () => setOpen(true)], [3400, () => setOpen(false)], [900, charge], [3800, () => {}]],
      on() {
        notch.tabIndex = 0;
        renderNp();
        d.every(1000, () => {
          if (!playing) return;
          pos += 1;
          if (pos >= TRACKS[track][2]) { track = (track + 1) % TRACKS.length; pos = 0; }
          renderNp();
        });
      },
      off() {
        clearTimeout(hoverT);
        setOpen(false);
        notch.classList.remove('charging');
        notch.tabIndex = -1;
      },
    });
    notch.addEventListener('mouseenter', () => {
      if (current !== 'notch') return;
      d.touch();
      clearTimeout(hoverT);
      hoverT = setTimeout(() => setOpen(true), 80);
    });
    notch.addEventListener('mouseleave', () => {
      if (current !== 'notch') return;
      clearTimeout(hoverT);
      hoverT = setTimeout(() => setOpen(false), 300);
    });
    notch.addEventListener('click', (e) => {
      if (current !== 'notch' || e.target.closest('button')) return;
      d.touch();
      clearTimeout(hoverT);
      setOpen(!isOpen());
    });
    notch.addEventListener('keydown', (e) => {
      if (current !== 'notch' || e.target !== notch || (e.key !== 'Enter' && e.key !== ' ')) return;
      e.preventDefault();
      d.touch();
      setOpen(!isOpen());
    });
    $('#n-toggle').addEventListener('click', () => { d.touch(); setOpen(!isOpen()); });
    $('#n-plug').addEventListener('click', () => { d.touch(); charge(); });
    $('#np-play').addEventListener('click', () => { d.touch(); playing = !playing; renderNp(); });
    $('#np-next').addEventListener('click', () => { d.touch(); track = (track + 1) % TRACKS.length; pos = 0; renderNp(); });
    $('#np-prev').addEventListener('click', () => {
      d.touch();
      if (pos > 3) pos = 0;
      else { track = (track + TRACKS.length - 1) % TRACKS.length; pos = 0; }
      renderNp();
    });
    renderNp();
    return d;
  })();

  // ---------- Màn hình ----------
  D.display = (() => {
    const bi = $('#br-int');
    const be = $('#br-ext');
    const bio = $('#br-int-o');
    const beo = $('#br-ext-o');
    const tv = $('#tv');
    const tvDim = $('#tv-dim');
    const resBtns = $$('.res [data-res]');
    function apply() {
      fillRange(bi);
      fillRange(be);
      bio.textContent = bi.value + '%';
      beo.textContent = be.value + '%';
      if (current === 'display') setDim(((100 - bi.value) / 100) * 0.7);
      tvDim.style.opacity = String(((100 - be.value) / 100) * 0.85);
    }
    function res(r) {
      tv.dataset.res = r;
      for (const b of resBtns) b.setAttribute('aria-pressed', String(b.dataset.res === r));
    }
    const set = (r, v) => { r.value = v; apply(); };
    const d = makeDemo({
      on: apply,
      off() { setDim(0); },
      script: () => [
        [700, () => set(bi, 65)], [300, () => set(bi, 45)], [700, () => set(be, 35)], [800, () => res('1440')],
        [900, () => res('2160')], [900, () => set(be, 80)], [600, () => set(bi, 85)], [900, () => res('1080')], [1400, () => {}],
      ],
    });
    for (const r of [bi, be]) r.addEventListener('input', () => { d.touch(); apply(); });
    for (const b of resBtns) b.addEventListener('click', () => { d.touch(); res(b.dataset.res); });
    apply();
    return d;
  })();

  // ---------- Pin ----------
  D.battery = (() => {
    const panel = $('.bat');
    const pctEl = $('#bat-pct');
    const stateEl = $('#bat-state');
    const fillEl = $('#bat-fill');
    const mark = $('#bat-mark');
    const lim = $('#bat-lim');
    const limO = $('#bat-lim-o');
    const plugBtn = $('#bat-plug');
    const topBtn = $('#bat-top');
    let pct = 62;
    let plugged = true;
    let topup = false;
    let mode = 'charge';
    let n = 0;
    const target = () => (topup ? 100 : Number(lim.value));
    function tick() {
      const t = target();
      n += 1;
      if (plugged) {
        // Sailing: đang giữ thì chỉ sạc lại khi tụt quá 5% dưới ngưỡng.
        if (pct < t && (mode !== 'hold' || pct <= t - 5)) { pct += 1; mode = 'charge'; }
        else if (pct > t) { if (n % 3 === 0) pct -= 1; mode = 'drain'; }
        else { mode = 'hold'; if (topup && pct >= 100) topup = false; }
      } else {
        if (n % 4 === 0) pct = Math.max(5, pct - 1);
        mode = 'battery';
      }
      render();
    }
    function render() {
      const t = target();
      pctEl.textContent = pct + '%';
      fillEl.style.setProperty('--pct', pct + '%');
      mark.style.setProperty('--lim', String(Number(lim.value) / 100));
      limO.textContent = lim.value + '%';
      fillRange(lim);
      panel.classList.toggle('charging', plugged && mode === 'charge');
      panel.classList.toggle('low', pct <= 20);
      let s;
      if (mode === 'charge') s = T(`Đang sạc đến ${t}%`, `Charging to ${t}%`);
      else if (mode === 'drain') s = T(`Đang cắm điện, xả về ${t}%`, `Plugged in, discharging to ${t}%`);
      else if (mode === 'battery') s = T('Đang dùng pin', 'On battery');
      else if (pct < t) s = T(`Sailing: sạc lại khi dưới ${t - 5}%`, `Sailing: recharges below ${t - 5}%`);
      else s = T(`Giữ ở ${t}%, không sạc thêm`, `Holding at ${t}%, not charging`);
      stateEl.textContent = s;
      plugBtn.textContent = plugged ? T('Rút sạc', 'Unplug') : T('Cắm sạc', 'Plug in');
      topBtn.classList.toggle('on', topup);
    }
    const d = makeDemo({ render, on() { render(); d.every(140, tick); } });
    lim.addEventListener('input', () => { d.touch(); render(); });
    plugBtn.addEventListener('click', () => {
      d.touch();
      plugged = !plugged;
      if (plugged) {
        const t = target();
        mode = pct > t - 5 && pct <= t ? 'hold' : 'charge';
      }
      render();
    });
    topBtn.addEventListener('click', () => { d.touch(); topup = !topup; render(); });
    render();
    return d;
  })();

  // ---------- Âm thanh ----------
  D.sound = (() => {
    const rows = $$('#mix .mx');
    function upd(row) {
      const r = $('.rng', row);
      const m = $('.mute', row);
      const muted = m.getAttribute('aria-pressed') === 'true';
      fillRange(r);
      $('output', row).textContent = muted ? T('Tắt', 'Off') : r.value + '%';
      $('.meter i', row).style.setProperty('--v', (muted ? 0 : r.value) + '%');
      row.classList.toggle('muted', muted);
      $('use', m).setAttribute('href', muted ? '#i-mute' : '#i-sound');
    }
    const render = () => rows.forEach(upd);
    const flash = (row) => { row.classList.remove('flash'); void row.offsetWidth; row.classList.add('flash'); };
    const setVol = (row, v) => { $('.rng', row).value = v; upd(row); };
    const mute = (row) => { const m = $('.mute', row); m.setAttribute('aria-pressed', String(m.getAttribute('aria-pressed') !== 'true')); upd(row); };
    const setDev = (row, i) => { $('select', row).selectedIndex = i; flash(row); };
    const d = makeDemo({
      render,
      loop: false,
      script: () => [[1000, () => setVol(rows[3], 35)], [900, () => mute(rows[1])], [1000, () => setDev(rows[0], 2)], [1800, () => mute(rows[1])]],
    });
    for (const row of rows) {
      $('.rng', row).addEventListener('input', () => { d.touch(); upd(row); });
      $('.mute', row).addEventListener('click', () => { d.touch(); mute(row); });
      $('select', row).addEventListener('change', () => { d.touch(); flash(row); });
    }
    $('#mix-out').addEventListener('change', () => d.touch());
    render();
    return d;
  })();

  // ---------- Giữ máy thức ----------
  D.keepawake = (() => {
    const panel = $('#ka');
    const stateEl = $('#ka-state');
    const subEl = $('#ka-sub');
    const btns = $$('.ka-btns button');
    let until = null; // null: tắt; Infinity: đến khi tắt; số: mốc thời gian
    let chosen = -1;
    let sleepT = 0;
    const asleep = () => screen.classList.contains('asleep');
    function wake() { screen.classList.remove('asleep'); setDim(0); }
    function render() {
      const on = until !== null;
      panel.classList.toggle('awake', on);
      for (const b of btns) b.classList.toggle('on', Number(b.dataset.min) === chosen);
      if (!on) {
        stateEl.textContent = T('Đang tắt', 'Off');
        subEl.textContent = asleep()
          ? T('Mac đã ngủ. Chọn một mức để đánh thức.', 'The Mac fell asleep. Pick a duration to wake it.')
          : T('Mac ngủ theo cài đặt hệ thống', 'The Mac sleeps on its usual schedule');
        return;
      }
      stateEl.textContent = T('Mac sẽ không ngủ', 'The Mac stays awake');
      if (until === Infinity) { subEl.textContent = T('Đến khi bạn tắt', 'Until you turn it off'); return; }
      const s = Math.max(0, Math.round((until - Date.now()) / 1000));
      const h = Math.floor(s / 3600);
      const m = Math.floor((s % 3600) / 60);
      const left = h ? `${h}:${pad(m)}:${pad(s % 60)}` : `${m}:${pad(s % 60)}`;
      subEl.textContent = T(`Còn ${left}`, `${left} left`);
    }
    function scheduleSleep() {
      clearTimeout(sleepT);
      sleepT = setTimeout(() => {
        if (current !== 'keepawake' || until !== null) return;
        screen.classList.add('asleep');
        setDim(0.72);
        render();
      }, 4000);
    }
    function choose(min) {
      chosen = min;
      clearTimeout(sleepT);
      wake();
      if (min < 0) { until = null; scheduleSleep(); }
      else until = min === 0 ? Infinity : Date.now() + min * 60000;
      render();
    }
    const d = makeDemo({
      render,
      loop: false,
      script: () => [[5600, () => choose(60)]],
      on() {
        render();
        d.every(1000, render);
        if (until === null) scheduleSleep();
      },
      off() { clearTimeout(sleepT); wake(); },
    });
    for (const b of btns) b.addEventListener('click', () => { d.touch(); choose(Number(b.dataset.min)); });
    render();
    return d;
  })();

  langHooks.push(() => { if (D[current].render) D[current].render(); });

  // Màn hình ra khỏi khung nhìn thì dừng demo; quay lại thì chạy tiếp.
  if ('IntersectionObserver' in window) {
    new IntersectionObserver((entries) => {
      const v = entries[entries.length - 1].isIntersecting;
      if (v === inView) return;
      inView = v;
      screen.classList.toggle('paused', !v);
      if (v) startDemo(); else stopDemo();
    }, { threshold: 0.2 }).observe(screen);
  } else {
    inView = true;
    startDemo();
  }

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
      btn.textContent = T('Đã chép', 'Copied');
      setTimeout(() => { btn.textContent = lang === 'en' ? btn.dataset.en : original.get(btn).html; }, 1500);
    });
  }

  // ---------- Khởi động ----------
  const saved = store.get('lang');
  const prefersVi = (navigator.languages || [navigator.language || '']).some((l) => /^vi\b/i.test(l));
  const initial = saved === 'vi' || saved === 'en' ? saved : prefersVi ? 'vi' : 'en';
  if (initial === 'en') applyLang('en');
})();
