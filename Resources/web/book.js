/* book.js —— 書那一欄（docs/SPEC.md 第 13 節）。
 *
 * 可重排的書：Swift 把每個 spine 檔的原文與所有 CSS 一次送來，這裡串成一條。
 * 樣式「先讀後丟」：在一個看不見的 iframe 裡套上書自己的 CSS，用 getComputedStyle
 * 讀出每個元素實際上是不是粗體、斜體、置中、縮排、小字，轉成我們的 mb-* class，
 * 再把書的 CSS 與 class 全部丟掉、套我們的主題。粗體因此也只換色、不加粗。
 *
 * 固定版面的書：每頁是一個 iframe（mbres://book/…），等比縮放、翻頁式顯示，
 * 不套主題、不能標記。
 */

'use strict';

(function () {
  const content = document.getElementById('content');
  const I = () => MB.internal;
  const toSwift = (p) => I().toSwift(p);
  const OPS = 'http://www.idpf.org/2007/ops';

  const BK = {
    active: false,
    fixed: false,
    toc: [],
    markers: [],          // [{el, index, level}]，依文件順序，標出每個目錄項目從哪裡開始
    chapter: null,
    navigatedAt: 0,       // 最後一次被同步或選單帶去某處的時間
  };
  window.MBBook = BK;

  BK.deactivate = function () {
    if (!BK.active) return;
    BK.active = false;
    BK.fixed = false;
    BK.toc = [];
    BK.markers = [];
    BK.chapter = null;
    document.documentElement.classList.remove('mb-book-mode', 'mb-fixed-mode');
    content.classList.remove('mb-book');
    closePopover();
  };

  /* ── 路徑 ───────────────────────────────────────────── */

  function dirname(path) {
    const i = path.lastIndexOf('/');
    return i === -1 ? '' : path.slice(0, i);
  }

  /* href 相對於某個 spine 檔 → ZIP 裡的路徑與錨點 */
  function resolve(href, from) {
    const hash = href.indexOf('#');
    const raw = hash === -1 ? href : href.slice(0, hash);
    const frag = hash === -1 ? null : decodeURIComponent(href.slice(hash + 1));
    let decoded = raw;
    try { decoded = decodeURIComponent(raw); } catch (e) { /* 保留原樣 */ }
    if (!decoded) return { path: from, frag };
    const stack = decoded.startsWith('/') ? [] : dirname(from).split('/').filter(Boolean);
    for (const piece of decoded.split('/')) {
      if (!piece || piece === '.') continue;
      if (piece === '..') stack.pop(); else stack.push(piece);
    }
    return { path: stack.join('/'), frag };
  }

  const bookURL = (path) => 'mbres://book/' + path.split('/').map(encodeURIComponent).join('/');

  /* 每個 spine 檔的 id 加前綴防撞；用檔名而不是順序，重新打包時順序變了 id 也不變 */
  const prefixOf = (path) => 'f-' + path.replace(/[^A-Za-z0-9_-]/g, '_');
  const idFor = (path, frag) => frag ? prefixOf(path) + '--' + frag : prefixOf(path);

  function epubType(el) {
    return (el.getAttributeNS && el.getAttributeNS(OPS, 'type')) || el.getAttribute('epub:type') || '';
  }

  /* ── 渲染：可重排 ───────────────────────────────────── */

  MB.renderBook = function (payload, opts) {
    opts = opts || {};
    const hl = window.MBHighlights;
    const anchor = opts.keepScroll ? captureBookAnchor() : null;
    const kept = hl && BK.active && !BK.fixed ? hl.beforeRender() : null;

    closePopover();
    I().closeFind();
    I().markRendered();
    BK.active = true;
    BK.fixed = !!payload.fixed;
    BK.toc = payload.toc || [];
    document.documentElement.classList.add('mb-book-mode');
    document.documentElement.classList.toggle('mb-fixed-mode', BK.fixed);
    content.classList.add('mb-book');

    if (BK.fixed) { renderFixed(payload, opts, anchor); return; }

    const sections = buildSections(payload);
    content.innerHTML = '';
    content.appendChild(sections);
    activateImages();

    const outline = assignHeadings();
    locateChapters();
    outline.forEach((o) => { o.chapter = chapterOf(document.getElementById(o.id)); });

    if (hl) hl.afterRender(opts.highlights, kept);

    const target = anchor || payload.position;
    if (target) restoreBookAnchor(target);
    else window.scrollTo(0, 0);
    // 圖片載入後版面會變，載完再回位一次（使用者已經自己捲了就不動）
    // 之後若被同步帶走（navigatedAt 更新）就不再拉回來
    const renderedAt = Date.now();
    if (target) I().afterLayout(() => { if (!I().userMoved() && BK.navigatedAt < renderedAt) restoreBookAnchor(target); });

    toSwift({ type: 'outline', outline });
    reportPosition(false, true);
  };



  MB.renderBookError = function (text) {
    BK.deactivate();
    content.innerHTML = '';
    const box = document.createElement('div');
    box.className = 'mb-book-error';
    box.textContent = text;
    content.appendChild(box);
    toSwift({ type: 'outline', outline: [] });
  };

  /* 整本串成一條。CSS 只在 iframe 裡活一下，讀完就丟。 */
  function buildSections(payload) {
    const frame = document.createElement('iframe');
    frame.setAttribute('aria-hidden', 'true');
    frame.style.cssText = 'position:fixed;left:-30000px;top:0;width:760px;height:600px;border:0;visibility:hidden';
    document.body.appendChild(frame);
    const fdoc = frame.contentDocument;
    fdoc.open();
    fdoc.write('<!DOCTYPE html><html><head><meta charset="utf-8"></head><body></body></html>');
    fdoc.close();

    const css = payload.css || {};
    const spinePaths = new Set((payload.spine || []).map((s) => s.path));
    const fbody = fdoc.body;
    const frag = document.createDocumentFragment();

    // 一章一章輪流套樣式：每個 XHTML 只套它自己連結的 CSS 與自己的 <style>。
    // 整本一起套的話，某一頁自帶的 <style>p{text-align:center}</style>（書名頁之類）
    // 會漏到全書每一段，整本書都變成置中
    for (const item of payload.spine || []) {
      let doc = new DOMParser().parseFromString(item.xhtml, 'application/xhtml+xml');
      // XHTML 寫壞了（未宣告的 HTML 實體之類）就退回寬鬆的 HTML 解析
      if (doc.getElementsByTagName('parsererror').length) doc = new DOMParser().parseFromString(item.xhtml, 'text/html');
      const body = doc.body || doc.getElementsByTagName('body')[0];
      if (!body) continue;

      fdoc.head.innerHTML = '';
      for (const link of doc.querySelectorAll('link[href]')) {
        if (!/stylesheet/i.test(link.getAttribute('rel') || '')) continue;
        const p = resolve(link.getAttribute('href'), item.path).path;
        if (css[p] != null) addStyle(fdoc, css[p]);
      }
      for (const st of doc.querySelectorAll('style')) addStyle(fdoc, st.textContent);

      // 圖片先不給 src：在 iframe 裡就開始載的話，iframe 一拿掉，還沒載完的就全部中斷、
      // 變成破圖（圖多的書幾乎整本都是）。搬進正式的文件之後才接上（activateImages）
      parkImages(body, item.path);

      const section = fdoc.createElement('section');
      section.className = 'mb-chapter ' + (body.getAttribute('class') || '');
      section.id = prefixOf(item.path);
      section.dataset.path = item.path;
      for (const child of [...body.childNodes]) section.appendChild(fdoc.importNode(child, true));
      fbody.innerHTML = '';
      fbody.appendChild(section);
      rewrite(section, item.path, spinePaths);
      convertStyles(fdoc, frame.contentWindow);
      frag.appendChild(document.adoptNode(section));
    }

    frame.remove();
    // 注腳要整本一起看：連結與它指向的 aside 常在不同章
    hideFootnotes(frag);
    attachLinks(frag);
    return frag;
  }


  /* 書嵌的字型一律不用（字體跟著 data-font），@import 也不跟 */
  function addStyle(fdoc, text) {
    const st = fdoc.createElement('style');
    st.textContent = (text || '').replace(/@font-face\s*\{[^}]*\}/gi, '').replace(/@import[^;]*;/gi, '');
    fdoc.head.appendChild(st);
  }

  /* id 加前綴、連結改成文件內錨點、圖片改走 mbres://book/、拿掉 script */
  function rewrite(section, path, spinePaths) {
    section.querySelectorAll('script, link, style, meta, title').forEach((el) => el.remove());
    section.querySelectorAll('[id]').forEach((el) => { el.id = idFor(path, el.id); });
    // EPUB 2 的 <a name="…"> 也是錨點
    section.querySelectorAll('a[name]:not([id])').forEach((el) => { el.id = idFor(path, el.getAttribute('name')); });

    section.querySelectorAll('a[href]').forEach((a) => {
      const href = a.getAttribute('href');
      if (/^[a-z][a-z0-9+.-]*:/i.test(href)) { a.dataset.external = '1'; return; }
      const t = resolve(href, path);
      if (!spinePaths.has(t.path)) { a.removeAttribute('href'); return; }
      a.setAttribute('href', '#' + idFor(t.path, t.frag));
      a.dataset.internal = '1';
    });

  }

  const XLINK = 'http://www.w3.org/1999/xlink';

  /* 圖片的位址先存在 data-mb-src，src 拿掉。在 DOMParser 的文件裡做 —— 那裡沒有
   * 瀏覽環境，不會發出任何請求。 */
  function parkImages(body, path) {
    const abs = (v) => /^[a-z]+:/i.test(v) ? v : bookURL(resolve(v, path).path);
    body.querySelectorAll('img[src]').forEach((img) => {
      img.setAttribute('data-mb-src', abs(img.getAttribute('src')));
      img.removeAttribute('src');
      img.removeAttribute('srcset');
    });
    // SVG 包著的封面圖
    body.querySelectorAll('image').forEach((im) => {
      const v = im.getAttributeNS(XLINK, 'href') || im.getAttribute('href') || im.getAttribute('xlink:href');
      if (!v) return;
      im.setAttribute('data-mb-src', abs(v));
      im.removeAttributeNS(XLINK, 'href');
      im.removeAttribute('href');
      im.removeAttribute('xlink:href');
    });
  }

  /* 搬進正式文件之後才開始載圖。不用 lazy：圖片載入後才撐開高度，上方的版面會位移，
   * 同步與閱讀位置就落在錯的地方。width/height 留著，先用長寬比佔位。 */
  function activateImages() {
    content.querySelectorAll('img[data-mb-src]').forEach((img) => {
      img.setAttribute('src', img.getAttribute('data-mb-src'));
      img.removeAttribute('data-mb-src');
    });
    content.querySelectorAll('image[data-mb-src]').forEach((im) => {
      const v = im.getAttribute('data-mb-src');
      im.setAttributeNS(XLINK, 'xlink:href', v);
      im.setAttribute('href', v);
      im.removeAttribute('data-mb-src');
    });
  }

  /* ── 先讀後丟：書的 CSS → 我們的語意 class ─────────────── */

  const BLOCK = /^(block|list-item|table|table-cell|flex|grid|flow-root)$/;

  function convertStyles(fdoc, win) {
    const cache = new Map();
    const style = (el) => {
      let cs = cache.get(el);
      if (!cs) {
        const c = win.getComputedStyle(el);
        cs = {
          weight: parseInt(c.fontWeight, 10) || 400,
          italic: c.fontStyle === 'italic' || c.fontStyle === 'oblique',
          align: c.textAlign,
          indent: parseFloat(c.textIndent) || 0,
          size: parseFloat(c.fontSize) || 16,
          display: c.display,
          valign: c.verticalAlign,
        };
        cache.set(el, cs);
      }
      return cs;
    };

    const flags = [];
    for (const el of fdoc.body.querySelectorAll('section.mb-chapter *')) {
      const tag = el.localName;
      if (tag === 'svg' || el.closest('svg')) continue;
      const me = style(el), parent = style(el.parentElement);
      const cls = [];
      const inHeading = !!el.closest('h1, h2, h3, h4, h5, h6, th');

      if (me.display === 'none') cls.push('mb-hidden');
      if (!inHeading && me.weight >= 600 && parent.weight < 600) cls.push('mb-b');
      // 從粗體改回一般也要標：書常把 <li> 設成粗體只為了讓編號變粗，裡面的段落再改回一般。
      // 我們的粗體是顏色，顏色會往下繼承，不標的話整個清單項目都變橘色
      if (!inHeading && me.weight < 600 && parent.weight >= 600) cls.push('mb-nb');
      if (me.italic && !parent.italic && tag !== 'i' && tag !== 'em') cls.push('mb-i');
      if (BLOCK.test(me.display)) {
        if (me.align !== parent.align || el.parentElement.localName === 'section') {
          if (me.align === 'center') cls.push('mb-center');
          else if (me.align === 'right' || me.align === 'end') cls.push('mb-right');
          // 置中的區塊裡又改回靠左（清單、段落），不標的話會跟著上層一起置中
          else if (parent.align === 'center' || parent.align === 'right' || parent.align === 'end') cls.push('mb-left');
        }
        if (me.indent > 1 && tag === 'p') cls.push('mb-indent');
      }
      if (me.size < parent.size * 0.88 && !inHeading && tag !== 'sup' && tag !== 'sub') cls.push('mb-small');
      if (me.valign === 'super' && tag !== 'sup') cls.push('mb-sup');
      flags.push([el, cls]);
    }
    // 讀完才改：邊讀邊改會讓後面元素的計算值跟著變
    for (const [el, cls] of flags) {
      el.removeAttribute('style');
      el.removeAttribute('class');
      if (cls.length) el.setAttribute('class', cls.join(' '));
    }
    fdoc.body.querySelectorAll('section.mb-chapter').forEach((s) => { s.className = 'mb-chapter'; });
  }

  /* 注腳型的 <aside> 從正文收起，點注腳編號時用浮框顯示（docs/SPEC.md 13.5）。
   * 只收被 epub:type 標成注釋、或有連結指向的；拿來當側欄方塊的照常顯示。 */
  function hideFootnotes(root) {
    const targeted = new Set();
    root.querySelectorAll('a[data-internal]').forEach((a) => targeted.add(a.getAttribute('href').slice(1)));
    root.querySelectorAll('aside').forEach((aside) => {
      const type = epubType(aside);
      if (/\b(footnote|endnote|rearnote|note)\b/.test(type) || (aside.id && targeted.has(aside.id))) {
        aside.classList.add('mb-fn');
      }
    });
  }

  /* ── 標題、目錄與章 ───────────────────────────────────── */

  function assignHeadings() {
    const seen = new Map();
    const outline = [];
    content.querySelectorAll('h1, h2, h3, h4').forEach((el) => {
      const text = el.textContent.replace(/\s+/g, ' ').trim();
      if (!el.id) {
        const section = el.closest('section.mb-chapter');
        const base = (section ? section.id + '--' : '') + I().slugify(text);
        const n = (seen.get(base) || 0) + 1;
        seen.set(base, n);
        el.id = n === 1 ? base : `${base}-${n}`;
      }
      if (!text || el.closest('.mb-fn, .mb-hidden')) return;
      outline.push({ id: el.id, level: parseInt(el.tagName.substring(1), 10), text });
    });
    return outline;
  }

  /* 每個目錄項目在文件裡從哪個元素開始。依文件順序排好，之後用二分搜尋找所在章。 */
  function locateChapters() {
    BK.markers = [];
    BK.toc.forEach((entry, index) => {
      const el = document.getElementById(idFor(entry.path, entry.fragment)) || document.getElementById(prefixOf(entry.path));
      if (el) BK.markers.push({ el, index, level: entry.level || 1 });
    });
    BK.markers.sort((a, b) => {
      if (a.el === b.el) return a.index - b.index;
      return a.el.compareDocumentPosition(b.el) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
    });
  }

  /* 元素所在的章：文件順序上最後一個在它之前（含）的目錄項目 */
  function chapterOf(el) {
    if (!el) return null;
    let found = null;
    for (const m of BK.markers) {
      // 子孫也算 FOLLOWING（CONTAINED_BY 會連帶設 FOLLOWING）
      if (m.el === el || (m.el.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) found = m.index;
      else break;
    }
    return found;
  }

  /* 第 i 章的範圍：從它的起點到下一個同級或更上層目錄項目的起點 */
  function chapterRange(index) {
    const at = BK.markers.findIndex((m) => m.index === index);
    if (at === -1) return null;
    const start = BK.markers[at];
    let end = null;
    for (let i = at + 1; i < BK.markers.length; i++) {
      if (BK.markers[i].level <= start.level && BK.markers[i].el !== start.el) { end = BK.markers[i].el; break; }
    }
    return { start: start.el, end };
  }

  function inRange(el, range) {
    const afterStart = el === range.start || range.start.contains(el) ||
      (range.start.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING);
    const beforeEnd = !range.end || (el.compareDocumentPosition(range.end) & Node.DOCUMENT_POSITION_FOLLOWING);
    return !!afterStart && !!beforeEnd;
  }

  function headingsIn(range) {
    return [...content.querySelectorAll('h1, h2, h3, h4')].filter((h) => inRange(h, range) && !h.closest('.mb-fn'));
  }

  /* 點了某個標題：它在哪一章、是不是那一章的章名（章名對到心得的檔頭，不必提示「找不到小節」） */
  BK.describeHeading = function (h) {
    const chapter = chapterOf(h);
    let chapterTitle = false;
    if (chapter != null) {
      const range = chapterRange(chapter);
      const first = range ? headingsIn(range)[0] : null;
      const label = I().normHeading(BK.toc[chapter] ? BK.toc[chapter].label : '');
      chapterTitle = first === h || (label && I().normHeading(h.textContent) === label);
    }
    return { chapter, chapterTitle };
  };

  BK.syncTo = function (req) {
    BK.navigatedAt = Date.now();
    if (BK.fixed) { gotoChapterPage((req.chapters || [])[0], true); return; }
    const chapters = req.chapters || [];
    const ranges = chapters.map(chapterRange).filter(Boolean);
    if (!ranges.length) return;
    const candidates = ranges.flatMap(headingsIn);
    const hit = req.text ? I().bestHeading(candidates, req.text) : null;
    const fallback = headingsIn(ranges[0])[0] || ranges[0].start;
    I().landSync(hit || fallback, req, !!hit, '找不到對應小節，已跳到章首');
  };

  MB.scrollToChapter = function (index) {
    BK.navigatedAt = Date.now();
    if (BK.fixed) { gotoChapterPage(index, false); return; }
    const range = chapterRange(index);
    if (range) { range.start.scrollIntoView({ behavior: 'smooth', block: 'start' }); I().settleOn(range.start); }
  };

  /* ── 閱讀位置 ─────────────────────────────────────────
   * 書的章可能很長、標題很少，只用標題當錨點會差很遠。改用畫面頂端那個有 id
   * 的元素（書裡的段落、分頁標記多半有 id），沒有才退回標題。
   */
  function captureBookAnchor() {
    if (!BK.active || BK.fixed) return null;
    const rect = content.getBoundingClientRect();
    let el = document.elementFromPoint(rect.left + 60, 30);
    while (el && el !== content && !el.id) el = el.parentElement;
    if (el && el !== content && el.id && content.contains(el)) {
      return { id: el.id, delta: el.getBoundingClientRect().top };
    }
    return I().captureAnchor();
  }

  function restoreBookAnchor(anchor) {
    if (anchor && anchor.id && !document.getElementById(anchor.id) && typeof anchor.y !== 'number') {
      window.scrollTo(0, 0);
      return;
    }
    I().restoreAnchor(anchor);
  }

  // 給 app.js 的「寬度改變時守住閱讀位置」用
  BK.captureAnchor = () => captureBookAnchor();
  BK.restoreAnchor = (a) => restoreBookAnchor(a);

  function currentChapter() {
    let found = null;
    for (const m of BK.markers) {
      if (m.el.getBoundingClientRect().top <= 120) found = m.index;
      else break;
    }
    if (found == null && BK.markers.length) found = BK.markers[0].index;
    return found;
  }

  let positionTimer = null;
  /* initial：剛渲染完，只回報所在章，不存閱讀位置 —— 版面還沒穩，存下來的會是錯的 */
  function reportPosition(turned, initial) {
    if (!BK.active) return;
    if (BK.fixed) {
      toSwift({ type: 'bookPosition', chapter: chapterOfPage(fx.page), position: { page: fx.page }, turned });
      return;
    }
    BK.chapter = currentChapter();
    const msg = { type: 'bookPosition', chapter: BK.chapter, turned: false };
    if (!initial) msg.position = captureBookAnchor() || {};
    toSwift(msg);
  }

  window.addEventListener('scroll', () => {
    if (!BK.active || BK.fixed) return;
    clearTimeout(positionTimer);
    positionTimer = setTimeout(() => reportPosition(false), 400);
  }, { passive: true });

  /* ── 連結與注腳浮框 ─────────────────────────────────── */

  const popover = document.createElement('div');
  popover.id = 'mb-footnote';
  document.body.appendChild(popover);

  function closePopover() { popover.classList.remove('show'); popover.innerHTML = ''; }

  function attachLinks(root) {
    root.querySelectorAll('a[data-external]').forEach((a) => {
      a.addEventListener('click', (e) => { e.preventDefault(); toSwift({ type: 'openExternal', url: a.href }); });
    });
  }

  /* 注腳編號：被 epub:type 標成 noteref、指向收起來的 aside、或長得像編號（1、[2]、*） */
  function isNoteRef(a, target) {
    if (/\bnoteref\b/.test(epubType(a))) return true;
    if (target.closest('.mb-fn')) return true;
    const text = a.textContent.trim();
    return /^[\[(（]?[0-9０-９]{1,4}[\])）]?$|^[*＊†‡§]+$/.test(text) && !/^h[1-6]$/.test(target.localName);
  }

  function noteBlock(target) {
    const fn = target.closest('.mb-fn');
    if (fn) return fn;
    return target.closest('p, li, dd, aside, div, blockquote') || target;
  }

  content.addEventListener('click', (e) => {
    if (!BK.active || BK.fixed) return;
    const a = e.target.closest('a[data-internal]');
    if (!a) return;
    e.preventDefault();
    const target = document.getElementById(a.getAttribute('href').slice(1));
    if (!target) return;
    const block = noteBlock(target);
    if (isNoteRef(a, target) && block.textContent.length < 3000) {
      showPopover(a, block);
    } else {
      closePopover();
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });

  function showPopover(link, block) {
    const clone = block.cloneNode(true);
    clone.classList.remove('mb-fn', 'mb-hidden');
    clone.removeAttribute('id');
    clone.querySelectorAll('[id]').forEach((el) => el.removeAttribute('id'));
    // 注釋裡「返回正文」的連結在浮框裡沒有意義
    clone.querySelectorAll('a[data-internal]').forEach((a) => {
      const t = document.getElementById(a.getAttribute('href').slice(1));
      if (t && (t === link || t.contains(link) || link.contains(t))) a.remove();
    });
    clone.querySelectorAll('mark.mb-hl, mark.mb-hit').forEach((m) => m.replaceWith(...m.childNodes));
    popover.innerHTML = '';
    popover.appendChild(clone);
    popover.classList.add('show');

    const r = link.getBoundingClientRect();
    const w = popover.offsetWidth, h = popover.offsetHeight;
    let top = r.bottom + window.scrollY + 8;
    if (r.bottom + h + 16 > window.innerHeight) top = r.top + window.scrollY - h - 8;
    const left = Math.max(8, Math.min(r.left + window.scrollX - w / 2, window.innerWidth - w - 8));
    popover.style.top = Math.max(window.scrollY + 8, top) + 'px';
    popover.style.left = left + 'px';
  }

  popover.addEventListener('click', (e) => {
    const a = e.target.closest('a[data-internal]');
    if (!a) return;
    e.preventDefault();
    const t = document.getElementById(a.getAttribute('href').slice(1));
    closePopover();
    if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' });
  });

  document.addEventListener('mousedown', (e) => {
    if (!popover.classList.contains('show')) return;
    if (popover.contains(e.target) || e.target.closest('a[data-internal]')) return;
    closePopover();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePopover(); });

  /* ── 固定版面（docs/SPEC.md 13.9）─────────────────────── */

  const fx = { pages: [], spreads: [], page: 0, spread: true, rtl: false, chapterPages: [] };

  function renderFixed(payload, opts, anchor) {
    fx.pages = payload.pages || [];
    fx.rtl = !!payload.rtl;
    fx.spread = payload.spread !== false;
    // 每個目錄項目從第幾頁開始
    const indexOfPath = new Map(fx.pages.map((p, i) => [p.path, i]));
    fx.chapterPages = BK.toc.map((t) => indexOfPath.has(t.path) ? indexOfPath.get(t.path) : null);

    const saved = payload.position && typeof payload.position.page === 'number' ? payload.position.page : 0;
    fx.page = Math.min(Math.max(0, opts.keepScroll ? fx.page : saved), Math.max(0, fx.pages.length - 1));

    content.innerHTML = '<div id="mb-fxl"><div class="mb-fxl-stage"></div><div class="mb-fxl-indicator"></div></div>';
    toSwift({ type: 'outline', outline: [] });
    // 固定版面不能標記：給標記模組一份「唯讀、沒有內容」的狀態
    if (window.MBHighlights && opts.highlights) {
      window.MBHighlights.afterRender(Object.assign({}, opts.highlights, { writable: false, reason: '固定版面的書不能標記' }), null);
    }
    layoutFixed();
    reportPosition(false);
  }

  /* 欄寬夠才跨頁：單頁會小於約 400pt 就退回單頁 */
  function useSpread() {
    return fx.spread && content.clientWidth / 2 >= 400;
  }

  function spreadsFor(spread) {
    const out = [];
    if (!spread) { fx.pages.forEach((_, i) => out.push([i])); return out; }
    let i = 0;
    out.push([0]);                                        // 封面單獨一頁
    i = 1;
    while (i < fx.pages.length) {
      const p = fx.pages[i];
      if (p.spread === 'page-spread-center' || i + 1 >= fx.pages.length) { out.push([i]); i += 1; continue; }
      out.push([i, i + 1]);
      i += 2;
    }
    return out;
  }

  function currentSpreadIndex() {
    return Math.max(0, fx.spreads.findIndex((s) => s.includes(fx.page)));
  }

  function layoutFixed() {
    const stage = content.querySelector('.mb-fxl-stage');
    if (!stage || !fx.pages.length) return;
    fx.spreads = spreadsFor(useSpread());
    const spread = fx.spreads[currentSpreadIndex()];
    const order = fx.rtl ? [...spread].reverse() : spread;
    const availW = content.clientWidth - 24, availH = window.innerHeight - 56;
    const totalW = order.reduce((s, i) => s + fx.pages[i].width, 0);
    const maxH = Math.max(...order.map((i) => fx.pages[i].height));
    const scale = Math.min(availW / totalW, availH / maxH);

    stage.style.width = totalW * scale + 'px';
    stage.style.height = maxH * scale + 'px';
    // 同一組頁面（只是視窗縮放）就只改尺寸，不重建 iframe —— 重建會整頁閃白
    const key = order.join(',');
    if (stage.dataset.pages === key) {
      [...stage.children].forEach((box, n) => {
        const p = fx.pages[order[n]];
        box.style.width = p.width * scale + 'px';
        box.style.height = p.height * scale + 'px';
        box.firstChild.style.transform = `scale(${scale})`;
      });
      updateIndicator(spread);
      return;
    }
    stage.dataset.pages = key;
    stage.innerHTML = '';
    for (const i of order) {
      const p = fx.pages[i];
      const box = document.createElement('div');
      box.className = 'mb-fxl-page';
      box.style.width = p.width * scale + 'px';
      box.style.height = p.height * scale + 'px';
      const frame = document.createElement('iframe');
      frame.src = bookURL(p.path);
      frame.setAttribute('scrolling', 'no');
      frame.style.width = p.width + 'px';
      frame.style.height = p.height + 'px';
      frame.style.transform = `scale(${scale})`;
      box.appendChild(frame);
      stage.appendChild(box);
    }
    updateIndicator(spread);
  }

  function updateIndicator(spread) {
    const label = spread.length > 1 ? `${spread[0] + 1}–${spread[1] + 1}` : `${spread[0] + 1}`;
    content.querySelector('.mb-fxl-indicator').textContent = `${label}／${fx.pages.length}`;
  }

  function chapterOfPage(page) {
    let found = null;
    fx.chapterPages.forEach((start, i) => { if (start != null && start <= page) found = i; });
    return found;
  }

  function turn(delta) {
    if (!BK.fixed || !fx.spreads.length) return;
    const next = Math.min(Math.max(0, currentSpreadIndex() + delta), fx.spreads.length - 1);
    if (fx.spreads[next][0] === fx.page) return;
    fx.page = fx.spreads[next][0];
    layoutFixed();
    reportPosition(true);
  }

  function gotoChapterPage(index, flashIt) {
    const page = index != null ? fx.chapterPages[index] : null;
    if (page == null) return;
    fx.page = page;
    layoutFixed();
    reportPosition(false);
    if (flashIt) {
      const ind = content.querySelector('.mb-fxl-indicator');
      if (ind) { ind.classList.remove('mb-sync-flash'); void ind.offsetWidth; ind.classList.add('mb-sync-flash'); }
    }
  }

  /* ← 上一頁、→ 下一頁。右翻左的固定版面書反過來：按鍵跟著畫面走，← 前往左邊那頁
   * （也就是下一頁），跟紙本與漫畫閱讀器一樣。
   * 可重排的書一律橫排顯示，不管原書是不是右翻左，← 都是上一頁。
   * 可重排的書「一頁」是一個畫面高，留兩行重疊，翻過去還接得上剛才讀到的地方。 */
  document.addEventListener('keydown', (e) => {
    if (!BK.active || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey && e.key !== ' ') return;
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight' && !BK.fixed) return;
    const step = e.key === 'ArrowLeft' ? -1 : e.key === 'ArrowRight' ? 1 : 0;
    if (step && !BK.fixed) {
      e.preventDefault();
      closePopover();
      const lineGap = parseFloat(getComputedStyle(document.body).lineHeight) || 32;
      window.scrollBy({ top: step * Math.max(100, window.innerHeight - lineGap * 2), behavior: 'auto' });
      return;
    }
    if (step) { e.preventDefault(); turn(fx.rtl ? -step : step); }
    else if (e.key === ' ') { e.preventDefault(); turn(e.shiftKey ? -1 : 1); }
    else if (e.key === 'PageDown') { e.preventDefault(); turn(1); }
    else if (e.key === 'PageUp') { e.preventDefault(); turn(-1); }
  });

  /* 觸控板左右滑：累積到一個門檻才翻一頁，翻完冷卻一下，免得一次滑過好幾頁 */
  let wheelAcc = 0, wheelLock = 0;
  window.addEventListener('wheel', (e) => {
    if (!BK.fixed) return;
    e.preventDefault();
    const now = Date.now();
    if (now < wheelLock) return;
    const dx = e.deltaX, dy = e.deltaY;
    wheelAcc += Math.abs(dx) > Math.abs(dy) ? dx * (fx.rtl ? -1 : 1) : dy;
    if (Math.abs(wheelAcc) > 80) {
      turn(wheelAcc > 0 ? 1 : -1);
      wheelAcc = 0;
      wheelLock = now + 450;
    }
  }, { passive: false });

  window.addEventListener('resize', () => { if (BK.fixed) layoutFixed(); });
})();
