/* bookpdf.js —— 書那欄的 PDF（docs/SPEC.md 13.13）。
 *
 * 照原樣顯示頁面，不套我們的樣式：每頁一個 canvas，由 pdf.js 畫。PDF 從 mbres://book/ 讀，
 * worker 從 mbres://app/vendor/pdfjs/ 載入（實測是真的背景 Worker）。
 *
 * canvas 上疊一層 pdf.js 的透明文字層，拿來選字、複製；文字層用全文那份正規化過的
 * textContent 畫，跟全文的字一模一樣。
 *
 * 只畫畫面附近幾頁：300 頁全部畫出來要 1～2 GB。頁框的長寬比一開始就照每頁的尺寸排好，
 * 捲軸長度與閱讀位置不必等頁面畫完；離開範圍的頁把 canvas 收掉。
 */

'use strict';

(function () {
  const content = document.getElementById('content');
  const BK = window.MBBook;
  const I = () => MB.internal;

  let lib = null;
  async function pdfjs() {
    if (!lib) {
      // book.js 是一般 script，pdf.js 只有 ES module 版，用動態 import 載
      lib = await import('./vendor/pdfjs/pdf.min.mjs');
      lib.GlobalWorkerOptions.workerSrc = 'vendor/pdfjs/pdf.worker.min.mjs';
    }
    return lib;
  }

  const P = {
    gen: 0,          // 每次開檔加一；晚到的非同步結果對不上就丟掉
    doc: null,
    pages: [],       // [{w, h, box, canvas, task, drawnWidth, layer}]
    observer: null,
    near: new Set(), // 在畫面附近、該畫的頁
    paged: false,    // 單頁、雙頁（docs/SPEC.md 13.13）：只顯示目前這組跨頁
    cur: 0,          // 翻頁模式下目前所在頁（0 起算）：跳轉時是目標那頁，不換成跨頁的第一頁 ——
                     // 雙頁時章首常在右頁，換成左頁就會被算成上一章（章名、Home／End 都錯）
    spreads: [],
    pageLayout: '',  // PDF 的 /PageLayout，決定雙頁怎麼配對
    pendingSync: null, // 書籤還沒讀好時送來的同步要求，讀好再做
    toc: [],         // 書籤攤平：[{label, level, page, ratio}]，page 從 1 開始；對不到頁的 page 為 null
    text: null,      // 全文，抽完才有：{pages: [textContent…], strings: [每頁字串], full, starts: [每頁在 full 的起點], hasText}
  };

  /* ── 開檔 ───────────────────────────────────────────── */

  BK.renderPdf = async function (payload, opts) {
    const keep = opts.keepScroll ? BK.pdfAnchor() : null;
    teardown();
    const gen = P.gen;
    content.innerHTML = '<div id="mb-pdf"></div>';
    I().toSwift({ type: 'outline', outline: [] });
    // 標記要等全文抽完才能比對（docs/SPEC.md 13.13）。重載（keepScroll）不帶標記，沿用記憶體裡的
    P.hlPayload = opts.highlights || null;
    if (window.MBHighlights) window.MBHighlights.suspend();

    let doc;
    try {
      const pdf = await pdfjs();
      doc = await pdf.getDocument({ url: 'mbres://book/' + payload.pdf }).promise;
    } catch (e) {
      if (gen === P.gen) MB.renderBookError('無法開啟這個 PDF');
      return;
    }
    if (gen !== P.gen) { doc.destroy(); return; }
    P.doc = doc;

    // 每頁的尺寸一次問完（並行送給 worker），排好頁框才能回到閱讀位置
    const sizes = await Promise.all(Array.from({ length: doc.numPages }, (_, i) =>
      doc.getPage(i + 1).then((page) => {
        const vp = page.getViewport({ scale: 1 });
        return { w: vp.width, h: vp.height };
      })));
    if (gen !== P.gen) return;
    try { P.pageLayout = (await doc.getPageLayout()) || ''; } catch (e) { P.pageLayout = ''; }
    if (gen !== P.gen) return;

    const root = content.querySelector('#mb-pdf');
    P.pages = sizes.map((s) => {
      const box = document.createElement('div');
      box.className = 'mb-pdf-page';
      box.style.aspectRatio = `${s.w} / ${s.h}`;
      root.appendChild(box);
      return { w: s.w, h: s.h, box, canvas: null, task: null, drawnWidth: 0, layer: null };
    });
    scaleBoxes();

    const target = keep || payload.position;
    P.paged = BK.layout !== 'scroll';
    if (P.paged) { P.cur = target && typeof target.page === 'number' ? target.page - 1 : 0; layoutPaged(); }
    else if (target && typeof target.page === 'number') restore(target);
    else window.scrollTo(0, 0);

    P.observer = new IntersectionObserver(onIntersect, { rootMargin: '150% 0px' });
    P.pages.forEach((p) => P.observer.observe(p.box));
    I().toSwift({ type: 'bookPosition', chapter: null, turned: false });

    // 第一頁先畫，書籤與全文在背景讀；標記、引文、搜尋都等全文
    loadOutline(doc, gen);
    extractText(doc, gen, !opts.keepScroll);
  };

  function teardown() {
    P.gen += 1;
    if (P.observer) P.observer.disconnect();
    P.observer = null;
    P.pages.forEach(release);
    P.pages = [];
    P.paged = false;
    document.documentElement.classList.remove('mb-pdf-paged');
    indicator.hidden = true;
    P.near.clear();
    P.text = null;
    P.hlPayload = null;
    P.quoteAll = null;   // 全書的引文比對用字串，第一次找全書時才建
    P.findText = null;   // 搜尋用的全書字串，第一次搜尋時才建
    P.hits = [];
    P.toc = [];
    P.pendingSync = null;
    P.tocLoaded = false;
    if (P.doc) P.doc.destroy();
    P.doc = null;
  }
  BK.pdfTeardown = teardown;

  /* ── 書籤（docs/SPEC.md 13.13）──────────────────────────────
   * 攤平成一列，順序與層級照書籤樹，跟 EPUB 的 nav 一樣當「章」用。每一項解析到第幾頁、
   * 頁內多高，所在章與跳到某章都靠這個。沒有書籤也送一個空的給 Swift：側欄才知道要寫「沒有目錄」。 */

  async function loadOutline(doc, gen) {
    let outline = null;
    try { outline = await doc.getOutline(); } catch (e) { /* 當作沒有書籤 */ }
    const flat = [];
    const walk = (items, level) => (items || []).forEach((it) => {
      flat.push({ label: (it.title || '').trim(), level, dest: it.dest });
      walk(it.items, level + 1);
    });
    walk(outline, 1);
    const toc = [];
    for (const item of flat) {
      const at = await resolveDest(doc, item.dest);
      if (gen !== P.gen) return;
      toc.push({ label: normalizeText(item.label), level: item.level, page: at ? at.page : null, ratio: at ? at.ratio : 0 });
    }
    P.toc = toc;
    P.tocLoaded = true;
    I().toSwift({ type: 'bookToc', toc: toc.map(({ label, level }) => ({ label, level })) });
    flushPendingSync();
    // 開檔時回報的位置還不知道章，書籤讀好再報一次
    I().toSwift({ type: 'bookPosition', chapter: BK.pdfChapter(), turned: false });
  }

  /* 心得帶動書（docs/SPEC.md 13.13）：章靠書籤，小節靠標題關鍵詞，引文找原句。
   * 換心得或剛開檔時，Swift 送來的同步可能比書籤、全文先到，先存著 */
  BK.pdfSyncTo = function (req) {
    const wantsText = (req.quote || (req.text && !req.quiet)) && P.text == null;
    if (!P.tocLoaded || wantsText) { P.pendingSync = req; return; }
    if (req.quote) { syncQuote(req); return; }
    const chapter = (req.chapters || []).find((i) => P.toc[i] && P.toc[i].page != null);
    if (chapter == null) {
      if (!P.toc.length) MB.toast('這份 PDF 沒有目錄');
      return;
    }
    // 點的是小節標題：拿標題文字去這一章的全文找，跟 EPUB「標題對不到」的退路一樣（docs/SPEC.md 13.6）。
    // 點的是章名（quiet）就不找，章首正是要去的地方
    if (req.text && !req.quiet && P.text.hasText) {
      const { text, where } = keyText(pagesOf([chapter]), (c) => (/\s/.test(c) ? '' : c));
      const word = BK.longestKeyword(text, req.text);
      if (word) { land(spot(where, text.indexOf(word), word.length), req, `依關鍵詞「${word}」對到內文`); return; }
    }
    land(chapterStart(chapter), req, req.text && !req.quiet ? '找不到對應小節，已跳到章首' : null);
  };

  /* 引文找原句：比對規則與 EPUB 相同（去標點空白、異體字歸一，book.js 的 quoteFind）。
   * 先找這一章（含部分對到），才找全書；都找不到退回章首（docs/SPEC.md 13.13） */
  function syncQuote(req) {
    const chapters = (req.chapters || []).filter((i) => P.toc[i] && P.toc[i].page != null);
    const fallback = (note) => {
      if (chapters.length) land(chapterStart(chapters[0]), req, note + '，已跳到這一章開頭');
      else MB.toast(note);
    };
    if (!P.text.hasText) { fallback('這份 PDF 沒有文字可以比對'); return; }
    // 引文就是章名（心得檔頭的「選擇2 累積人生籌碼」）：到那一章章首
    const key = BK.quoteKey(req.quote);
    const titled = P.toc.findIndex((t) => t.page != null && BK.quoteKey(t.label) === key);
    if (titled !== -1) { land(chapterStart(titled), req, null); return; }

    const inChapter = chapters.length ? keyText(pagesOf(chapters), BK.quoteChar) : null;
    let found = inChapter && (BK.quoteFind(inChapter.text, req.quote, false) || BK.quoteFind(inChapter.text, req.quote, true));
    let src = inChapter;
    if (!found) {
      if (!P.quoteAll) P.quoteAll = keyText(P.pages.map((_, i) => i), BK.quoteChar);
      src = P.quoteAll;
      found = BK.quoteFind(src.text, req.quote, false) || (!chapters.length && BK.quoteFind(src.text, req.quote, true));
    }
    if (!found) { fallback('書裡找不到這段引文'); return; }
    land(spot(src.where, found.at, found.length), req, found.whole ? null : '書裡沒有完全相同的句子，已跳到最接近的一段');
  }

  function flushPendingSync() {
    if (!P.pendingSync) return;
    const req = P.pendingSync;
    P.pendingSync = null;
    BK.pdfSyncTo(req);
  }

  /* 這一章：從它的書籤所在頁，到下一個有頁碼的書籤所在頁（含）。頁內的起點不細分 —— 前一章的
   * 結尾若跟這章章首同一頁，多搜那半頁無妨 */
  function chapterPages(index) {
    const start = P.toc[index].page;
    let end = P.pages.length;
    for (let i = index + 1; i < P.toc.length; i++) {
      if (P.toc[i].page != null && P.toc[i].page > start) { end = P.toc[i].page; break; }
    }
    return [start, end];
  }

  /* 幾章合起來涵蓋的頁（0 起算、由小到大、不重複） */
  function pagesOf(chapters) {
    const set = new Set();
    for (const c of chapters) {
      const [from, to] = chapterPages(c);
      for (let pg = from - 1; pg < to; pg++) set.add(pg);
    }
    return [...set].sort((x, y) => x - y);
  }

  function chapterStart(index) {
    const t = P.toc[index];
    return { page: t.page, top: t.ratio, boxes: null };
  }

  /* 把幾頁的字逐字轉換（mapChar 回傳空字串就丟掉，可能一變多）後串起來，記下每個字出自哪頁哪個位置 */
  function keyText(pages, mapChar) {
    let text = '';
    const where = [];
    for (const pg of pages) {
      const s = P.text.strings[pg];
      for (let i = 0; i < s.length; i++) {
        const c = mapChar(s[i]);
        for (const x of c) { text += x; where.push([pg, i]); }
      }
    }
    return { text, where };
  }

  /* text 裡 [at, at+length) 這段 → 落點：起點所在頁、頁內高度、每一行字的框 */
  function spot(where, at, length) {
    const [pg, a] = where[at];
    const [endPg, b] = where[at + length - 1];
    const boxes = [];
    for (let p = pg; p <= endPg; p++) {
      const from = p === pg ? a : 0;
      const to = p === endPg ? b : P.text.strings[p].length - 1;
      for (const rect of lineRects(p, from, to)) boxes.push({ page: p + 1, rect });
    }
    return { page: pg + 1, top: boxes.length ? boxes[0].rect.top : 0, boxes };
  }

  /* 頁字串裡 [a, b] 這段字的框，一行一個，以頁的比例表示（0～1，由上往下）。
   * 引文常跨好幾行，合成一個大框會連旁邊沒選到的字一起閃 */
  function lineRects(pg, a, b) {
    const items = P.text.pages[pg].items;
    const p = P.pages[pg];
    const lines = [];
    items.forEach((item, i) => {
      if (!item.str || !item.transform) return;
      const s = P.text.itemStarts[pg][i], e = s + item.str.length - 1;
      if (e < a || s > b) return;
      const [, , , d, x, y] = item.transform;
      const h = item.height || Math.abs(d);
      // 一個項目常是半行字：照字數比例裁到真正那幾個字（中文等寬，誤差在一兩個字內）
      const n = item.str.length;
      const from = (Math.max(a, s) - s) / n, to = Math.min(n, Math.min(b, e) - s + 1) / n;
      // y 是基線，字會往下伸出一截（中文約字高的兩成）：框的底邊放在基線上，底線會劃過字的下半部
      const r = { left: (x + item.width * from) / p.w, right: (x + item.width * to) / p.w,
        top: 1 - (y + h * 0.9) / p.h, bottom: 1 - (y - h * 0.2) / p.h };
      // 同一行（垂直方向重疊過半）的項目併成一個框
      const line = lines.find((l) => Math.min(l.bottom, r.bottom) - Math.max(l.top, r.top) > (r.bottom - r.top) / 2);
      if (line) {
        line.left = Math.min(line.left, r.left); line.right = Math.max(line.right, r.right);
        line.top = Math.min(line.top, r.top); line.bottom = Math.max(line.bottom, r.bottom);
      } else {
        lines.push(r);
      }
    });
    return lines;
  }

  /* 捲到落點、閃一下。有字框就閃那幾個字，沒有（章首）就閃書籤底下一條。
   * tab 模式下書在背景（background）：先捲好，切過去時才閃，同 EPUB */
  function land(at, req, note) {
    const p = P.pages[at.page - 1];
    if (!p) return;
    const background = !!req.background;
    if (P.paged) {
      goToPage(at.page - 1);
    } else {
      const rect = p.box.getBoundingClientRect();
      window.scrollTo({ top: Math.max(0, window.scrollY + rect.top + at.top * rect.height - (at.boxes ? 80 : 12)),
        behavior: background ? 'auto' : 'smooth' });
    }
    const show = () => {
      if (at.boxes) at.boxes.forEach((b) => flashBox(P.pages[b.page - 1], b.rect));
      else flashBox(p, null, at.top);
      if (note) MB.toast(note);
    };
    if (background) I().setPendingSync(show);
    else setTimeout(show, 450);
  }

  /* ── 標記的文字來源（docs/SPEC.md 13.13）────────────────────
   * highlights.js 綁著 DOM 的那幾件事，PDF 版的實作。位置一律是全文（P.text.full）裡的偏移 */

  /* 全文第 raw 個字在哪一頁（0 起算） */
  function pageOf(raw) {
    const { starts, strings } = P.text;
    let lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= raw) lo = mid; else hi = mid - 1;
    }
    // 空白頁的起點跟下一頁一樣，往回找到真正裝著這個字的那頁
    while (lo > 0 && raw >= starts[lo] + strings[lo].length && starts[lo - 1] === starts[lo]) lo--;
    return lo;
  }

  /* 文字層裡的 (node, offset) → 全文偏移。node 可能是 span 裡的文字、span 本身，
   * 或拖選拉到空白處時的文字層、endOfContent */
  function offsetAt(node, off) {
    const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    if (!el || !el.closest) return null;
    const layer = el.closest('.textLayer');
    if (!layer) return null;
    const pg = Number(layer.dataset.pg);
    const base = P.text.starts[pg];
    const spanStart = (span) => base + P.text.itemStarts[pg][Number(span.dataset.i)];
    const span = el.closest('span[data-i]');
    if (span) {
      const len = span.textContent.length;
      const inside = node.nodeType === Node.TEXT_NODE ? off : (off > 0 ? len : 0);
      return spanStart(span) + Math.min(inside, len);
    }
    // 落在文字層或 endOfContent 上：取邊界後的第一個 span，沒有就是這一頁的結尾
    const spans = [...layer.querySelectorAll('span[data-i]')];
    const boundary = node === layer ? layer.childNodes[off] : null;
    const after = boundary ? spans.find((sp) => boundary === sp || boundary.contains(sp) ||
      (boundary.compareDocumentPosition(sp) & Node.DOCUMENT_POSITION_FOLLOWING)) : null;
    return after ? spanStart(after) : base + P.text.strings[pg].length;
  }

  /* 側欄分組：有書籤依章，沒有依頁 */
  function groupAt(raw) {
    const pg = pageOf(raw) + 1;
    let found = -1;
    P.toc.forEach((t, i) => { if (t.page != null && t.page <= pg) found = i; });
    if (found !== -1) return { id: 'c' + found, text: P.toc[found].label };
    return { id: 'p' + pg, text: `第 ${pg} 頁` };
  }

  function drawHighlight(it) {
    const first = pageOf(it.start), last = pageOf(it.end - 1);
    let tail = null;
    for (let pg = first; pg <= last; pg++) {
      const base = P.text.starts[pg];
      const a = pg === first ? it.start - base : 0;
      const b = pg === last ? it.end - 1 - base : P.text.strings[pg].length - 1;
      for (const rect of lineRects(pg, a, b)) {
        const el = document.createElement('div');
        el.className = 'mb-hl mb-pdf-hl';
        el.dataset.id = it.id;
        el.dataset.style = it.style;
        placeBox(el, rect, 0);
        P.pages[pg].box.appendChild(el);
        tail = el;
      }
    }
    if (tail && it.note) tail.classList.add('mb-note-end');
  }

  /* 文字層在最上面才能選字，疊在下面的標記框收不到滑鼠：用座標自己找 */
  function highlightAt(x, y) {
    const under = document.elementFromPoint(x, y);
    const box = under && under.closest && under.closest('.mb-pdf-page');
    if (!box) return null;
    let hit = null;
    box.querySelectorAll('.mb-pdf-hl').forEach((el) => {
      const r = el.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) hit = el;
    });
    return hit;
  }

  BK.pdfStashHighlights = (payload) => { P.hlPayload = payload; };

  BK.pdfSource = {
    field: 'page',
    ready: () => !!P.text,
    text: () => P.text.full,
    // 錨點的位置提示是頁碼：同一句出現多次時，頁碼相同的那處加分
    heads: () => P.text.starts.map((raw, i) => ({ id: i + 1, text: `第 ${i + 1} 頁`, raw })),
    groupAt,
    offsetAt,
    clear: () => content.querySelectorAll('.mb-pdf-hl').forEach((el) => el.remove()),
    draw: drawHighlight,
    highlightAt,
  };

  /* ── 搜尋（Cmd F）─────────────────────────────────────────
   * 字是 canvas 畫的，不能像心得那樣把命中包成 <mark>：在全文裡找，換算成框疊在頁框上。
   * 比對時兩邊都去掉空白與換行 —— PDF 的中文句子常被斷在兩行，抽出來中間夾著換行。
   * 英文詞之間的空白也一起去掉，搜「Donald Kendall」照樣找得到 */
  BK.pdfFindAll = function (query) {
    BK.pdfClearHits();
    const q = query.replace(/\s/g, '').toLowerCase();
    if (!q || !P.text || !P.text.hasText) return [];
    if (!P.findText) P.findText = keyText(P.pages.map((_, i) => i), (c) => (/\s/.test(c) ? '' : c.toLowerCase()));
    const { text, where } = P.findText;
    for (let at = text.indexOf(q); at !== -1; at = text.indexOf(q, at + q.length)) {
      const s = spot(where, at, q.length);
      const els = s.boxes.map((b) => {
        const el = document.createElement('div');
        el.className = 'mb-pdf-hit';
        placeBox(el, b.rect, 0.002);
        P.pages[b.page - 1].box.appendChild(el);
        return el;
      });
      P.hits.push({ page: s.page, top: s.top, els });
    }
    return P.hits;
  };

  BK.pdfShowHit = function (index, jump) {
    P.hits.forEach((h) => h.els.forEach((el) => el.classList.remove('mb-current')));
    const hit = P.hits[index];
    if (!hit) return;
    hit.els.forEach((el) => el.classList.add('mb-current'));
    if (!jump) return;
    if (P.paged) { goToPage(hit.page - 1); return; }
    // 放到畫面中間，跟心得的搜尋一樣
    const rect = P.pages[hit.page - 1].box.getBoundingClientRect();
    window.scrollTo({ top: Math.max(0, window.scrollY + rect.top + hit.top * rect.height - window.innerHeight / 2),
      behavior: 'smooth' });
  };

  BK.pdfClearHits = function () {
    P.hits.forEach((h) => h.els.forEach((el) => el.remove()));
    P.hits = [];
  };

  /* 書籤的目的地：具名的先查表；第一個元素是頁的參照（或頁碼），XYZ／FitH 帶著頁內高度 */
  async function resolveDest(doc, dest) {
    try {
      if (typeof dest === 'string') dest = await doc.getDestination(dest);
      if (!Array.isArray(dest)) return null;
      const ref = dest[0];
      const index = ref && typeof ref === 'object' ? await doc.getPageIndex(ref)
        : Number.isInteger(ref) ? ref : null;
      const p = index == null ? null : P.pages[index];
      if (!p) return null;
      const kind = dest[1] && dest[1].name;
      const top = kind === 'XYZ' ? dest[3] : (kind === 'FitH' || kind === 'FitBH') ? dest[2] : null;
      // PDF 的 y 由下往上量
      const ratio = typeof top === 'number' ? Math.min(1, Math.max(0, 1 - top / p.h)) : 0;
      return { page: index + 1, ratio };
    } catch (e) {
      return null;
    }
  }

  /* 目前所在章：畫面頂端往下 120px 那一點之前，最後一個開始的書籤（跟 EPUB 捲動模式同一個基準） */
  BK.pdfChapter = function () {
    if (!P.toc.length || !P.pages.length) return null;
    // 翻頁模式以目前所在頁為準（同 13.9 的 fx.page）
    if (P.paged) {
      let at = null;
      P.toc.forEach((t, i) => { if (t.page != null && t.page <= P.cur + 1) at = i; });
      return at ?? P.toc.findIndex((t) => t.page != null);
    }
    const y = window.scrollY + 120;
    let found = null;
    P.toc.forEach((t, i) => {
      if (t.page == null) return;
      const box = P.pages[t.page - 1].box;
      const top = box.getBoundingClientRect().top + window.scrollY + t.ratio * box.offsetHeight;
      if (top <= y) found = i;
    });
    if (found == null) found = P.toc.findIndex((t) => t.page != null);
    return found === -1 ? null : found;
  };

  /* 被心得帶過來時在落點閃一條：書本來就停在那一章開頭時畫面不會動，不閃就看不出有反應。
   * 蓋在頁框上一層，不動 canvas 與文字層；顏色與節奏同 EPUB 的 .mb-sync-flash */
  function flashBox(p, rect, top) {
    const band = document.createElement('div');
    band.className = 'mb-pdf-flash mb-sync-flash';
    // 字框四周留一點邊，閃起來才不會貼著字
    if (rect) {
      placeBox(band, rect, 0.006);
    } else {
      band.style.top = top * 100 + '%';
    }
    p.box.appendChild(band);
    band.addEventListener('animationend', () => band.remove());
  }

  /* 把元素放到頁內某個框（頁的比例）上，四周多留 pad */
  function placeBox(el, rect, pad) {
    el.style.left = (rect.left - pad) * 100 + '%';
    el.style.width = (rect.right - rect.left + pad * 2) * 100 + '%';
    el.style.top = (rect.top - pad) * 100 + '%';
    el.style.height = (rect.bottom - rect.top + pad * 2) * 100 + '%';
  }

  /* 下拉選單或側欄選了某一章：捲到書籤指的地方，頂端留一點空 */
  BK.pdfScrollToChapter = function (index) {
    const t = P.toc[index];
    if (!t || t.page == null) return;
    restore({ page: t.page, ratio: t.ratio });
    window.scrollBy(0, -12);
  };

  /* ── 全文 ───────────────────────────────────────────────
   * 每頁的 textContent 逐字正規化後留著：全文拿來比對、搜尋，之後文字層也用同一份畫，
   * 兩邊的字一定一樣，位置才對得上（docs/SPEC.md 13.13）。 */

  async function extractText(doc, gen, announce) {
    const pages = [];
    for (let i = 1; i <= doc.numPages; i++) {
      let tc;
      try {
        tc = await (await doc.getPage(i)).getTextContent();
      } catch (e) {
        tc = { items: [], styles: {} };
      }
      if (gen !== P.gen) return;
      for (const item of tc.items) if (item.str) item.str = normalizeText(item.str);
      pages.push(tc);
    }
    P.text = joinText(pages);
    P.text.hasText = P.text.full.replace(/\s/g, '').length >= doc.numPages * MIN_CHARS_PER_PAGE;
    // 重載（檔案被換掉）不再講一次
    if (!P.text.hasText && announce) MB.toast('這份 PDF 沒有文字，不能標記與搜尋');
    P.near.forEach(drawText);
    flushPendingSync();
    if (window.MBHighlights) {
      const payload = P.hlPayload && !P.text.hasText
        ? Object.assign({}, P.hlPayload, { writable: false, reason: '這份 PDF 沒有文字，不能標記' })
        : P.hlPayload;
      P.hlPayload = null;
      window.MBHighlights.afterRender(payload, null);
    }
    // 全文還沒抽完就按了搜尋：那時一筆都找不到，抽完重找
    I().rerunFind();
  }

  /* 每頁的字串：項目依序接起來，行尾（與頁尾）的換行照規則換掉（docs/SPEC.md 13.13）——
   * 兩邊都是中日文字就直接接起來，其他換成一個空格。不處理的話中文句子被斷在兩行，
   * 標記的 exact 會是「攀爬的困 難度」。英文行尾的連字號照原樣：是斷字還是字本身就有，猜不準。
   * 記下每個項目在那頁字串裡從第幾個字開始：文字層的選取、字的框都靠它換算 */
  const CJK = /[\u2E80-\u9FFF\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFFEF\u{20000}-\u{2FA1F}]/u;

  function joinText(pages) {
    // 每個換行點後面第一個字（可能在下一頁），倒著走一次就知道
    const flat = pages.flatMap((tc, pg) => tc.items.map((item, i) => ({ item, pg, i })));
    const nextChar = new Array(flat.length);
    let next = '';
    for (let k = flat.length - 1; k >= 0; k--) {
      nextChar[k] = next;
      const str = flat[k].item.str;
      if (str && str.trim()) next = str.trimStart()[0];
    }
    const strings = pages.map(() => '');
    const itemStarts = pages.map((tc) => new Array(tc.items.length));
    let prev = '';
    flat.forEach(({ item, pg, i }, k) => {
      itemStarts[pg][i] = strings[pg].length;
      const str = item.str || '';
      strings[pg] += str;
      if (str.trim()) prev = str.trimEnd().slice(-1);
      const pageEnd = i === pages[pg].items.length - 1;
      if (!(item.hasEOL || pageEnd) || !nextChar[k] || /\s$/.test(str)) return;
      if (!(CJK.test(prev) && CJK.test(nextChar[k]))) strings[pg] += ' ';
    });
    const starts = [];
    let full = '';
    for (const str of strings) { starts.push(full.length); full += str; }
    return { pages, strings, itemStarts, full, starts };
  }

  /* 每頁平均不到這麼多字（不算空白）就當作沒有文字層。實測每頁一張圖的書抽到 0 字，
   * 文字書每頁平均 500 字以上；掃描書頂多抽到頁碼，有圖說的圖片書每頁十幾二十字仍算有字 */
  const MIN_CHARS_PER_PAGE = 10;

  /* calibre 加 macOS 宋體輸出的 PDF，ToUnicode 常指錯碼位：看起來是「大家」，抽出來是康熙部首
   * 「⼤家」，問號是直排標點「︖」。只轉這幾個區段，而且轉完仍是一個字才換 —— 一對一，
   * 文字層 span 的寬度與位置不變。不對整段做 NFKC：那會把全形「，」「？」「（」轉成半形。
   * 直排標點 NFKC 的結果多半是半形（︖ → ?），中文內文該是全形，再轉回全形。 */
  const SUSPECT = /[\u2E80-\u2FDF\uF900-\uFAFF\uFE10-\uFE1F\uFE30-\uFE4F\u{2F800}-\u{2FA1F}]/u;
  const SUSPECT_ALL = new RegExp(SUSPECT.source, 'gu');

  function normalizeChar(c) {
    const n = c.normalize('NFKC');
    if (n === c || [...n].length !== 1) return c;
    const code = n.codePointAt(0);
    return code >= 0x21 && code <= 0x7E ? String.fromCodePoint(code + 0xFEE0) : n;
  }

  function normalizeText(str) {
    return SUSPECT.test(str) ? str.replace(SUSPECT_ALL, normalizeChar) : str;
  }

  /* ── 畫頁 ───────────────────────────────────────────── */

  function onIntersect(entries) {
    if (P.paged) return;        // 翻頁模式自己決定畫哪幾頁（layoutPaged）
    for (const e of entries) {
      const index = P.pages.findIndex((p) => p.box === e.target);
      if (index === -1) continue;
      if (e.isIntersecting) { P.near.add(index); draw(index); drawText(index); } else { P.near.delete(index); release(P.pages[index]); }
    }
  }

  async function draw(index) {
    const p = P.pages[index];
    // 翻頁模式下前後那組是隱藏的，量不到寬度，用排版時算好的
    const width = P.paged ? Math.round(p.cssWidth || 0) : p.box.clientWidth;
    if (!width || (p.canvas && p.drawnWidth === width) || !P.doc) return;
    const gen = P.gen;
    if (p.task) p.task.cancel();
    const page = await P.doc.getPage(index + 1);
    if (gen !== P.gen || !P.near.has(index)) return;

    // 視網膜螢幕要用裝置像素畫，不然字是糊的
    const scale = width / p.w * (window.devicePixelRatio || 1);
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement('canvas');
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    const task = page.render({ canvas, canvasContext: canvas.getContext('2d'), viewport });
    p.task = task;
    try {
      await task.promise;
    } catch (e) {
      return;          // 被取消（捲走了、欄寬又變了）
    }
    if (p.task !== task) return;
    p.task = null;
    if (gen !== P.gen || !P.near.has(index)) { canvas.width = canvas.height = 0; return; }
    // 畫完才換上，重畫（欄寬改變）時舊的那張先留著，不會整頁閃白
    if (p.canvas) { p.canvas.width = p.canvas.height = 0; p.canvas.remove(); }
    p.canvas = canvas;
    p.drawnWidth = width;
    p.box.appendChild(canvas);
  }

  /* 文字層的字級與位置都跟著 --total-scale-factor（CSS px／PDF pt）走，欄寬改變時只要改這個值，
   * 不必重建。先全部量完再一起寫，免得每寫一次就逼 WebKit 重排一次 */
  function scaleBoxes() {
    const widths = P.pages.map((p) => (P.paged ? p.cssWidth || 0 : p.box.clientWidth));
    P.pages.forEach((p, i) => { if (widths[i]) p.box.style.setProperty('--total-scale-factor', widths[i] / p.w); });
  }

  async function drawText(index) {
    const p = P.pages[index];
    if (!p || p.layer || !P.text || !P.text.hasText || !P.doc) return;
    const gen = P.gen;
    const div = document.createElement('div');
    div.className = 'textLayer';
    p.layer = div;
    const page = await P.doc.getPage(index + 1);
    if (gen !== P.gen || p.layer !== div) return;
    const layer = new lib.TextLayer({
      textContentSource: P.text.pages[index],
      container: div,
      viewport: page.getViewport({ scale: 1 }),
    });
    try {
      await layer.render();
    } catch (e) {
      return;
    }
    if (gen !== P.gen || p.layer !== div) return;
    // textDivs 依序對應每個有 str 的項目：記下來，選取才換算得回全文的位置
    div.dataset.pg = index;
    const textItems = P.text.pages[index].items.map((it, i) => (it.str === undefined ? -1 : i)).filter((i) => i !== -1);
    layer.textDivs.forEach((span, k) => { span.dataset.i = textItems[k]; });
    // 拖選拉到行與行之間的空白時，選取範圍不要跳到整頁開頭（pdf.js 檢視器的做法）
    const end = document.createElement('div');
    end.className = 'endOfContent';
    div.appendChild(end);
    p.box.appendChild(div);
  }

  content.addEventListener('mousedown', (e) => {
    const layer = e.target.closest && e.target.closest('.textLayer');
    if (layer) layer.classList.add('selecting');
  });
  document.addEventListener('mouseup', () => {
    content.querySelectorAll('.textLayer.selecting').forEach((el) => el.classList.remove('selecting'));
  });

  function release(p) {
    if (p.layer) { p.layer.remove(); p.layer = null; }
    if (p.task) { p.task.cancel(); p.task = null; }
    if (p.canvas) {
      // WebKit 不會馬上回收 canvas 的記憶體，先把尺寸歸零
      p.canvas.width = p.canvas.height = 0;
      p.canvas.remove();
      p.canvas = null;
    }
    p.drawnWidth = 0;
  }

  /* 欄寬改變：頁框靠 aspect-ratio 自己跟著縮放，停下來之後才用新的解析度重畫 */
  let resizeTimer = null;
  window.addEventListener('resize', () => {
    if (!BK.active || !BK.pdf) return;
    // 翻頁模式：頁框是固定尺寸，停下來再重算比例、重畫
    if (P.paged) { clearTimeout(resizeTimer); resizeTimer = setTimeout(layoutPaged, 150); return; }
    scaleBoxes();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => P.near.forEach(draw), 200);
  });

  /* ── 閱讀位置：頁碼＋頁內比例 ──────────────────────────────
   * 欄寬一變頁高就變，存像素回不到同一個地方（docs/SPEC.md 13.13）。 */

  BK.pdfAnchor = function () {
    if (P.paged) return P.pages.length ? { page: P.cur + 1, ratio: 0 } : null;
    for (let i = 0; i < P.pages.length; i++) {
      const rect = P.pages[i].box.getBoundingClientRect();
      if (rect.bottom > 0) {
        const ratio = rect.height ? Math.min(1, Math.max(0, -rect.top / rect.height)) : 0;
        return { page: i + 1, ratio: Math.round(ratio * 10000) / 10000 };
      }
    }
    return null;
  };

  function restore(anchor) {
    const p = P.pages[Math.min(P.pages.length, Math.max(1, anchor.page)) - 1];
    if (!p) return;
    if (P.paged) { goToPage(P.pages.indexOf(p)); return; }
    const rect = p.box.getBoundingClientRect();
    window.scrollTo(0, window.scrollY + rect.top + (anchor.ratio || 0) * rect.height);
  }
  BK.pdfRestore = (anchor) => { if (anchor && typeof anchor.page === 'number') restore(anchor); };

  /* ── 單頁、雙頁（docs/SPEC.md 13.13）──────────────────────────
   * 沿用捲動模式的頁框，只改排法：只顯示目前這組跨頁，其他隱藏，顯示中的縮放到整頁塞進欄裡。
   * canvas、文字層、標記、命中框都掛在頁框裡，不必重建。直接換頁、沒有動畫（同 13.9）。 */

  const indicator = document.createElement('div');
  indicator.className = 'mb-pdf-indicator';
  indicator.hidden = true;
  document.body.appendChild(indicator);

  /* 選了雙頁、而且每頁不小於約 400pt 才跨頁（同 13.9） */
  function useSpread() {
    return BK.layout === 'double' && content.clientWidth / 2 >= 400;
  }

  /* 雙頁怎麼配對：PDF 自己宣告的 /PageLayout 優先 —— TwoPageLeft 從第 1 頁成對、TwoPageRight
   * 封面單獨；沒寫就照 13.9 封面單獨、之後兩兩成對（PDF 書多半由紙本或 EPUB 轉來，有封面） */
  function spreadsFor(spread) {
    const n = P.pages.length, out = [];
    if (!spread) { for (let i = 0; i < n; i++) out.push([i]); return out; }
    let i = 0;
    if (P.pageLayout !== 'TwoPageLeft' && n) { out.push([0]); i = 1; }
    for (; i < n; i += 2) out.push(i + 1 < n ? [i, i + 1] : [i]);
    return out;
  }

  function layoutPaged() {
    document.documentElement.classList.toggle('mb-pdf-paged', P.paged);
    if (!P.pages.length) return;
    if (!P.paged) {
      P.pages.forEach((p) => { p.box.classList.remove('mb-off'); p.box.style.width = ''; p.cssWidth = 0; });
      indicator.hidden = true;
      scaleBoxes();
      return;
    }
    P.spreads = spreadsFor(useSpread());
    let si = P.spreads.findIndex((sp) => sp.includes(P.cur));
    if (si === -1) si = 0;
    const spread = P.spreads[si];
    const availW = content.clientWidth - 24, availH = window.innerHeight - 52;
    const fit = (sp) => Math.min(availW / sp.reduce((sum, i) => sum + P.pages[i].w, 0),
      availH / Math.max(...sp.map((i) => P.pages[i].h)));
    // 前後各一組也先排好尺寸、畫起來：翻過去才不會先白一下
    const keep = new Set();
    for (const k of [si - 1, si, si + 1]) {
      const sp = P.spreads[k];
      if (!sp) continue;
      const scale = fit(sp);
      for (const i of sp) { P.pages[i].cssWidth = P.pages[i].w * scale; keep.add(i); }
    }
    P.pages.forEach((p, i) => {
      const show = spread.includes(i);
      p.box.classList.toggle('mb-off', !show);
      p.box.style.width = show ? p.cssWidth + 'px' : '';
    });
    for (const i of [...P.near]) if (!keep.has(i)) { P.near.delete(i); release(P.pages[i]); }
    scaleBoxes();
    keep.forEach((i) => { P.near.add(i); draw(i); drawText(i); });
    const last = spread[spread.length - 1];
    indicator.textContent = (spread.length > 1 ? `${spread[0] + 1}–${last + 1}` : `${spread[0] + 1}`) + `／${P.pages.length}`;
    indicator.hidden = false;
  }

  /* 翻到某一頁所在的跨頁（跳轉用：目錄、同步、搜尋、側欄點標記） */
  function goToPage(index) {
    P.cur = Math.max(0, Math.min(P.pages.length - 1, index));
    layoutPaged();
    BK.reportPosition(false);
  }

  /* 使用者翻頁：跨過章界時心得跟著換（turned，同 13.9） */
  BK.pdfTurn = function (step) {
    if (!P.paged || !P.spreads.length) return;
    const si = P.spreads.findIndex((sp) => sp.includes(P.cur));
    const next = Math.max(0, Math.min(P.spreads.length - 1, si + step));
    if (next === si) return;
    P.cur = P.spreads[next][0];
    layoutPaged();
    BK.reportPosition(true);
  };

  /* Home／End：本章第一頁／最後一頁；沒有書籤就是全書首尾 */
  BK.pdfEdge = function (dir) {
    const ch = BK.pdfChapter();
    let target;
    if (ch == null || ch === -1) target = dir < 0 ? 0 : P.pages.length - 1;
    else {
      const [from, to] = chapterPages(ch);
      // chapterPages 的結尾是下一章所在頁；那頁屬於下一章，就停在前一頁
      const nextStarts = P.toc.some((t, i) => i > ch && t.page === to && to > from);
      target = dir < 0 ? from - 1 : (nextStarts ? to - 2 : to - 1);
    }
    P.cur = Math.max(0, target);
    layoutPaged();
    BK.reportPosition(true);
  };

  /* 側欄點標記等「把某個元素帶進畫面」：翻到它所在的頁 */
  BK.pdfReveal = function (el) {
    const box = el && el.closest && el.closest('.mb-pdf-page');
    const i = P.pages.findIndex((p) => p.box === box);
    if (i !== -1) goToPage(i);
  };

  /* 三選一切換：停在同一頁 */
  BK.pdfSetLayout = function () {
    if (!P.pages.length) return;          // 還沒排好：renderPdf 會照 BK.layout 排
    const anchor = BK.pdfAnchor();
    const paged = BK.layout !== 'scroll';
    if (paged === P.paged && !paged) return;
    P.paged = paged;
    if (paged) {
      P.cur = anchor ? anchor.page - 1 : 0;
      window.scrollTo(0, 0);
      layoutPaged();
    } else {
      layoutPaged();
      if (anchor) restore(anchor);
      // 回到捲動模式：重新交給 IntersectionObserver 決定畫哪幾頁
      P.near.forEach((i) => release(P.pages[i]));
      P.near.clear();
      if (P.observer) { P.observer.disconnect(); P.pages.forEach((p) => P.observer.observe(p.box)); }
    }
    BK.reportPosition(false);
  };
})();
