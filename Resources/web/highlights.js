/* highlights.js —— 標記與註記（docs/SPEC.md 第 12 節）。
 *
 * 網頁端是標記資料的唯一真相：合併、擦除、錨點比對都需要渲染後的文字位置，
 * 只有這裡拿得到。Swift 只負責讀寫 sidecar 檔、鏡像給側欄。
 *
 * 位置一律是「content.textContent 裡的偏移」（raw），只活在記憶體裡。
 * 存進 sidecar 的是引文錨點（exact / prefix / suffix / heading），而且是把
 * 空白連續段壓成一個之後的文字（norm）—— AI 重排換行時照樣對得上。
 */

'use strict';

(function () {
  const content = document.getElementById('content');
  const STYLES = ['green', 'blue', 'purple', 'pink', 'underline'];
  const NAMES = { green: '綠', blue: '藍', purple: '紫', pink: '粉', underline: '底線' };
  const CONTEXT = 32;          // 前後文各存幾個字
  const NOTE_IDLE = 500;       // 停手多久寫入註記
  const TIP_DELAY = 400;       // tooltip 出現前的延遲：掃過去不會跳出來

  /* ── 狀態 ──────────────────────────────────────────────
   * item：{ id, style, exact, prefix, suffix, heading, note, created,
   *         start, end（只在記憶體）, orphan, prevId（孤兒排序用） }
   */
  const H = {
    doc: null,              // 目前文件的路徑，存檔訊息帶著它，Swift 才不會寫錯檔
    items: [],
    writable: true,
    readOnlyReason: '',
  };
  let idx = null;           // 文字索引，每次繪製重建

  function toSwift(payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mb) {
      window.webkit.messageHandlers.mb.postMessage(payload);
    }
  }

  /* ── 文字來源（docs/SPEC.md 13.13）────────────────────────
   * 綁著 DOM 的幾件事：取全文、錨點的位置提示、選取換算成偏移、畫標記、找滑鼠下的標記。
   * 心得與 EPUB 用這裡的 DOM 版；PDF 的字在 canvas 上，由 bookpdf.js 提供（MBBook.pdfSource）。
   * 合併、擦除、註記、工具列、存檔這些第 12 節的規則只有一份，都在下面 */
  const domSource = {
    field: 'heading',                       // 錨點的位置提示存在哪個欄位
    ready: () => true,
    text: () => content.textContent,
    heads: () => headingOffsets(),
    groupAt: (raw) => headingAt(raw),       // 側欄分組
    offsetAt: (node, off) => offsetOf(node, off),
    clear: () => unwrapAll(),
    draw: (it) => wrap(it),
    highlightAt: () => null,                // DOM 版用事件的 target 就找得到
  };
  const src = () => (window.MBBook && window.MBBook.pdf && window.MBBook.pdfSource) || domSource;

  /* 滑鼠事件落在哪一條標記上（回傳那條標記的某個元素） */
  const highlightOf = (e) => (e.target.closest && e.target.closest('mark.mb-hl')) ||
    src().highlightAt(e.clientX, e.clientY);

  /* ── 文字索引 ──────────────────────────────────────────
   * raw：content.textContent。norm：空白連續段壓成一個空白。
   * 兩邊互查的對照表讓錨點在 norm 上比對、在 raw 上繪製。
   */
  const isSpace = (c) => /\s/.test(c);
  const normalize = (s) => (s || '').replace(/\s+/g, ' ');

  function buildIndex() {
    const raw = src().text();
    let norm = '';
    const n2r = [];
    const r2n = new Array(raw.length + 1);
    let inSpace = false;
    for (let i = 0; i < raw.length; i++) {
      r2n[i] = norm.length;
      if (isSpace(raw[i])) {
        if (!inSpace) { norm += ' '; n2r.push(i); inSpace = true; }
      } else {
        norm += raw[i]; n2r.push(i); inSpace = false;
      }
    }
    r2n[raw.length] = norm.length;
    n2r.push(raw.length);
    idx = { raw, norm, n2r, r2n, heads: src().heads() };
  }

  /* 每個標題前面有幾個字。一次走完整份文件，而不是每個標題各建一個 Range ——
   * 整本書串成一條時有幾百個標題，逐一 Range.toString() 是平方級的。 */
  function headingOffsets() {
    const els = [...content.querySelectorAll('h1, h2, h3, h4')];
    const heads = [];
    if (!els.length) return heads;
    let next = 0, pos = 0;
    const w = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    while (w.nextNode() && next < els.length) {
      const n = w.currentNode;
      if (n.nodeType === Node.TEXT_NODE) pos += n.data.length;
      else if (n === els[next]) { heads.push({ id: n.id, text: n.textContent.trim(), raw: pos }); next++; }
    }
    return heads;
  }

  function offsetOf(node, off) {
    const r = document.createRange();
    r.setStart(content, 0);
    r.setEnd(node, off);
    return r.toString().length;
  }

  function headingAt(rawPos) {
    let found = null;
    for (const h of idx.heads) { if (h.raw <= rawPos) found = h; else break; }
    return found;
  }

  /* ── 錨點 ──────────────────────────────────────────────
   * 1. 找出 exact 所有出現的位置
   * 2. 只出現一次就直接接上 —— 句子本身還在就是同一句，前後文被改了也一樣
   * 3. 出現多次就比前後文連續相同的字數，heading 相同再加分；同分取第一個
   */
  function commonSuffix(a, b) {
    let n = 0;
    while (n < a.length && n < b.length && a[a.length - 1 - n] === b[b.length - 1 - n]) n++;
    return n;
  }
  function commonPrefix(a, b) {
    let n = 0;
    while (n < a.length && n < b.length && a[n] === b[n]) n++;
    return n;
  }

  function locate(item) {
    const exact = normalize(item.exact).trim();
    if (!exact) return null;
    const hits = [];
    for (let at = idx.norm.indexOf(exact); at !== -1; at = idx.norm.indexOf(exact, at + 1)) hits.push(at);
    if (!hits.length) return null;

    let best = hits[0];
    if (hits.length > 1) {
      const prefix = normalize(item.prefix);
      const suffix = normalize(item.suffix);
      let bestScore = -1;
      for (const at of hits) {
        const before = idx.norm.slice(Math.max(0, at - prefix.length), at);
        const after = idx.norm.slice(at + exact.length, at + exact.length + suffix.length);
        let score = commonSuffix(prefix, before) + commonPrefix(suffix, after);
        const head = headingAt(idx.n2r[at]);
        if ((head ? head.id : null) === (item[src().field] ?? null)) score += 8;
        if (score > bestScore) { bestScore = score; best = at; }
      }
    }
    return { start: idx.n2r[best], end: idx.n2r[best + exact.length - 1] + 1 };
  }

  /* 把記憶體裡的位置寫回錨點欄位。只更新成功對上的；孤兒原封不動。
   * 這就是「搭便車更新前後文」—— 只在記憶體，等下一次使用者動作才寫檔。 */
  function refreshAnchors() {
    if (!idx) return;
    for (const it of H.items) {
      if (it.orphan) continue;
      const ns = idx.r2n[it.start];
      const ne = idx.r2n[it.end - 1] + 1;
      it.exact = idx.norm.slice(ns, ne).trim();
      it.prefix = idx.norm.slice(Math.max(0, ns - CONTEXT), ns);
      it.suffix = idx.norm.slice(ne, ne + CONTEXT);
      const head = headingAt(it.start);
      it[src().field] = head ? head.id : null;
    }
  }

  function reanchor() {
    for (const it of H.items) {
      const pos = locate(it);
      if (pos) { it.start = pos.start; it.end = pos.end; it.orphan = false; }
      else { it.orphan = true; it.start = it.end = -1; }
    }
  }

  /* ── 繪製 ──────────────────────────────────────────────
   * 搜尋命中也是 <mark>，而 clearHits 會把命中換回純文字 —— 標記包在命中裡面的話
   * 會被一起拆掉。所以先清命中、再重畫標記、最後把搜尋補回來。
   */
  function textNodes() {
    const out = [];
    const w = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    let pos = 0;
    while (w.nextNode()) {
      const n = w.currentNode;
      out.push({ n, s: pos, e: pos + n.data.length });
      pos += n.data.length;
    }
    return out;
  }

  function unwrapAll() {
    content.querySelectorAll('mark.mb-hl').forEach((m) => {
      const parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
      parent.normalize();
    });
  }

  function wrap(it) {
    let last = null;
    for (const { n, s, e } of textNodes()) {
      if (e <= it.start || s >= it.end) continue;
      if (!n.data.trim()) continue;          // 段落、儲存格之間的換行不要包
      const r = document.createRange();
      r.setStart(n, Math.max(it.start, s) - s);
      r.setEnd(n, Math.min(it.end, e) - s);
      const m = document.createElement('mark');
      m.className = 'mb-hl';
      m.dataset.style = it.style;
      m.dataset.id = it.id;
      r.surroundContents(m);
      last = m;
    }
    if (last && it.note) last.classList.add('mb-note-end');
  }

  function paint() {
    const find = window.MB && MB.internal;
    if (find) find.clearHits();
    src().clear();
    buildIndex();
    for (const it of anchored()) src().draw(it);
    if (find) find.rerunFind();
    mirror();
  }

  const anchored = () => H.items.filter((it) => !it.orphan).sort((a, b) => a.start - b.start);
  const orphans = () => H.items.filter((it) => it.orphan);
  const byId = (id) => H.items.find((it) => it.id === id);

  /* 側欄的鏡像：比對後的清單，每次異動送一次。 */
  function mirror() {
    const list = [...anchored(), ...orphans()].map((it) => {
      const head = it.orphan ? null : src().groupAt(it.start);
      return {
        id: it.id,
        style: it.style,
        text: it.orphan ? normalize(it.exact) : normalize(idx.raw.slice(it.start, it.end)).trim(),
        note: it.note || '',
        heading: it.orphan ? (it.heading ?? null) : (head ? head.id : null),
        headingText: head ? head.text : null,
        orphan: !!it.orphan,
      };
    });
    toSwift({ type: 'highlights', doc: H.doc, items: list });
  }

  /* ── 存檔 ──────────────────────────────────────────────
   * 只有使用者的動作才會走到這裡。鍵的順序固定、依原文位置排序，
   * 孤兒維持它上次在檔案裡的位置 —— git diff 只出現真正變動的那幾行。
   */
  function serialize() {
    refreshAnchors();
    const list = anchored();
    for (const o of orphans()) {
      const at = o.prevId ? list.findIndex((x) => x.id === o.prevId) : -1;
      list.splice(at === -1 ? Math.min(o.loadIndex ?? 0, list.length) : at + 1, 0, o);
    }
    if (!list.length) return null;
    const out = list.map((it) => {
      const o = { id: it.id, style: it.style, exact: it.exact, prefix: it.prefix, suffix: it.suffix };
      // PDF 的條目用 page 取代 heading，不寫 heading 鍵（docs/SPEC.md 12.4）
      if (src().field === 'page') { if (it.page != null) o.page = it.page; } else o.heading = it.heading ?? null;
      if (it.note) o.note = it.note;
      o.created = it.created;
      return o;
    });
    return JSON.stringify({ version: 1, highlights: out }, null, 2) + '\n';
  }

  function save() {
    if (!H.writable || !H.doc) return null;
    const json = serialize();
    rememberOrder();
    toSwift({ type: 'saveHighlights', doc: H.doc, json });
    return json;
  }

  /* 記下每條的前一條是誰：之後變成孤兒時才知道該排在哪裡。 */
  function rememberOrder() {
    const list = [...anchored(), ...orphans()];
    list.forEach((it, i) => { if (!it.orphan) { it.prevId = i ? list[i - 1].id : null; it.loadIndex = i; } });
  }

  function load(json) {
    H.items = [];
    if (!json) return;
    let data;
    try { data = JSON.parse(json); } catch (e) { return; }   // Swift 已經驗過，這裡只是保險
    (data.highlights || []).forEach((h, i, all) => {
      if (!h || !STYLES.includes(h.style) || typeof h.exact !== 'string') return;
      H.items.push({
        id: String(h.id || newId()),
        style: h.style,
        exact: h.exact,
        prefix: h.prefix || '',
        suffix: h.suffix || '',
        heading: h.heading ?? null,
        page: Number.isInteger(h.page) && h.page >= 1 ? h.page : null,
        note: typeof h.note === 'string' ? h.note : '',
        created: h.created || timestamp(),
        prevId: i ? String(all[i - 1].id) : null,
        loadIndex: i,
        orphan: false, start: -1, end: -1,
      });
    });
  }

  function newId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    let s;
    do { s = Array.from({ length: 8 }, () => chars[Math.floor(Math.random() * chars.length)]).join(''); }
    while (H.items.some((it) => it.id === s));
    return s;
  }

  function timestamp() {
    const d = new Date();
    const pad = (n) => String(Math.abs(n)).padStart(2, '0');
    const tz = -d.getTimezoneOffset();
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
      `${tz >= 0 ? '+' : '-'}${pad(Math.trunc(tz / 60))}:${pad(tz % 60)}`;
  }

  /* ── 建立、改色、擦除 ──────────────────────────────────
   * 建立時碰到既有標記就整條合併（畫線時手不準）；擦除只擦選到的部分（要精細）。
   */
  const touched = (s, e) => anchored().filter((it) => it.start < e && it.end > s);

  /* 緊接著、中間只隔空白或換行、而且同色的標記（docs/SPEC.md 12.2）。
   * 翻頁模式下一句話被切在頁尾，翻頁前後分兩次標，靠這條連成一筆。不同色不算：
   * 刻意把相鄰兩句標成不同顏色時要能分開。 */
  const adjacent = (s, e, style) => anchored().filter((it) => it.style === style &&
    ((it.end <= s && !idx.raw.slice(it.end, s).trim()) || (it.start >= e && !idx.raw.slice(e, it.start).trim())));
  const solid = (s, e) => s < e && idx.raw.slice(s, e).trim().length > 0;

  function create(range, style) {
    let { start, end } = range;
    const overlap = touched(start, end);
    const hit = [...overlap, ...adjacent(start, end, style).filter((it) => !overlap.includes(it))];
    for (const it of hit) { start = Math.min(start, it.start); end = Math.max(end, it.end); }
    const note = hit.map((it) => it.note).filter(Boolean).join('\n\n');   // 合併時註記依原文順序串接
    H.items = H.items.filter((it) => !hit.includes(it));
    const it = { id: newId(), style, start, end, note, created: timestamp(), orphan: false };
    H.items.push(it);
    paint();
    save();
    return it;
  }

  // 每條碰到的標記留下前後殘段，註記跟著前段走
  function erase(s, e) {
    for (const it of touched(s, e)) {
      const pieces = [];
      if (solid(it.start, s)) pieces.push([it.start, Math.min(s, it.end)]);
      if (solid(e, it.end)) pieces.push([Math.max(e, it.start), it.end]);
      H.items = H.items.filter((x) => x !== it);
      pieces.forEach(([a, b], i) => {
        H.items.push(i === 0
          ? { ...it, start: a, end: b }
          : { id: newId(), style: it.style, start: a, end: b, note: '', created: timestamp(), orphan: false });
      });
    }
    paint();
    save();
  }

  // 擦除會不會讓某條有註記的標記整條消失 —— 會的話按鈕要警示
  function eraseKillsNote(s, e) {
    return touched(s, e).some((it) => it.note && !solid(it.start, s) && !solid(e, it.end));
  }

  function remove(id) {
    H.items = H.items.filter((it) => it.id !== id);
    paint();
    save();
  }

  /* ── 選取 ──────────────────────────────────────────────
   * 整理規則：限縮在內文、去掉頭尾空白、只剩空白就不算。
   */
  function selectionRange() {
    const sel = window.getSelection();
    if (!sel.rangeCount || sel.isCollapsed) return null;
    const r = sel.getRangeAt(0);
    if (!r.intersectsNode(content)) return null;
    const all = document.createRange();
    all.selectNodeContents(content);
    const startInside = r.compareBoundaryPoints(Range.START_TO_START, all) >= 0;
    const endInside = r.compareBoundaryPoints(Range.END_TO_END, all) <= 0;
    let start = startInside ? src().offsetAt(r.startContainer, r.startOffset) : 0;
    let end = endInside ? src().offsetAt(r.endContainer, r.endOffset) : idx.raw.length;
    if (start == null || end == null) return null;
    while (start < end && isSpace(idx.raw[start])) start++;
    while (end > start && isSpace(idx.raw[end - 1])) end--;
    if (start >= end) return null;
    const rects = r.getClientRects();
    return { start, end, rect: rects.length ? rects[0] : r.getBoundingClientRect() };
  }

  /* ── 工具列 ────────────────────────────────────────────
   * ctx：{ mode: 'create', start, end } 選取中；{ mode: 'edit', id } 點了某條標記。
   */
  const bar = document.createElement('div');
  bar.id = 'hl-bar';
  document.body.appendChild(bar);
  const tip = document.createElement('div');
  tip.id = 'hl-tip';
  tip.innerHTML = '<div class="clamp"></div>';
  document.body.appendChild(tip);
  const banner = document.createElement('div');
  banner.id = 'hl-banner';
  banner.hidden = true;
  document.body.appendChild(banner);

  let ctx = null;
  let noteEditing = false;
  let anchorRect = null;
  let typingTimer = null;
  let savedAt = null;

  function place() {
    if (!anchorRect || !bar.classList.contains('show')) return;
    bar.style.left = '0px';
    bar.style.top = '0px';
    const w = bar.offsetWidth, h = bar.offsetHeight, r = anchorRect;
    let top = r.top + window.scrollY - h - 8;
    if (r.top - h - 8 < 0) top = r.bottom + window.scrollY + 8;     // 上方沒空間就放下面
    let left = r.left + window.scrollX + r.width / 2 - w / 2;
    left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
    bar.style.left = left + 'px';
    bar.style.top = top + 'px';
  }

  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function drawBar() {
    hideTip();
    const editing = ctx.mode === 'edit' ? byId(ctx.id) : null;
    const ro = !H.writable;

    // 刪除鍵常駐：建立模式下沒碰到標記就變灰；會擦光有註記的標記就警示
    let delLabel = '刪除', delDisabled = ro, delWarn = false;
    if (editing) { if (editing.note) { delLabel = '刪除（含註記）'; delWarn = true; } }
    else if (!touched(ctx.start, ctx.end).length) delDisabled = true;
    else if (eraseKillsNote(ctx.start, ctx.end)) { delLabel = '刪除（含註記）'; delWarn = true; }

    const noteText = editing ? (editing.note || '') : '';
    const showNote = !ro && (noteEditing || noteText) || (ro && noteText);
    bar.innerHTML =
      '<div class="row">' +
      STYLES.map((s) => `<button data-act="style" data-style="${s}" title="${NAMES[s]}"` +
        `${editing && editing.style === s ? ' class="cur"' : ''}${ro ? ' disabled' : ''}>` +
        (s === 'underline' ? '<span class="ul">底</span>' : `<span class="sw" data-style="${s}"></span>`) +
        '</button>').join('') +
      '<span class="sep"></span>' +
      `<button data-act="note"${ro ? ' disabled' : ''}>註記</button>` +
      '<button data-act="copy">拷貝</button>' +
      `<button data-act="delete"${delWarn ? ' class="warn"' : ''}${delDisabled ? ' disabled' : ''}>${delLabel}</button>` +
      '</div>' +
      (ro && H.readOnlyReason ? `<div class="ro">${esc(H.readOnlyReason)}</div>` : '') +
      (showNote
        ? '<div class="note">' + (noteEditing
          ? `<textarea placeholder="寫點什麼…" spellcheck="false">${esc(noteText)}</textarea>` +
            `<div class="hint">${savedAt ? `已自動儲存 ${savedAt}` : '自動儲存'}　清空即刪除註記</div>`
          : `<div class="note-view"${ro ? '' : ' title="點一下編輯"'}>${esc(noteText)}</div>`) + '</div>'
        : '');
    bar.classList.add('show');
    place();
    if (noteEditing) {
      const t = bar.querySelector('textarea');
      t.focus();
      t.setSelectionRange(t.value.length, t.value.length);
    }
  }

  function hideBar() {
    commitNote();
    bar.classList.remove('show');
    setActive(null);
    ctx = null;
    noteEditing = false;
    savedAt = null;
  }

  function setActive(id) {
    content.querySelectorAll('.mb-hl.mb-active').forEach((m) => m.classList.remove('mb-active'));
    if (id) content.querySelectorAll(`.mb-hl[data-id="${id}"]`).forEach((m) => m.classList.add('mb-active'));
  }

  function openEdit(id, withNote) {
    // 同一條也要先寫：重畫工具列時輸入框會跟著消失
    if (ctx && ctx.mode === 'edit') commitNote();
    const first = content.querySelector(`.mb-hl[data-id="${id}"]`);
    if (!first) { hideBar(); return; }
    if (!ctx || ctx.id !== id) savedAt = null;
    ctx = { mode: 'edit', id };
    noteEditing = !!withNote;
    setActive(id);
    anchorRect = first.getClientRects()[0];
    drawBar();
  }

  /* ── 註記：沒有存檔鍵、沒有取消 ─────────────────────────
   * 停手 500 ms 寫一次，任何關掉輸入框的動作再寫一次。檔案隨時可能被 AI 改寫
   * 觸發重載，「關掉才存」會在最不該丟的時候丟。
   */
  function commitNote() {
    clearTimeout(typingTimer);
    typingTimer = null;
    const t = bar.querySelector('textarea');
    if (!t || !ctx || ctx.mode !== 'edit') return null;
    const it = byId(ctx.id);
    if (!it) return null;                     // 標記已經被刪了
    const text = t.value.trim();
    if (text === (it.note || '')) return null;
    it.note = text;
    const id = ctx.id;
    paint();
    setActive(id);
    savedAt = new Date().toLocaleTimeString('zh-TW', { hour12: false });
    return save();
  }

  bar.addEventListener('input', (e) => {
    if (e.target.tagName !== 'TEXTAREA') return;
    clearTimeout(typingTimer);
    const hint = bar.querySelector('.hint');
    if (hint) hint.textContent = '輸入中…';
    typingTimer = setTimeout(() => {
      commitNote();
      const h = bar.querySelector('.hint');
      if (h) h.textContent = `已自動儲存 ${savedAt || new Date().toLocaleTimeString('zh-TW', { hour12: false })}　清空即刪除註記`;
    }, NOTE_IDLE);
  });

  // 保住選取；但輸入框要能拿到焦點
  bar.addEventListener('mousedown', (e) => { if (!e.target.closest('textarea')) e.preventDefault(); });

  bar.addEventListener('click', (e) => {
    if (e.target.closest('.note-view')) {
      if (!H.writable) return;
      noteEditing = true;
      drawBar();
      return;
    }
    const b = e.target.closest('button');
    if (!b || b.disabled || !ctx) return;
    const act = b.dataset.act;

    if (act === 'copy') {
      const r = ctx.mode === 'edit' ? byId(ctx.id) : ctx;
      toSwift({ type: 'copy', text: idx.raw.slice(r.start, r.end).trim() });
      window.getSelection().removeAllRanges();
      hideBar();
      return;
    }
    if (act === 'delete') {
      if (ctx.mode === 'edit') { const id = ctx.id; ctx = null; noteEditing = false; remove(id); }
      else erase(ctx.start, ctx.end);
      window.getSelection().removeAllRanges();
      hideBar();
      return;
    }
    if (act === 'style') {
      if (ctx.mode === 'edit') {
        const id = ctx.id, keep = noteEditing;
        commitNote();
        byId(id).style = b.dataset.style;
        paint();
        save();
        openEdit(id, keep);
      } else {
        create(ctx, b.dataset.style);
        window.getSelection().removeAllRanges();
        ctx = null;
        hideBar();
      }
      return;
    }
    if (act === 'note') {
      if (ctx.mode === 'edit' && noteEditing) { commitNote(); noteEditing = false; openEdit(ctx.id); return; }
      let id = ctx.id;
      if (ctx.mode === 'create') {
        // 先建立再開輸入框：碰到既有標記就沿用它的顏色，否則用預設的綠
        const hit = touched(ctx.start, ctx.end);
        id = create(ctx, hit.length ? hit[0].style : 'green').id;
        window.getSelection().removeAllRanges();
        ctx = null;
      }
      openEdit(id, true);
    }
  });

  content.addEventListener('mouseup', () => {
    setTimeout(() => {
      if (!idx || !src().ready()) return;
      const s = selectionRange();
      if (!s) return;
      commitNote();
      setActive(null);
      noteEditing = false;
      savedAt = null;
      ctx = { mode: 'create', start: s.start, end: s.end };
      anchorRect = s.rect;
      drawBar();
    }, 0);
  });

  content.addEventListener('click', (e) => {
    if (e.target.closest('a')) return;                    // 連結優先
    const m = highlightOf(e);
    if (!m || !window.getSelection().isCollapsed) return;
    openEdit(m.dataset.id);
  });

  document.addEventListener('mousedown', (e) => {
    hideTip();
    if (bar.contains(e.target) || banner.contains(e.target)) return;
    if (highlightOf(e) && !e.target.closest('a')) return;
    if (bar.classList.contains('show')) hideBar();
  });

  document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'TEXTAREA' && bar.contains(e.target)) {
      // Cmd Return 與 Esc 都只是「關掉」，關掉就寫入
      if ((e.key === 'Enter' && e.metaKey) || e.key === 'Escape') { e.preventDefault(); hideBar(); }
      return;
    }
    if (e.target.tagName === 'INPUT') return;               // 搜尋框
    if (!bar.classList.contains('show')) return;
    if (e.key === 'Escape') { hideBar(); return; }
    if (e.key === 'Backspace' || e.key === 'Delete') {
      const btn = bar.querySelector('[data-act=delete]');
      if (btn && !btn.disabled) { e.preventDefault(); btn.click(); }
    }
  });

  window.addEventListener('resize', place);

  /* ── 註記 tooltip ──────────────────────────────────────
   * 放在整條標記第一行的上方（不蓋到標記本身），上方沒空間就放到最後一行下方。
   */
  let tipTimer = null, tipId = null;

  function hideTip() {
    clearTimeout(tipTimer);
    tipTimer = null;
    tipId = null;
    tip.classList.remove('show');
  }

  function showTip(it) {
    if (bar.classList.contains('show')) return;          // 工具列開著時不顯示
    const rects = [...content.querySelectorAll(`.mb-hl[data-id="${it.id}"]`)].flatMap((m) => [...m.getClientRects()]);
    if (!rects.length) return;
    tip.firstElementChild.textContent = it.note;
    tip.classList.add('show');
    tip.style.left = '0px';
    tip.style.top = '0px';
    const first = rects[0], last = rects[rects.length - 1];
    const w = tip.offsetWidth, h = tip.offsetHeight;
    let top = first.top + window.scrollY - h - 6;
    if (first.top - h - 6 < 0) top = last.bottom + window.scrollY + 6;
    const left = Math.max(8, Math.min(first.left + window.scrollX, window.innerWidth - w - 8));
    tip.style.left = left + 'px';
    tip.style.top = top + 'px';
  }

  function hoverOn(m) {
    const it = byId(m.dataset.id);
    if (!it || !it.note || tipId === it.id) return;      // 同一條的另一塊 <mark> 不重新計時
    hideTip();
    tipId = it.id;
    tipTimer = setTimeout(() => showTip(it), TIP_DELAY);
  }

  content.addEventListener('mouseover', (e) => {
    const m = e.target.closest('mark.mb-hl');
    if (m) hoverOn(m);
  });

  /* PDF 的標記框收不到滑鼠（文字層在上面），移過與游標用座標判斷 */
  content.addEventListener('mousemove', (e) => {
    if (src() === domSource) return;
    const m = src().highlightAt(e.clientX, e.clientY);
    const page = e.target.closest && e.target.closest('.mb-pdf-page');
    content.querySelectorAll('.mb-hl-hover').forEach((el) => { if (el !== page || !m) el.classList.remove('mb-hl-hover'); });
    if (page && m) page.classList.add('mb-hl-hover');
    if (m) hoverOn(m);
    else if (tipId) hideTip();
  });
  content.addEventListener('mouseout', (e) => {
    const from = e.target.closest('mark.mb-hl');
    if (!from) return;
    const to = e.relatedTarget && e.relatedTarget.closest ? e.relatedTarget.closest('mark.mb-hl') : null;
    if (to && to.dataset.id === from.dataset.id) return;
    hideTip();
  });
  window.addEventListener('scroll', hideTip, { passive: true });
  content.addEventListener('scroll', hideTip, { passive: true });   // 書的翻頁模式

  /* ── 警示列：寫入失敗、唯讀的原因 ───────────────────── */
  banner.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) toSwift({ type: 'bannerAction', id: b.dataset.id });
  });

  /* ── 給 app.js 與 Swift 的介面 ───────────────────────── */

  const HL = {};
  window.MBHighlights = HL;

  /* PDF 開檔：舊的文字索引對不上新內容，全文抽完 afterRender 才重建。標記清單留著，重載時沿用 */
  HL.suspend = function () {
    if (bar.classList.contains('show')) hideBar();
    hideTip();
    idx = null;
  };

  /* MB.render 換內容之前：把位置寫回錨點欄位（新內容一來位置就失效了），
   * 正在打的註記先寫入。 */
  HL.beforeRender = function () {
    if (!idx) return null;
    commitNote();
    refreshAnchors();
    hideTip();
    return ctx ? { mode: ctx.mode, id: ctx.id, note: noteEditing } : null;
  };

  /* 內容換好之後：重新比對、重畫。`payload` 只在換檔或 sidecar 被外部改動時才有，
   * 平常重載沿用記憶體裡的標記（那才是唯一的真相）。 */
  HL.afterRender = function (payload, kept) {
    if (payload) {
      H.doc = payload.doc;
      H.writable = payload.writable !== false;
      H.readOnlyReason = payload.reason || '';
      load(payload.json);
      kept = null;
    }
    buildIndex();
    reanchor();
    paint();

    // 重載當下正在操作的東西：建立模式一律關（選取範圍已經失效），
    // 編輯模式那條還在就重新定位，不在就關掉
    bar.classList.remove('show');
    ctx = null;
    noteEditing = false;
    setActive(null);
    if (kept && kept.mode === 'edit' && byId(kept.id) && !byId(kept.id).orphan) {
      // 等捲軸回位之後再定位，否則工具列會停在舊的座標
      requestAnimationFrame(() => openEdit(kept.id, kept.note));
    }
  };

  /* sidecar 被外部改動（git pull、checkout）：外部的內容為準。
   * 不能像重載那樣先寫入註記 —— 那會拿記憶體裡的舊清單蓋掉外部的改動。
   * 改成先記下打到一半的字，載入新內容後同一條還在就補進去再寫。 */
  MB.setHighlights = function (payload) {
    // PDF 的全文還沒抽完：先交給 bookpdf.js 存著，抽完一起比對
    if (!src().ready()) { window.MBBook.pdfStashHighlights(payload); return; }
    clearTimeout(typingTimer);
    const t = bar.querySelector('textarea');
    const pending = t && ctx && ctx.mode === 'edit' ? { id: ctx.id, text: t.value.trim() } : null;
    const kept = ctx && ctx.mode === 'edit' ? { mode: 'edit', id: ctx.id, note: noteEditing } : null;
    hideTip();
    bar.innerHTML = '';                       // 輸入框拿掉，hideBar 之類的路徑就不會再寫一次舊的
    HL.afterRender(payload, null);
    if (pending) {
      const it = byId(pending.id);
      if (it && !it.orphan && pending.text !== (it.note || '')) { it.note = pending.text; paint(); save(); }
    }
    if (kept && byId(kept.id) && !byId(kept.id).orphan) requestAnimationFrame(() => openEdit(kept.id, kept.note));
  };

  MB.setHighlightBanner = function (text, actions) {
    if (!text) { banner.hidden = true; banner.innerHTML = ''; return; }
    banner.innerHTML = `<span>${esc(text)}</span>` +
      (actions || []).map((a) => `<button data-id="${esc(a.id)}">${esc(a.label)}</button>`).join('');
    banner.hidden = false;
  };

  MB.revealHighlight = function (id) {
    hideBar();
    const marks = [...content.querySelectorAll(`.mb-hl[data-id="${id}"]`)];
    if (!marks.length) return;
    MB.internal.reveal(marks[0], true, 'center');
    setTimeout(() => marks.forEach((m) => {
      m.classList.remove('mb-flash');
      void m.offsetWidth;                              // 重設動畫
      m.classList.add('mb-flash');
    }), 350);
  };

  MB.deleteHighlight = function (id) {
    if (!H.writable) return;
    if (ctx && ctx.mode === 'edit' && ctx.id === id) { ctx = null; noteEditing = false; bar.classList.remove('show'); }
    remove(id);
  };

  /* Shift Cmd H：選取範圍直接套綠色。回傳有沒有建立，Swift 沒建立就發提示音。 */
  MB.highlightSelection = function () {
    if (!idx || !H.writable) return false;
    const s = selectionRange();
    if (!s) return false;
    if (bar.classList.contains('show')) hideBar();
    create(s, 'green');
    window.getSelection().removeAllRanges();
    return true;
  };

  /* 視窗失去焦點、換檔、關窗前：先把註記寫入並關掉輸入框。
   * 回傳寫入的內容，讓關窗時 Swift 能在網頁端消失前自己寫檔。 */
  MB.commitNote = function () {
    const json = commitNote();
    if (noteEditing) { noteEditing = false; if (ctx) drawBar(); }
    return json;
  };

  /* 認領孤兒 sidecar：拿別的 sidecar 來試比對，回報對得上幾條。不改任何狀態。 */
  MB.probeHighlights = function (candidates) {
    // PDF 的全文還沒抽完：比不了，當作一條都對不上（只是不主動提議認領）
    if (!src().ready()) return (candidates || []).map((c) => ({ name: c.name, matched: 0, total: 0 }));
    if (!idx) buildIndex();
    return (candidates || []).map((c) => {
      let list = [];
      try { list = JSON.parse(c.json).highlights || []; } catch (e) { /* 壞檔當作 0 條 */ }
      const matched = list.filter((h) => h && typeof h.exact === 'string' && locate(h)).length;
      return { name: c.name, matched, total: list.length };
    });
  };
})();
