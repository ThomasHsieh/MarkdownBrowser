/* bookpdf.js —— 書那欄的 PDF（docs/SPEC.md 13.13）。
 *
 * 照原樣顯示頁面，不套我們的樣式：每頁一個 canvas，由 pdf.js 畫。PDF 從 mbres://book/ 讀，
 * worker 從 mbres://app/vendor/pdfjs/ 載入（實測是真的背景 Worker）。
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
    pages: [],       // [{w, h, box, canvas, task, drawnWidth}]
    observer: null,
    near: new Set(), // 在畫面附近、該畫的頁
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
      return { w: s.w, h: s.h, box, canvas: null, task: null, drawnWidth: 0 };
    });

    const target = keep || payload.position;
    if (target && typeof target.page === 'number') restore(target);
    else window.scrollTo(0, 0);

    P.observer = new IntersectionObserver(onIntersect, { rootMargin: '150% 0px' });
    P.pages.forEach((p) => P.observer.observe(p.box));
    I().toSwift({ type: 'bookPosition', chapter: null, turned: false });

    // 第一頁先畫，全文在背景抽；標記、引文、搜尋都等這份
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
    if (P.doc) P.doc.destroy();
    P.doc = null;
  }
  BK.pdfTeardown = teardown;

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
      if (e.isIntersecting) { P.near.add(index); draw(index); } else { P.near.delete(index); release(P.pages[index]); }
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

  function release(p) {
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
