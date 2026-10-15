/* book.js —— 書那一欄（docs/SPEC.md 第 13 節）。
 *
 * 可重排的書：Swift 把每個 spine 檔的原文與所有 CSS 一次送來，這裡串成一條。
 * 樣式「先讀後丟」：在一個看不見的 iframe 裡套上書自己的 CSS，用 getComputedStyle
 * 讀出每個元素實際上是不是粗體、斜體、置中、縮排、小字，轉成我們的 mb-* class，
 * 再把書的 CSS 與 class 全部丟掉、套我們的樣式。粗體因此也只換色、不加粗。
 *
 * 固定版面的書：每頁是一個 iframe（mbres://book/…），等比縮放、翻頁式顯示，
 * 不套我們的樣式、不能標記。
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
    layout: 'single',     // scroll / single / double（docs/SPEC.md 13.12）
  };
  window.MBBook = BK;
  // 翻頁模式只用在可重排的書；心得那欄（BK.active 為假）一律捲動
  Object.defineProperty(BK, 'paged', { get: () => BK.active && !BK.fixed && BK.layout !== 'scroll' });

  BK.deactivate = function () {
    if (!BK.active) return;
    BK.active = false;
    BK.fixed = false;
    BK.toc = [];
    BK.markers = [];
    BK.chapter = null;
    document.documentElement.classList.remove('mb-book-mode', 'mb-fixed-mode', 'mb-paged', 'mb-double');
    hideFullpage();
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
    const end = document.createElement('div');
    end.className = 'mb-end';
    content.appendChild(end);
    activateImages();
    applyLayout();

    markImagePages();
    const outline = assignHeadings();
    locateChapters();
    outline.forEach((o) => { o.chapter = chapterOf(document.getElementById(o.id)); });

    if (hl) hl.afterRender(opts.highlights, kept);

    const target = anchor || payload.position;
    if (target) restoreBookAnchor(target);
    else { window.scrollTo(0, 0); content.scrollLeft = 0; }
    updateIndicators();
    // 圖片載入後版面會變，載完再回位一次（使用者已經自己捲了就不動）
    // 之後若被同步帶走（navigatedAt 更新）就不再拉回來
    const renderedAt = Date.now();
    I().afterLayout(() => {
      fixPushedLines();
      if (target && !I().userMoved() && BK.navigatedAt < renderedAt) restoreBookAnchor(target);
      updateIndicators();
    });

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
    promotePseudoHeadings(frag, payload.toc);
    // 注腳要整本一起看：連結與它指向的 aside 常在不同章
    hideFootnotes(frag);
    attachLinks(frag);
    return frag;
  }


  /* 偽標題升格成真的標題：大綱、同步、下拉選單的小節才找得到它們。
   * 層級看書的目錄：目錄指到的那幾個（「3.1（小節名）」）照目錄層級，同一種樣式
   * （原本的 class）的其他段落跟它同一層；目錄沒指到的樣式放在下一層。只用字級或出現次數排
   * 不可靠 —— 《書 E》有六種一樣 1.29em 的粗體樣式，小節標題會被擠到最底層。
   * 書完全沒有目錄可對時，才依字級由大到小排（同字級同一層）。從 h2 開始，h1 留給書自己標的章名。 */
  function promotePseudoHeadings(root, toc) {
    const els = [...root.querySelectorAll('[data-mb-ph]')];
    if (!els.length) return;
    const tocLevel = new Map();
    for (const t of toc || []) tocLevel.set(idFor(t.path, t.fragment), t.level || 1);
    const keyOf = (el) => el.getAttribute('data-mb-ph').split('|')[0];
    const groupLevel = new Map();
    for (const el of els) {
      if (!el.id || !tocLevel.has(el.id)) continue;
      const lv = Math.max(2, tocLevel.get(el.id));
      const key = keyOf(el);
      groupLevel.set(key, Math.min(groupLevel.get(key) || 9, lv));
    }
    let levelOf;
    if (groupLevel.size) {
      const below = Math.min(4, Math.max(...groupLevel.values()) + 1);
      levelOf = (el) => groupLevel.get(keyOf(el)) || below;
    } else {
      const sizes = [...new Set(els.map((el) => parseFloat(el.getAttribute('data-mb-ph').split('|')[1])))]
        .sort((a, b) => b - a);
      levelOf = (el) => 2 + sizes.indexOf(parseFloat(el.getAttribute('data-mb-ph').split('|')[1]));
    }
    for (const el of els) {
      const h = document.createElement('h' + Math.min(4, levelOf(el)));
      for (const attr of [...el.attributes]) {
        if (attr.name !== 'data-mb-ph') h.setAttribute(attr.name, attr.value);
      }
      h.classList.remove('mb-b', 'mb-small');          // 標題走標題的字級與顏色，不吃粗體那條規則
      if (!h.getAttribute('class')) h.removeAttribute('class');
      while (el.firstChild) h.appendChild(el.firstChild);
      el.replaceWith(h);
    }
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
          // 四邊都有框線：書用方框圈起來的小標、重點（《書 E》的「【第一類】…」）
          boxed: ['Top', 'Right', 'Bottom', 'Left'].every((side) =>
            !/^(none|hidden)$/.test(c[`border${side}Style`]) && parseFloat(c[`border${side}Width`]) > 0),
        };
        cache.set(el, cs);
      }
      return cs;
    };

    const flags = [];
    const boxes = new Set();
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
      // 框線的顏色、粗細、圓角都不照書（書是淺灰底白紙配的），只留「這裡有個框」
      // 框裡又有框（書的外框套內框）只畫外面那個
      if (me.boxed && /^(block|flow-root|flex|grid)$/.test(me.display) && !/^(hr|img|table|td|th)$/.test(tag)) {
        let inner = false;
        for (let p = el.parentElement; p && !inner; p = p.parentElement) inner = boxes.has(p);
        if (!inner) { cls.push('mb-box'); boxes.add(el); }
      }
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
    // 章名與副標常用同一層標籤（《書 A》兩個都是 h1，靠書的 CSS 分 1.5em 與 1.1em）。
    // 書的 CSS 丟掉之後兩個一樣大，所以比原書字級：同一章裡同層標題，比第一個小兩成以上的
    // 就是副標，往下降一級顯示
    for (const sec of fdoc.body.querySelectorAll('section.mb-chapter')) {
      const first = {};
      for (const h of sec.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
        const size = parseFloat(win.getComputedStyle(h).fontSize) || 0;
        const tag = h.localName;
        if (!first[tag]) { first[tag] = size; continue; }
        if (size && size < first[tag] * 0.85) {
          const entry = flags.find(([el]) => el === h);
          if (entry) entry[1].push('mb-subhead');
        }
      }
    }
    // 偽標題：有些書（calibre 轉出來的特別多）整本沒有標題標籤，章節標題是一段加大加粗的
    // <p class="titleinbig">。書的 CSS 丟掉後只剩粗體，變成一段橘色的普通文字，大綱也是空的。
    // 這裡先記下候選：短、加粗、字級比內文大一截的段落，連同它原本的 class 與字級，
    // 等整本讀完再依樣式排出層級（promotePseudoHeadings）
    const body = parseFloat(win.getComputedStyle(fdoc.body).fontSize) || 16;
    for (const [el] of flags) {
      if (el.localName !== 'p' && el.localName !== 'div') continue;
      if (el.closest('h1, h2, h3, h4, h5, h6, li, table, aside, blockquote, figure')) continue;
      if (el.querySelector('p, div, img, svg, table, ul, ol')) continue;
      const text = el.textContent.replace(/\s+/g, '');
      // 只排除句號結尾的：問句當標題很常見（「適合誰？」「4.1（問句小節名）？」）
      if (!text || text.length > 80 || /[。.]$/.test(text)) continue;
      const me = style(el);
      if (me.weight < 600 || me.size < body * 1.12) continue;
      el.setAttribute('data-mb-ph', `${el.getAttribute('class') || 'size'}|${Math.round(me.size * 10) / 10}`);
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

  /* 只有一張圖、沒有文字的章（封面、書名頁）。翻頁模式下翻到它時滿版顯示（docs/SPEC.md 13.12） */
  function markImagePages() {
    for (const sec of content.querySelectorAll(':scope > section.mb-chapter')) {
      const pics = sec.querySelectorAll('img, svg');
      if (pics.length === 1 && !sec.textContent.trim()) sec.classList.add('mb-imgpage');
    }
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
    if (req.quote) { syncQuote(req); return; }
    if (BK.fixed) { gotoChapterPage((req.chapters || [])[0], true); return; }
    const chapters = req.chapters || [];
    const ranges = chapters.map(chapterRange).filter(Boolean);
    if (!ranges.length) return;
    const candidates = ranges.flatMap(headingsIn);
    const hit = req.text ? I().bestHeading(candidates, req.text) : null;
   
    // 標題對不到：拿心得標題的關鍵詞去這一章的內文找（docs/SPEC.md 13.6）。
    // 點的是章名（quiet）就不找，章首正是要去的地方
    if (!hit && req.text && !req.quiet) {
      const k = keywordHit(ranges, req.text);
      if (k) { landRange(k.range, req, `依關鍵詞「${k.word}」對到內文`); return; }
    }
    const fallback = headingsIn(ranges[0])[0] || ranges[0].start;
    I().landSync(hit || fallback, req, !!hit, '找不到對應小節，已跳到章首');
  };

  /* ── 關鍵詞找內文（docs/SPEC.md 13.6）────────────────────
   * 關鍵詞是心得標題與這一章內文的最長重疊字串，至少 3 個字，頭尾是虛詞的不算 ——
   * 「的結果」「同一個」這類只是虛詞組合，照著跳會落在不相干的段落。
   * 出現好幾次就用第一次：書第一次提到一個人名或故事，幾乎都是那段的開頭。 */
  const FUNCTION_CHARS = new Set('的了與是在和就也而或及之把被讓不個成'.split(''));

  /* 這幾章的內文：文字節點依序接起來、拿掉空白，另外記住每個字在哪個節點的第幾個位置。
   * mapChar 可以換掉比對用的字（引文比對要連標點一起拿掉、異體字歸一），回空字串就跳過 */
  function chapterText(ranges, mapChar) {
    let text = '';
    const where = [];
    for (const range of ranges) {
      const w = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
      w.currentNode = range.start;
      let n = range.start.nodeType === 3 ? range.start : w.nextNode();
      for (; n; n = w.nextNode()) {
        if (range.end && (n === range.end || range.end.contains(n) ||
            (range.end.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_FOLLOWING))) break;
        if (n.parentElement.closest('.mb-fn, .mb-hidden, script, style')) continue;
        const d = n.data;
        for (let i = 0; i < d.length; i++) {
          const c = mapChar ? mapChar(d[i]) : (/\s/.test(d[i]) ? '' : d[i]);
          for (const x of c) { text += x; where.push([n, i]); }
        }
      }
    }
    return { text, where };
  }

  function keywordHit(ranges, heading) {
    const h = I().normHeading(heading);
    if (h.length < 3) return null;
    const { text, where } = chapterText(ranges);
    if (!text) return null;
    let best = '';
    for (let i = 0; i < h.length; i++) {
      if (FUNCTION_CHARS.has(h[i])) continue;
      for (let j = h.length; j - i >= Math.max(3, best.length + 1); j--) {
        if (FUNCTION_CHARS.has(h[j - 1])) continue;
        const sub = h.slice(i, j);
        if (text.includes(sub)) { best = sub; break; }
      }
    }
    if (best.length < 3) return null;
    return { word: best, range: rangeOf(where, text.indexOf(best), best.length) };
  }

  function rangeOf(where, at, length) {
    const [sn, so] = where[at];
    const [en, eo] = where[at + length - 1];
    const range = document.createRange();
    range.setStart(sn, so);
    range.setEnd(en, eo + 1);
    return range;
  }

  /* ── 引文找原文（docs/SPEC.md 13.6）──────────────────────
   * 心得的引文多半一字不差抄自書，但標點、空白常被改（全形半形、引號種類、斷行），
   * 書又常用異體字（「爲」「着」「裏」）。所以兩邊都拿掉空白與標點、異體字歸一再比。
   * 先找對應的章：完整出現，或最長的一段重疊（至少 8 個字、也至少佔引文四成，提示是部分
   * 對到的）。這一章都沒有才找全書（引文可能出自別章）。 */
  const VARIANTS = {};
  for (const pair of ['爲為', '着著', '裏裡', '綫線', '衆眾', '眞真', '敎教', '説說', '緖緒', '户戶', '啓啟',
    '峯峰', '羣群', '僞偽', '産產', '鎭鎮', '衞衛', '内內', '兑兌', '税稅', '脱脫', '鋭銳', '悦悅', '閲閱',
    '値值', '吿告', '黄黃', '尙尚', '颜顏', '彥彦', '淸清', '靑青', '卽即', '旣既', '槪概', '曁暨']) {
    VARIANTS[pair[0]] = pair[1];
  }

  function quoteChar(c) {
    if (/[\s\p{P}\p{S}]/u.test(c)) return '';
    const k = c.normalize('NFKC').toLowerCase();          // 全形數字與英文歸成半形
    return [...k].map((x) => VARIANTS[x] || x).filter((x) => !/[\s\p{P}\p{S}]/u.test(x)).join('');
  }

  function quoteKey(text) {
    return [...text].map(quoteChar).join('');
  }

  function quoteHit(ranges, quote, partial) {
    const q = quoteKey(quote);
    if (!q) return null;
    const { text, where } = chapterText(ranges, quoteChar);
    const at = text.indexOf(q);
    if (at !== -1) return { range: rangeOf(where, at, q.length), whole: true };
    if (!partial || q.length < 8) return null;
    const min = Math.max(8, Math.ceil(q.length * 0.4));
    let best = '', bestAt = -1;
    for (let i = 0; i + min <= q.length; i++) {
      for (let j = q.length; j - i >= Math.max(min, best.length + 1); j--) {
        const k = text.indexOf(q.slice(i, j));
        if (k !== -1) { best = q.slice(i, j); bestAt = k; break; }
      }
    }
    return best ? { range: rangeOf(where, bestAt, best.length), whole: false } : null;
  }

  function syncQuote(req) {
    // 固定版面是圖，沒有文字可找：照標題同步的做法翻到那一章
    if (BK.fixed) {
      if ((req.chapters || []).length) gotoChapterPage(req.chapters[0], true);
      else MB.toast('固定版面的書沒有文字可以比對');
      return;
    }
    // 引文就是章名（心得檔頭的「第4章：…」）：到那一章章首。章首常是一張圖，正文裡同樣的字
    // 只出現在書末的參考文獻
    const key = quoteKey(req.quote);
    const titled = BK.toc.findIndex((t) => quoteKey(t.label) === key);
    const titledRange = titled !== -1 ? chapterRange(titled) : null;
    if (titledRange) {
      I().landSync(headingsIn(titledRange)[0] || titledRange.start, req, true, null);
      return;
    }
    // 先找這一章（含部分對到），才找全書：別章也有同樣字句時（參考文獻、總結），這一章優先
    const chapters = (req.chapters || []).map(chapterRange).filter(Boolean);
    const whole = [{ start: content, end: content.querySelector(':scope > .mb-end') }];
    const hit = (chapters.length && (quoteHit(chapters, req.quote, false) || quoteHit(chapters, req.quote, true))) ||
      quoteHit(whole, req.quote, false) ||
      (!chapters.length && quoteHit(whole, req.quote, true));
    if (!hit) { MB.toast('書裡找不到這段引文'); return; }
    landRange(hit.range, req, hit.whole ? null : '書裡沒有完全相同的句子，已跳到最接近的一段');
  }

  /* 捲（翻）到那幾個字，只閃那幾個字。note 是提示（依關鍵詞推測、部分對到），沒有就不提示 */
  function landRange(range, req, note) {
    const rect = range.getClientRects()[0] || range.getBoundingClientRect();
    const background = !!req.background;
    if (BK.paged) {
      goView(viewOfX(rect.left), !background);
    } else {
      window.scrollTo({ top: Math.max(0, window.scrollY + rect.top - 80), behavior: background ? 'auto' : 'smooth' });
    }
    const show = () => { flashRange(range); if (note) MB.toast(note); };
    if (background) I().setPendingSync(show);
    else setTimeout(show, BK.paged ? 280 : 500);
  }

  /* 不動 DOM：在那幾個字的位置上蓋一層會淡出的底色。包一層 span 的話，標記的文字位置
   * 不變，但重畫標記時會被拆掉、殘留的 span 也會跟搜尋命中互相干擾 */
  function flashRange(range) {
    for (const q of range.getClientRects()) {
      if (q.width < 1) continue;
      const d = document.createElement('div');
      d.className = 'mb-kw-flash';
      d.style.left = q.left - 2 + 'px';
      d.style.top = q.top - 1 + 'px';
      d.style.width = q.width + 4 + 'px';
      d.style.height = q.height + 2 + 'px';
      document.body.appendChild(d);
      setTimeout(() => d.remove(), 1600);
    }
  }

  MB.scrollToChapter = function (index) {
    BK.navigatedAt = Date.now();
    if (BK.fixed) { gotoChapterPage(index, false); return; }
    const range = chapterRange(index);
    if (range) { I().reveal(range.start, true); I().settleOn(range.start); }
  };

  /* ── 閱讀位置 ─────────────────────────────────────────
   * 記兩種：畫面頂端那個有 id 的元素加偏移（捲動模式精準回位用），以及
   * 「第幾章（spine 檔）的第幾個字」（sec／off）。書裡的段落多半沒有 id，往上找會找到
   * 整章的 section；翻頁模式要知道「哪一頁」，只能靠文字位置。兩種模式互相切換時也靠它。
   */
  function sectionOf(node) {
    const el = node && (node.nodeType === 1 ? node : node.parentElement);
    return el ? el.closest('section.mb-chapter') : null;
  }

  function offsetIn(sec, node, off) {
    const r = document.createRange();
    r.setStart(sec, 0);
    r.setEnd(node, off);
    return r.toString().length;
  }

  function pointAt(sec, off) {
    const w = document.createTreeWalker(sec, NodeFilter.SHOW_TEXT);
    let n, pos = 0, last = null;
    while ((n = w.nextNode())) {
      if (pos + n.data.length > off) return { node: n, off: Math.max(0, off - pos) };
      pos += n.data.length;
      last = n;
    }
    return last ? { node: last, off: last.data.length } : null;
  }

  function rectAt(p) {
    const r = document.createRange();
    r.setStart(p.node, p.off);
    r.setEnd(p.node, Math.min(p.node.data.length, p.off + 1));
    const rects = r.getClientRects();
    return rects.length ? rects[0] : r.getBoundingClientRect();
  }

  /* 閱讀起點：翻頁模式是這一頁的左上角，捲動模式是畫面頂端的第一行 */
  function readingPoint() {
    let x0, y0;
    if (BK.paged) { const g = geom(); x0 = g.side; y0 = g.top; }
    else {
      const r = content.getBoundingClientRect();
      x0 = r.left + (parseFloat(getComputedStyle(content).paddingLeft) || 0);
      y0 = 24;
    }
    // 行首可能是縮排的空白或圖片，沿著第一行往右、往下各試幾個點
    for (const dy of [4, 24, 48]) {
      for (let dx = 2; dx < 400; dx += 36) {
        const range = document.caretRangeFromPoint(x0 + dx, y0 + dy);
        if (range && content.contains(range.startContainer) && range.startContainer.nodeType === 3) return range;
      }
    }
    return null;
  }

  function captureBookAnchor() {
    if (!BK.active || BK.fixed) return null;
    const out = {};
    const range = readingPoint();
    const sec = range && sectionOf(range.startContainer);
    if (sec) { out.sec = sec.id; out.off = offsetIn(sec, range.startContainer, range.startOffset); }
    if (!BK.paged) {
      const rect = content.getBoundingClientRect();
      let el = document.elementFromPoint(rect.left + 60, 30);
      while (el && el !== content && !el.id) el = el.parentElement;
      if (el && el !== content && el.id && content.contains(el)) {
        out.id = el.id;
        out.delta = el.getBoundingClientRect().top;
      } else if (!out.sec) {
        return I().captureAnchor();
      }
    } else if (!out.sec) {
      const s = chapterSpan();
      if (s.secs[s.idx]) { out.sec = s.secs[s.idx].id; out.off = 0; }
    }
    return out;
  }

  /* 錨點在畫面上的位置（rect）。文字位置優先，沒有才用元素 */
  function anchorRect(anchor) {
    if (anchor.sec) {
      const sec = document.getElementById(anchor.sec);
      if (sec) {
        const p = pointAt(sec, anchor.off || 0);
        return p ? rectAt(p) : sec.getBoundingClientRect();
      }
    }
    if (anchor.id) {
      const el = document.getElementById(anchor.id);
      if (el) return (el.getClientRects()[0]) || el.getBoundingClientRect();
    }
    return null;
  }

  function restoreBookAnchor(anchor) {
    if (!anchor) return;
    if (BK.paged) {
      const r = anchorRect(anchor);
      goView(r ? viewOfX(r.left) : 0, false);
      return;
    }
    // 捲動模式：有元素加偏移就用它（最精準）；從翻頁模式來的只有文字位置
    if (anchor.id && typeof anchor.delta === 'number' && document.getElementById(anchor.id)) {
      I().restoreAnchor(anchor);
      return;
    }
    if (anchor.sec) {
      const r = anchorRect(anchor);
      if (r) { window.scrollTo(0, Math.max(0, window.scrollY + r.top - 24)); return; }
    }
    if (typeof anchor.y === 'number') { I().restoreAnchor(anchor); return; }
    window.scrollTo(0, 0);
  }

  // 給 app.js 的「寬度改變時守住閱讀位置」用
  BK.captureAnchor = () => captureBookAnchor();
  BK.restoreAnchor = (a) => restoreBookAnchor(a);

  function currentChapter() {
    let found = null;
    if (BK.paged) {
      const first = firstCol();
      for (const m of BK.markers) {
        if (colOf(m.el) <= first) found = m.index;
        else break;
      }
    } else {
      for (const m of BK.markers) {
        if (m.el.getBoundingClientRect().top <= 120) found = m.index;
        else break;
      }
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

  const onBookScroll = () => {
    if (!BK.active || BK.fixed) return;
    clearTimeout(positionTimer);
    positionTimer = setTimeout(() => { reportPosition(false); updateIndicators(); }, 400);
  };
  window.addEventListener('scroll', onBookScroll, { passive: true });
  content.addEventListener('scroll', onBookScroll, { passive: true });   // 翻頁模式

  /* ── 翻頁模式（docs/SPEC.md 13.12）──────────────────────── */

  const pageLeft = document.createElement('div');
  pageLeft.id = 'mb-page-left';
  pageLeft.className = 'mb-pageinfo';
  const pageRight = document.createElement('div');
  pageRight.id = 'mb-page-right';
  pageRight.className = 'mb-pageinfo';
  const turnPrev = document.createElement('div');
  turnPrev.id = 'mb-turn-prev';
  turnPrev.className = 'mb-turn';
  turnPrev.textContent = '‹';
  const turnNext = document.createElement('div');
  turnNext.id = 'mb-turn-next';
  turnNext.className = 'mb-turn';
  turnNext.textContent = '›';
  document.body.append(pageLeft, pageRight, turnPrev, turnNext);
  turnPrev.addEventListener('click', () => { closePopover(); turnPage(-1); });
  turnNext.addEventListener('click', () => { closePopover(); turnPage(1); });

  let doubleNow = false;    // 實際顯示雙頁（選了雙頁、而且欄夠寬）

  /* 滿版的封面與書名頁：多欄版面裡的圖撐不到上下留白之外（容器上下不能有 padding，見 base.css），
   * 所以停在這種頁面時，另外蓋一層把圖從頁面頂端放到底部。雙頁時只蓋那一側。
   * 翻頁滑動中先拿掉，停下來才蓋上，滑動時看到的是版面裡原本的小圖。 */
  const fullpage = document.createElement('div');
  fullpage.id = 'mb-fullpage';
  document.body.appendChild(fullpage);

  function hideFullpage() {
    fullpage.classList.remove('show');
    fullpage.innerHTML = '';
    pageLeft.style.visibility = '';
    pageRight.style.visibility = '';
  }

  function showFullpage() {
    hideFullpage();
    if (!BK.paged) return;
    const pages = [...content.querySelectorAll(':scope > section.mb-imgpage')];
    if (!pages.length) return;
    const first = firstCol();
    const g = geom();
    let any = false;
   
    for (let i = 0; i < g.n; i++) {
      const slot = document.createElement('div');
      slot.className = 'mb-fullpage-slot';
      const sec = pages.find((p) => colOf(p) === first + i);
      if (sec) {
        const pic = sec.querySelector('img, svg').cloneNode(true);
        pic.removeAttribute('id');
        slot.classList.add('filled');
        slot.appendChild(pic);
        any = true;
      }
      fullpage.appendChild(slot);
    }
    fullpage.style.gridTemplateColumns = `repeat(${g.n}, 1fr)`;
    if (any) fullpage.classList.add('show'); else fullpage.innerHTML = '';
    // 滿版的那一側不顯示頁碼：左下的本章頁碼在第一頁、右下的百分比在最後一頁
    const slots = [...fullpage.children];
    pageLeft.style.visibility = slots[0] && slots[0].classList.contains('filled') ? 'hidden' : '';
    pageRight.style.visibility = slots.length && slots[slots.length - 1].classList.contains('filled') ? 'hidden' : '';
  }

  /* 翻頁模式由 #content 自己橫向捲動（scrollLeft），不是整份文件 —— 根元素設了
   * overflow:hidden 之後，WebKit 不讓文件橫向捲動，window.scrollTo 會沒反應。
   * 欄寬與一欄的跨距：欄距是左右留白的兩倍，所以單頁一欄＋欄距＝一個畫面寬 */
  function geom() {
    const cs = getComputedStyle(content);
    const side = parseFloat(cs.paddingLeft) || 0;
    // 要用小數的寬度：clientWidth 會四捨五入（818.75 → 819），每頁差 0.25px，
    // 翻到第 80 頁就累積差 20px，元素會被算到前一頁、翻頁也會慢慢偏掉
    const vw = content.getBoundingClientRect().width;
    const n = doubleNow ? 2 : 1;
    const gap = parseFloat(cs.columnGap) || side * 2;
    const colW = (vw - side * 2 - (n - 1) * gap) / n;
    return { side, top: content.getBoundingClientRect().top, vw, n, gap, stride: colW + gap };
  }

  /* 選了雙頁但每頁不足 30 個字：暫時顯示單頁，設定仍記著雙頁 */
  function applyLayout() {
    const html = document.documentElement;
    html.classList.toggle('mb-paged', BK.paged);
    let dbl = false;
    if (BK.paged && BK.layout === 'double') {
      const fs = parseFloat(getComputedStyle(document.body).fontSize) || 17;
      const side = parseFloat(getComputedStyle(content).paddingLeft) || 0;
      dbl = (document.documentElement.clientWidth - side * 4) / 2 >= fs * 30;
    }
    doubleNow = dbl;
    html.classList.toggle('mb-double', dbl);
    if (!BK.paged && content.scrollLeft) content.scrollLeft = 0;
    fixPushedLines();
  }

  /* 頁尾殘字（WebKit 的繪製問題）：段落開頭剛好落在頁尾、放不下一整行時，WebKit 把第一行
   * 推到下一頁，卻仍在上一頁底部畫出那一行的一截（連首行縮排都看得到）。偵測這種「方框在
   * 上一頁只有不到一行高」的區塊，讓它直接從下一頁開始 —— 那一行本來就在下一頁，排版結果
   * 不變，後面的內容也不會位移，只是殘影沒了。用裁切擋不乾淨：殘影與正常的最後一行可能重疊。
   * 版面每次改變（字級、欄寬、單雙頁、圖片載入）都要先拿掉舊的標記再重新量。 */
  const BLOCKS = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, dd, dt, figcaption, pre';
  function fixPushedLines() {
    content.querySelectorAll('.mb-pushed').forEach((el) => el.classList.remove('mb-pushed'));
    if (!BK.paged) return;
    const pushed = [];
    for (const el of content.querySelectorAll(BLOCKS)) {
      const rects = el.getClientRects();
      if (rects.length < 2) continue;
      const lh = parseFloat(getComputedStyle(el).lineHeight) || 30;
      if (rects[0].height < lh - 1) pushed.push(el);
    }
    pushed.forEach((el) => el.classList.add('mb-pushed'));
  }
  BK.fixPushedLines = () => fixPushedLines();

  /* 字型晚到（冷啟動時霞鶩文楷要好幾秒才解完）會讓整本重新斷行，前面量的就不準了：
   * 字型載完就重量一次，並停在原本讀到的地方 */
  if (document.fonts && document.fonts.addEventListener) {
    document.fonts.addEventListener('loadingdone', () => {
      if (!BK.paged) return;
      const anchor = captureBookAnchor();
      fixPushedLines();
      if (anchor) restoreBookAnchor(anchor);
      updateIndicators();
    });
  }

  /* 每次換頁再檢查這一頁的頁尾：只看畫面上那一兩欄底部的區塊，很便宜，
   * 補上任何漏網的情況（版面在全面檢查之後又被別的原因改變） */
  function fixPushedOnView() {
    if (!BK.paged) return;
    const g = geom();
    const bottom = content.getBoundingClientRect().bottom;
    for (let c = 0; c < g.n; c++) {
      for (const dy of [3, 10, 20]) {
        const x = g.side + c * g.stride + 40;
        const el = document.elementFromPoint(x, bottom - dy);
        const block = el && el.closest && el.closest(BLOCKS);
        if (!block || !content.contains(block) || block.classList.contains('mb-pushed')) continue;
        const rects = block.getClientRects();
        const lh = parseFloat(getComputedStyle(block).lineHeight) || 30;
        if (rects.length > 1 && rects[0].height < lh - 1) block.classList.add('mb-pushed');
      }
    }
  }

  /* 畫面上某個 x 座標落在第幾欄。以「目前這一頁」為基準往前後算，不從第一頁累加 ——
   * 欄寬是小數，從頭累加幾十頁後誤差會大到把元素算進前一頁 */
  function colOfX(left) {
    const g = geom();
    const rel = left - content.getBoundingClientRect().left;
    const v = Math.floor((rel + 1) / g.vw);
    const within = rel - v * g.vw;
    const c = Math.min(g.n - 1, Math.max(0, Math.floor((within - g.side + g.gap / 2) / g.stride)));
    return Math.max(0, (curView() + v) * g.n + c);
  }
  function colOf(el) {
    const r = (el.getClientRects()[0]) || el.getBoundingClientRect();
    return colOfX(r.left);
  }
  const viewOfCol = (col) => doubleNow ? Math.floor(col / 2) : col;
  const viewOfX = (left) => viewOfCol(colOfX(left));
  function curView() { return Math.round(content.scrollLeft / geom().vw); }
  function firstCol() { return doubleNow ? curView() * 2 : curView(); }
  function lastView() {
    const end = content.querySelector(':scope > .mb-end');
    return end ? viewOfCol(colOf(end)) : 0;
  }

  /* 翻頁的 0.2 秒水平滑動。連按時從上一次的目標接著算，不會少翻 */
  let anim = null, targetView = 0;
  function goView(v, animate) {
    v = Math.max(0, Math.min(v, lastView()));
    targetView = v;
    const x = v * geom().vw;
    if (anim) { cancelAnimationFrame(anim); anim = null; }
    hideFullpage();
    const from = content.scrollLeft;
    if (!animate || Math.abs(x - from) < 2 || Math.abs(x - from) > geom().vw * 1.5) {
      content.scrollLeft = x;
      updateIndicators();
      return;
    }
    const t0 = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - t0) / 200);
      content.scrollLeft = from + (x - from) * (1 - Math.pow(1 - k, 3));
      if (k < 1) anim = requestAnimationFrame(step);
      else { anim = null; updateIndicators(); }
    };
    anim = requestAnimationFrame(step);
  }

  function turnPage(step) {
    if (!BK.paged) return;
    goView((anim ? targetView : curView()) + step, true);
  }

  /* 目前這一頁在哪一章（spine 檔）、那一章從第幾欄到第幾欄 */
  function chapterSpan() {
    const secs = [...content.querySelectorAll(':scope > section.mb-chapter')];
    const starts = secs.map(colOf);
    const first = firstCol();
    let idx = 0;
    starts.forEach((c, i) => { if (c <= first) idx = i; });
    const end = content.querySelector(':scope > .mb-end');
    const lastCol = end ? colOf(end) : first;
    const stop = idx + 1 < starts.length ? starts[idx + 1] - 1 : lastCol;
    return { secs, idx, start: starts[idx] || 0, end: Math.max(starts[idx] || 0, stop) };
  }

  function gotoChapterEdge(dir) {
    const s = chapterSpan();
    goView(viewOfCol(dir < 0 ? s.start : s.end), true);
  }

  /* 全書百分比：以文字位置算，不用頁數（頁數會隨字級、欄寬、單雙頁改變） */
  function percent() {
    if (curView() >= lastView()) return 100;
    const secs = [...content.querySelectorAll(':scope > section.mb-chapter')];
    const total = secs.reduce((n, s) => n + s.textContent.length, 0) || 1;
    const range = readingPoint();
    const sec = range ? sectionOf(range.startContainer) : secs[chapterSpan().idx];
    let before = 0;
    for (const s of secs) { if (s === sec) break; before += s.textContent.length; }
    const inside = range && sec ? offsetIn(sec, range.startContainer, range.startOffset) : 0;
    return Math.min(99, Math.floor((before + inside) / total * 100));
  }

  function updateIndicators() {
    if (!BK.paged) { hideFullpage(); return; }
    fixPushedOnView();
    if (!anim) showFullpage();
    const s = chapterSpan();
    const total = s.end - s.start + 1;
    const at = Math.min(total, Math.max(1, firstCol() - s.start + 1));
    pageLeft.textContent = `本章 ${at}／${total} 頁`;
    pageRight.textContent = `${percent()}%`;
  }

  BK.reveal = (el) => { if (el) goView(viewOfCol(colOf(el)), false); };
  BK.elementView = (el) => viewOfCol(colOf(el));
  BK.currentView = () => curView();

  MB.setBookLayout = function (mode) {
    const anchor = BK.active && !BK.fixed ? captureBookAnchor() : null;
    BK.layout = mode;
    if (!BK.active) return;
    if (BK.fixed) { layoutFixed(); reportPosition(false); return; }
    applyLayout();
    requestAnimationFrame(() => {
      if (anchor) restoreBookAnchor(anchor);
      updateIndicators();
      reportPosition(false);
    });
  };

  /* 字級、字體一變，分頁跟著重排：記住讀到哪裡，排完翻回那一頁 */
  ['setFontSize', 'setFontFamily'].forEach((name) => {
    const original = MB[name];
    MB[name] = function (...args) {
      const anchor = BK.paged ? captureBookAnchor() : null;
      original.apply(this, args);
      if (anchor) requestAnimationFrame(() => { applyLayout(); restoreBookAnchor(anchor); });
    };
  });

  /* 視窗或分隔線改變欄寬：先重新判斷單雙頁，app.js 會在下一個 frame 回到原本的位置 */
  window.addEventListener('resize', () => { if (BK.active && !BK.fixed) applyLayout(); });

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
      I().reveal(target, true);
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
    if (t) I().reveal(t, true);
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

  /* 選了雙頁、書允許跨頁、欄寬也夠（單頁不小於約 400pt）才跨頁；「捲動」當作單頁 */
  function useSpread() {
    return BK.layout === 'double' && fx.spread && content.clientWidth / 2 >= 400;
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

  /* 翻頁鍵（docs/SPEC.md 13.5、13.9、13.12）
   * ← 上一頁、→ 下一頁。右翻左的固定版面書反過來：按鍵跟著畫面走，← 前往左邊那頁。
   * 翻頁模式另外認空白鍵、PageUp／PageDown、↑／↓，Home／End 跳本章頭尾。
   * 捲動模式的「一頁」是一個畫面高、留兩行重疊。 */
  document.addEventListener('keydown', (e) => {
    if (!BK.active || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
    const k = e.key;
    let step = k === 'ArrowRight' ? 1 : k === 'ArrowLeft' ? -1 : 0;

    if (BK.fixed) {
      if (step) step = fx.rtl ? -step : step;
      else if (k === ' ') step = e.shiftKey ? -1 : 1;
      else if (k === 'PageDown') step = 1;
      else if (k === 'PageUp') step = -1;
      if (!step) return;
      e.preventDefault();
      turn(step);
      return;
    }

    if (BK.paged) {
      let edge = 0;
      if (!step) {
        if (k === ' ') step = e.shiftKey ? -1 : 1;
        else if (k === 'PageDown' || k === 'ArrowDown') step = 1;
        else if (k === 'PageUp' || k === 'ArrowUp') step = -1;
        else if (k === 'Home') edge = -1;
        else if (k === 'End') edge = 1;
      }
      if (!step && !edge) return;
      e.preventDefault();
      closePopover();
      if (edge) gotoChapterEdge(edge); else turnPage(step);
      return;
    }

    if (!step || e.shiftKey) return;
    e.preventDefault();
    closePopover();
    const lineGap = parseFloat(getComputedStyle(document.body).lineHeight) || 32;
    window.scrollBy({ top: step * Math.max(100, window.innerHeight - lineGap * 2), behavior: 'auto' });
  });

  /* 觸控板左右滑：累積到一個門檻才翻一頁，翻完冷卻一下，免得一次滑過好幾頁 */
  let wheelAcc = 0, wheelLock = 0;
  window.addEventListener('wheel', (e) => {
    if (!BK.fixed && !BK.paged) return;
    e.preventDefault();
    const now = Date.now();
    if (now < wheelLock) return;
    const dx = e.deltaX, dy = e.deltaY;
    wheelAcc += Math.abs(dx) > Math.abs(dy) ? dx * (BK.fixed && fx.rtl ? -1 : 1) : dy;
    if (Math.abs(wheelAcc) > 80) {
      closePopover();
      if (BK.fixed) turn(wheelAcc > 0 ? 1 : -1); else turnPage(wheelAcc > 0 ? 1 : -1);
      wheelAcc = 0;
      wheelLock = now + 450;
    }
  }, { passive: false });

  window.addEventListener('resize', () => { if (BK.fixed) layoutFixed(); });
})();
