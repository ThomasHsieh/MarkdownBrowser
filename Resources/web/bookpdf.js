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
    // 標記還沒接上：先給標記模組一份「唯讀」的狀態，不會寫 sidecar
    if (window.MBHighlights && opts.highlights) {
      window.MBHighlights.afterRender(Object.assign({}, opts.highlights, { writable: false, reason: 'PDF 還不能標記' }), null);
    }

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
    if (target && typeof target.page === 'number') restore(target);
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
    P.near.clear();
    P.text = null;
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

  /* 心得帶動書（docs/SPEC.md 13.13）：同步只到章，捲到那一章的書籤。
   * 換心得或剛開檔時，Swift 送來的同步可能比書籤先到，先存著 */
  BK.pdfSyncTo = function (req) {
    // 要搜全文的同步還得等全文抽完
    const wantsText = req.text && !req.quiet && P.text == null;
    if (!P.tocLoaded || wantsText) { P.pendingSync = req; return; }
    const chapter = (req.chapters || []).find((i) => P.toc[i] && P.toc[i].page != null);
    if (chapter == null) {
      if (!P.toc.length) MB.toast('這份 PDF 沒有目錄');
      return;
    }
    // 點的是小節標題：拿標題文字去這一章的全文找，跟 EPUB「標題對不到」的退路一樣（docs/SPEC.md 13.6）。
    // 點的是章名（quiet）就不找，章首正是要去的地方
    if (req.text && !req.quiet && P.text && P.text.hasText) {
      const hit = keywordInChapter(chapter, req.text);
      if (hit) { land(hit, req, `依關鍵詞「${hit.word}」對到內文`); return; }
    }
    const t = P.toc[chapter];
    // 引文比對還沒做：先到那一章開頭
    const miss = req.quote ? 'PDF 還不能比對引文，已跳到這一章開頭'
      : req.text && !req.quiet ? '找不到對應小節，已跳到章首' : null;
    land({ page: t.page, top: t.ratio, rect: null }, req, miss);
  };

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

  /* 標題裡在這一章全文出現的最長一段 → 落點（頁、頁內高度、那幾個字的框） */
  function keywordInChapter(index, heading) {
    const [from, to] = chapterPages(index);
    let text = '';
    const where = [];               // text 第 k 個字 → [頁 index, 那頁字串裡的位置]
    for (let pg = from - 1; pg < to; pg++) {
      const s = P.text.strings[pg];
      for (let i = 0; i < s.length; i++) {
        if (/\s/.test(s[i])) continue;
        text += s[i];
        where.push([pg, i]);
      }
    }
    const word = BK.longestKeyword(text, heading);
    if (!word) return null;
    const at = text.indexOf(word);
    const [pg, startOff] = where[at];
    const [endPg, endOff] = where[at + word.length - 1];
    const rect = textRect(pg, startOff, endPg === pg ? endOff : P.text.strings[pg].length - 1);
    return { word, page: pg + 1, top: rect ? rect.top : 0, rect };
  }

  /* 頁字串裡 [a, b] 這段字所在 textContent 項目的外框，以頁的比例表示（0～1，由上往下） */
  function textRect(pg, a, b) {
    const items = P.text.pages[pg].items;
    const p = P.pages[pg];
    let off = 0, box = null;
    for (const item of items) {
      const len = (item.str || '').length + (item.hasEOL ? 1 : 0);
      const s = off, e = off + len - 1;
      off += len;
      if (e < a || s > b || !item.str || !item.transform) continue;
      const [, , , d, x, y] = item.transform;
      const h = item.height || Math.abs(d);
      // 一個項目常是半行字：照字數比例裁到真正那幾個字（中文等寬，誤差在一兩個字內）
      const n = item.str.length;
      const from = (Math.max(a, s) - s) / n, to = Math.min(n, Math.min(b, e) - s + 1) / n;
      const r = { left: (x + item.width * from) / p.w, right: (x + item.width * to) / p.w,
        top: 1 - (y + h) / p.h, bottom: 1 - y / p.h };
      box = box ? { left: Math.min(box.left, r.left), right: Math.max(box.right, r.right),
        top: Math.min(box.top, r.top), bottom: Math.max(box.bottom, r.bottom) } : r;
    }
    return box;
  }

  /* 捲到落點、閃一下。有字框就閃那幾個字，沒有（章首）就閃書籤底下一條。
   * tab 模式下書在背景（background）：先捲好，切過去時才閃，同 EPUB */
  function land(at, req, note) {
    const p = P.pages[at.page - 1];
    if (!p) return;
    const rect = p.box.getBoundingClientRect();
    const background = !!req.background;
    window.scrollTo({ top: Math.max(0, window.scrollY + rect.top + at.top * rect.height - (at.rect ? 80 : 12)),
      behavior: background ? 'auto' : 'smooth' });
    const show = () => { flashBox(p, at.rect, at.top); if (note) MB.toast(note); };
    if (background) I().setPendingSync(show);
    else setTimeout(show, 450);
  }

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
    if (rect) {
      // 字框四周留一點邊，閃起來才不會貼著字
      const pad = 0.006;
      band.style.left = (rect.left - pad) * 100 + '%';
      band.style.width = (rect.right - rect.left + pad * 2) * 100 + '%';
      band.style.top = (rect.top - pad) * 100 + '%';
      band.style.height = (rect.bottom - rect.top + pad * 2) * 100 + '%';
    } else {
      band.style.top = top * 100 + '%';
    }
    p.box.appendChild(band);
    band.addEventListener('animationend', () => band.remove());
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
    const pages = [], strings = [], starts = [];
    let full = '';
    for (let i = 1; i <= doc.numPages; i++) {
      let tc;
      try {
        tc = await (await doc.getPage(i)).getTextContent();
      } catch (e) {
        tc = { items: [], styles: {} };
      }
      if (gen !== P.gen) return;
      for (const item of tc.items) if (item.str) item.str = normalizeText(item.str);
      const str = tc.items.map((x) => (x.str || '') + (x.hasEOL ? '\n' : '')).join('');
      pages.push(tc);
      strings.push(str);
      starts.push(full.length);
      full += str;
    }
    const hasText = full.replace(/\s/g, '').length >= doc.numPages * MIN_CHARS_PER_PAGE;
    P.text = { pages, strings, full, starts, hasText };
    // 重載（檔案被換掉）不再講一次
    if (!hasText && announce) MB.toast('這份 PDF 沒有文字，不能標記與搜尋');
    P.near.forEach(drawText);
    flushPendingSync();
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
    for (const e of entries) {
      const index = P.pages.findIndex((p) => p.box === e.target);
      if (index === -1) continue;
      if (e.isIntersecting) { P.near.add(index); draw(index); drawText(index); } else { P.near.delete(index); release(P.pages[index]); }
    }
  }

  async function draw(index) {
    const p = P.pages[index];
    const width = p.box.clientWidth;
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
    const widths = P.pages.map((p) => p.box.clientWidth);
    P.pages.forEach((p, i) => p.box.style.setProperty('--total-scale-factor', widths[i] / p.w));
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
    scaleBoxes();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => P.near.forEach(draw), 200);
  });

  /* ── 閱讀位置：頁碼＋頁內比例 ──────────────────────────────
   * 欄寬一變頁高就變，存像素回不到同一個地方（docs/SPEC.md 13.13）。 */

  BK.pdfAnchor = function () {
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
    const rect = p.box.getBoundingClientRect();
    window.scrollTo(0, window.scrollY + rect.top + (anchor.ratio || 0) * rect.height);
  }
  BK.pdfRestore = (anchor) => { if (anchor && typeof anchor.page === 'number') restore(anchor); };
})();
