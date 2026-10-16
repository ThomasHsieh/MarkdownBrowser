/* app.js —— WKWebView 這一側的全部邏輯。
 *
 * Swift → JS：evaluateJavaScript("MB.xxx(...)")
 * JS → Swift：webkit.messageHandlers.mb.postMessage({type, ...})
 */

'use strict';


const md = window.markdownit({
  html: false,        // 心得檔沒有原生 HTML，關掉比較安全
  linkify: true,
  typographer: false,
  breaks: true,      // 手寫筆記裡一行就是一行，不照 CommonMark 併成同段
});

const content = document.getElementById('content');

function toSwift(payload) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mb) {
    window.webkit.messageHandlers.mb.postMessage(payload);
  }
}

/* ── 標題 id ────────────────────────────────────────────
 * 用標題文字做 slug（重複的加序號），而不是用出現順序編號。
 * AI 在你上方插入一段時，順序編號會整排位移，捲軸就回錯地方。
 */
function slugify(text) {
  return text
    .trim()
    .toLowerCase()
    .replace(/[\s　]+/g, '-')
    .replace(/[^\w一-鿿぀-ヿ-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '') || 'h';
}

function assignHeadingIds() {
  const seen = new Map();
  const outline = [];
  content.querySelectorAll('h1, h2, h3, h4').forEach((el) => {
    const base = slugify(el.textContent);
    const n = (seen.get(base) || 0) + 1;
    seen.set(base, n);
    el.id = n === 1 ? base : `${base}-${n}`;
    outline.push({
      id: el.id,
      level: parseInt(el.tagName.substring(1), 10),
      text: el.textContent.trim(),
    });
  });
  return outline;
}

/* ── 捲動錨點 ────────────────────────────────────────────
 * 記下「視窗頂端往下第一個標題」的 id 與偏移量。重載後找同 id 捲回去，
 * 比記像素位置穩 —— 上方被插入內容時像素位置整個位移。
 */
function captureAnchor() {
  const headings = content.querySelectorAll('h1, h2, h3, h4');
  let best = null;
  for (const el of headings) {
    const top = el.getBoundingClientRect().top;
    if (top <= 120) best = el;      // 最後一個還在視窗頂端以上的
    else if (!best) { best = el; break; }
    else break;
  }
  if (!best) return { y: window.scrollY };
  return { id: best.id, delta: best.getBoundingClientRect().top };
}

function restoreAnchor(anchor) {
  if (!anchor) return;
  if (anchor.id) {
    const el = document.getElementById(anchor.id);
    if (el) {
      const target = window.scrollY + el.getBoundingClientRect().top - anchor.delta;
      window.scrollTo(0, Math.max(0, target));
      return;
    }
  }
  if (typeof anchor.y === 'number') window.scrollTo(0, anchor.y);
}

/* ── 渲染 ───────────────────────────────────────────── */

const MB = {};
window.MB = MB;

let renderedAt = 0;

MB.render = function (markdown, opts) {
  opts = opts || {};
  renderedAt = Date.now();
  if (window.MBBook) window.MBBook.deactivate();
  const anchor = opts.keepScroll ? captureAnchor() : null;
  const hl = window.MBHighlights;
  const kept = hl ? hl.beforeRender() : null;   // 換內容前先把標記位置寫回錨點欄位

  content.innerHTML = md.render(markdown);
  const outline = assignHeadingIds();

  // 相對路徑的圖片指向「文件所在資料夾」，不是 App 自己的資源目錄。
  content.querySelectorAll('img[src]').forEach((img) => {
    const raw = img.getAttribute('src');
    if (!raw || /^([a-z]+:|\/\/|#)/i.test(raw)) return;
    img.setAttribute('src', 'mbres://doc/' + raw.split('/').map(encodeURIComponent).join('/'));
  });

  // 外部連結一律丟給系統瀏覽器，不在 App 內導航。
  content.querySelectorAll('a[href]').forEach((a) => {
    const href = a.getAttribute('href');
    if (/^(https?|mailto):/i.test(href)) {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        toSwift({ type: 'openExternal', url: a.href });
      });
    }
  });

  // 標記要在捲軸回位之前畫好：註記的小圓點會些微改變行寬
  if (hl) hl.afterRender(opts.highlights, kept);
  else if (findState.query) runFind(findState.query, false);

  if (anchor) restoreAnchor(anchor);
  else window.scrollTo(0, 0);

  toSwift({ type: 'outline', outline: outline });
};

MB.setAppearance = function (mode) {
  document.documentElement.setAttribute('data-appearance', mode);
};

/* 點了會帶動另一欄（對照中）：標題與心得的引文游標變手指，讓人知道可以點 */
MB.setLinked = function (on) {
  document.documentElement.toggleAttribute('data-linked', !!on);
};

/* 對照並排時，焦點欄框起來 */
MB.setFocusFrame = function (on) {
  document.documentElement.toggleAttribute('data-focus-frame', !!on);
};

MB.setFontFamily = function (name) {
  document.documentElement.setAttribute('data-font', name);
};

MB.setFontSize = function (px) {
  document.documentElement.style.setProperty('--font-size', px + 'px');
};

/* 把元素帶進畫面。書的翻頁模式是「翻到它所在的那一頁」，不能用 scrollIntoView ——
 * 那會停在兩頁中間。所有跳轉（同步、大綱、搜尋、標記、注腳連結）都走這裡。 */
function reveal(el, smooth, block) {
  if (!el) return;
  const book = window.MBBook;
  if (book && book.paged) { book.reveal(el); return; }
  el.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block: block || 'start' });
}

MB.scrollToHeading = function (id) {
  const el = document.getElementById(id);
  if (el) { reveal(el, true); settleOn(el); }
};

/* ── 對照同步（docs/SPEC.md 13.6）──────────────────────────
 * 點一邊的標題，Swift 轉給另一邊的 MB.syncTo。這裡是心得那欄的版本：
 * scope 是單檔心得裡那一章的標題，沒有就是整份；text 是書那邊被點的標題。
 */

/* 標題比對用的正規化：去「第 X 章」、去開頭的「一、」「1.」「（二）」編號、去標點。 */
function normHeading(s) {
  let t = (s || '').toLowerCase().replace(/\s+/g, '');
  t = t.replace(/第[0-9０-９〇零一二三四五六七八九十百兩]+[章部篇節講課回卷]/g, '');
  t = t.replace(/^(chapter|part)[0-9]+/, '');
  for (let i = 0; i < 2; i++) {
    t = t.replace(/^(?:[（(【\[][0-9０-９一二三四五六七八九十百]+[）)】\]]|[0-9０-９一二三四五六七八九十百]+[、.．:：])/, '');
  }
  return t.replace(/[^\p{L}\p{N}]/gu, '');
}

/* 在候選標題裡找最像的：完全相同 > 前綴相同 > 包含；同一級比重疊的字數。
 * 太短的不算，免得「兩件大事」之類亂跳。
 * 心得標題常寫成「活出有使命的人生｜做個有用的人」：章名與小節名都在裡面，
 * 要對的是最後那段（最具體的），對不到才用整句。 */
function bestHeading(candidates, text) {
  const parts = (text || '').split(/[｜|]/).map((p) => p.trim()).filter(Boolean);
  if (parts.length > 1) {
    const hit = matchHeading(candidates, parts[parts.length - 1]);
    if (hit) return hit;
  }
  return matchHeading(candidates, text);
}

function matchHeading(candidates, text) {
  const q = normHeading(text);
  if (q.length < 2) return null;
  let best = null, bestScore = 0;
  for (const el of candidates) {
    const c = normHeading(el.textContent);
    if (!c) continue;
    const short = Math.min(c.length, q.length);
    let tier = 0;
    if (c === q) tier = 3;
    else if (short >= 4 && (c.startsWith(q) || q.startsWith(c))) tier = 2;
    else if (short >= 4 && (c.includes(q) || q.includes(c))) tier = 1;
    const score = tier ? tier * 1000 + short : 0;
    if (score > bestScore) { bestScore = score; best = el; }
  }
  return best;
}

let pendingSync = null;      // tab 模式下在背景捲好的那一欄，切過去時才閃

function flash(el) {
  if (!el) return;
  el.classList.remove('mb-sync-flash');
  void el.offsetWidth;                                  // 重設動畫
  el.classList.add('mb-sync-flash');
}

/* 捲到目標並閃一下。看不到這一欄（tab 模式的背景）就先記著，切過來時才閃。 */
/* 使用者自己動過（捲動、按鍵、點擊）就不再替他校正捲動位置 */
let lastUserInput = 0;
['wheel', 'keydown', 'mousedown', 'touchstart'].forEach((t) =>
  window.addEventListener(t, () => { lastUserInput = Date.now(); }, { passive: true, capture: true }));

/* 內文的圖片與字型都載完（或最多等 4 秒）之後。字型晚到會讓整本重新斷行 ——
 * 冷啟動時霞鶩文楷要好幾秒才解完，位移比圖片還大。 */
function afterLayout(done) {
  const pending = [...content.querySelectorAll('img')].filter((img) => !img.complete);
  let left = pending.length + 1, fired = false;
  const finish = () => { if (!fired) { fired = true; requestAnimationFrame(done); } };
  const one = () => { if (--left === 0) finish(); };
  pending.forEach((img) => {
    img.addEventListener('load', one, { once: true });
    img.addEventListener('error', one, { once: true });
  });
  document.fonts.ready.then(one, one);
  setTimeout(finish, 4000);
}

/* 捲到目標之後，版面可能還在變（圖片剛載完、字型剛換好），目標就偏掉了。
 * 晚一點檢查，版面穩了再檢查一次，偏了就再對齊。使用者自己動過就不管。 */
function settleOn(target) {
  if (!target) return;
  const started = Date.now();
  const fix = () => {
    if (lastUserInput > started || !target.isConnected) return;
    const book = window.MBBook;
    if (book && book.paged) {
      if (book.elementView(target) !== book.currentView()) book.reveal(target);
    } else {
      const top = target.getBoundingClientRect().top;
      if (Math.abs(top) > 40) target.scrollIntoView({ block: 'start' });
    }
    keptAnchor = anchorNow();
  };
  setTimeout(fix, 700);
  afterLayout(fix);
}

function landSync(target, req, matched, missText) {
  const background = !!req.background;
  if (target) reveal(target, !background);
  else window.scrollTo({ top: 0, behavior: background ? 'auto' : 'smooth' });
  settleOn(target);
  const note = !matched && !req.quiet ? missText : null;
  if (background) { pendingSync = { el: target, toast: note }; return; }
  setTimeout(() => flash(target), 250);
  if (note) MB.toast(note);
}

MB.syncTo = function (req) {
  if (window.MBBook && window.MBBook.active) return window.MBBook.syncTo(req);
  const heads = [...content.querySelectorAll('h1, h2, h3, h4')];
  let scope = null, range = heads;
  if (req.scope) {
    const key = normHeading(req.scope);
    scope = heads.find((h) => normHeading(h.textContent) === key) || bestHeading(heads, req.scope);
    if (scope) {
      const level = parseInt(scope.tagName.substring(1), 10);
      const start = heads.indexOf(scope);
      let end = heads.length;
      for (let i = start + 1; i < heads.length; i++) {
        if (parseInt(heads[i].tagName.substring(1), 10) <= level) { end = i; break; }
      }
      range = heads.slice(start, end);
    }
  }
  const hit = req.text ? bestHeading(range, req.text) : null;
  landSync(hit || scope, req, !!hit || !req.text, '找不到對應小節，已跳到章首');
};

MB.revealPendingSync = function () {
  if (!pendingSync) return;
  const p = pendingSync;
  pendingSync = null;
  setTimeout(() => {
    if (p.run) { p.run(); return; }
    flash(p.el);
    if (p.toast) MB.toast(p.toast);
  }, 50);
};

const toastEl = document.createElement('div');
toastEl.id = 'mb-toast';
document.body.appendChild(toastEl);
let toastTimer = null;

MB.toast = function (text) {
  toastEl.textContent = text;
  toastEl.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove('show'), 2200);
};

/* 點內文的標題：交給 Swift 轉給另一欄。拖選文字、點標記、點連結都不算。 */
content.addEventListener('click', (e) => {
  const h = e.target.closest('h1, h2, h3, h4');
  if (!h || !content.contains(h)) return;
  if (e.target.closest('a, mark.mb-hl')) return;
  if (!window.getSelection().isCollapsed) return;
  const msg = {
    type: 'headingClicked',
    id: h.id,
    text: h.textContent.trim(),
    level: parseInt(h.tagName.substring(1), 10),
  };
  if (window.MBBook && window.MBBook.active) Object.assign(msg, window.MBBook.describeHeading(h));
  toSwift(msg);
});

/* 段落裡有好幾行（`>` 連續幾行不空行會併成一段，檔頭的「第4章：…」「作者：…」就是）時，
 * 只取點到的那一行：合起來的那段書裡不會有 */
function clickedLine(para, e) {
  // <br> 與原始檔的換行都算一行
  const textOf = (frag) => {
    const holder = document.createElement('div');
    holder.appendChild(frag);
    holder.querySelectorAll('br').forEach((br) => br.replaceWith('\n'));
    return holder.textContent;
  };
  const whole = document.createRange();
  whole.selectNodeContents(para);
  const lines = textOf(whole.cloneContents()).split('\n');
  if (lines.filter((l) => l.trim()).length < 2 || !document.caretRangeFromPoint) return null;
  const caret = document.caretRangeFromPoint(e.clientX, e.clientY);
  if (!caret || !para.contains(caret.startContainer)) return null;
  const before = document.createRange();
  before.setStart(para, 0);
  before.setEnd(caret.startContainer, caret.startOffset);
  const index = textOf(before.cloneContents()).split('\n').length - 1;
  return (lines[index] || '').trim() || null;
}

/* 點心得裡的引文：心得的引文多半是書的原句，交給 Swift 去書裡找那一段（docs/SPEC.md 13.6）。
 * 一次一段（<p>／<li>），不是整個 blockquote —— 同一塊常連引好幾句，點哪句就找哪句。
 * 書那欄自己不做：書裡的 blockquote 是書的內容，沒有對應的心得 */
content.addEventListener('click', (e) => {
  if (window.MBBook && window.MBBook.active) return;
  const q = e.target.closest('blockquote');
  if (!q || !content.contains(q)) return;
  if (e.target.closest('a, mark.mb-hl')) return;
  if (!window.getSelection().isCollapsed) return;
  const para = e.target.closest('p, li') || q;
  const text = clickedLine(para, e) || para.textContent.trim();
  if (!text) return;
  // 引文所在的小節：決定去書的哪一章找（單檔心得一份對好幾章）
  let heading = null;
  for (const h of content.querySelectorAll('h1, h2, h3, h4')) {
    if (h.compareDocumentPosition(q) & Node.DOCUMENT_POSITION_FOLLOWING) heading = h; else break;
  }
  toSwift({ type: 'quoteClicked', text, heading: heading ? heading.id : null });
});

/* 最後點過的那一欄是焦點欄：⌘F、⌘P、標記都作用在它身上。 */
document.addEventListener('mousedown', () => toSwift({ type: 'focus' }), true);

MB.print = function () {
  window.print();
};

/* ── 寬度改變時守住閱讀位置 ─────────────────────────────
 * 拖分隔線、縮放視窗、切 tab 都會改變欄寬，上方的文字重新斷行，WebKit 沒有
 * scroll anchoring，讀到的地方就整段漂走。捲動停下時記住「畫面頂端是哪裡」，
 * 寬度一變就回到那裡；縮放過程中重排引起的捲動不算數。
 */
let keptAnchor = null, lastWidth = window.innerWidth, resizing = 0;

function anchorNow() {
  const book = window.MBBook;
  return book && book.active ? book.captureAnchor() : captureAnchor();
}

function anchorRestore(anchor) {
  const book = window.MBBook;
  if (book && book.active) book.restoreAnchor(anchor); else restoreAnchor(anchor);
}

let keepTimer = null;
const keepOnScroll = () => {
  if (Date.now() < resizing) return;
  clearTimeout(keepTimer);
  keepTimer = setTimeout(() => { if (Date.now() >= resizing) keptAnchor = anchorNow(); }, 150);
};
window.addEventListener('scroll', keepOnScroll, { passive: true });
content.addEventListener('scroll', keepOnScroll, { passive: true });   // 書的翻頁模式由 #content 捲動

window.addEventListener('resize', () => {
  if (window.innerWidth === lastWidth) return;   // 只有高度變了，斷行不變
  lastWidth = window.innerWidth;
  resizing = Date.now() + 300;
  // 晚一個 frame：書的翻頁模式要先在自己的 resize 裡重新判斷單雙頁，再回位
  if (keptAnchor) { const a = keptAnchor; requestAnimationFrame(() => anchorRestore(a)); }
});

/* ── 大綱高亮 ───────────────────────────────────────── */

let scrollTimer = null;
window.addEventListener('scroll', () => {
  if (scrollTimer) return;
  scrollTimer = setTimeout(() => {
    scrollTimer = null;
    // 翻頁模式的「目前標題」看的是頁，不是畫面頂端；側欄用不到書的這個值，直接不報
    if (window.MBBook && window.MBBook.paged) return;
    const headings = content.querySelectorAll('h1, h2, h3, h4');
    let active = null;
    for (const el of headings) {
      if (el.getBoundingClientRect().top <= 120) active = el.id;
      else break;
    }
    toSwift({ type: 'activeHeading', id: active });
  }, 120);
}, { passive: true });

/* ── 搜尋 ───────────────────────────────────────────── */

const findBar = document.getElementById('find-bar');
const findInput = document.getElementById('find-input');
const findCount = document.getElementById('find-count');
const findState = { query: '', hits: [], index: -1 };

function clearHits() {
  content.querySelectorAll('mark.mb-hit').forEach((m) => {
    const parent = m.parentNode;
    parent.replaceChild(document.createTextNode(m.textContent), m);
    parent.normalize();
  });
  findState.hits = [];
  findState.index = -1;
}

function runFind(query, jump) {
  clearHits();
  findState.query = query;
  if (!query) {
    findCount.textContent = '0／0';
    return;
  }

  const needle = query.toLowerCase();
  const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      if (node.parentElement.closest('script, style')) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });

  const targets = [];
  let node;
  while ((node = walker.nextNode())) targets.push(node);

  for (const textNode of targets) {
    const haystack = textNode.nodeValue.toLowerCase();
    let from = 0;
    let at = haystack.indexOf(needle, from);
    if (at === -1) continue;

    const frag = document.createDocumentFragment();
    while (at !== -1) {
      if (at > from) frag.appendChild(document.createTextNode(textNode.nodeValue.slice(from, at)));
      const mark = document.createElement('mark');
      mark.className = 'mb-hit';
      mark.textContent = textNode.nodeValue.substr(at, query.length);
      frag.appendChild(mark);
      findState.hits.push(mark);
      from = at + query.length;
      at = haystack.indexOf(needle, from);
    }
    if (from < textNode.nodeValue.length) {
      frag.appendChild(document.createTextNode(textNode.nodeValue.slice(from)));
    }
    textNode.parentNode.replaceChild(frag, textNode);
  }

  if (findState.hits.length) {
    findState.index = 0;
    highlightCurrent(jump !== false);
  } else {
    findCount.textContent = '0／0';
  }
}

function highlightCurrent(jump) {
  findState.hits.forEach((m) => m.classList.remove('mb-current'));
  const hit = findState.hits[findState.index];
  if (!hit) return;
  hit.classList.add('mb-current');
  if (jump) reveal(hit, true, 'center');
  findCount.textContent = `${findState.index + 1}／${findState.hits.length}`;
}

function step(delta) {
  if (!findState.hits.length) return;
  findState.index = (findState.index + delta + findState.hits.length) % findState.hits.length;
  highlightCurrent(true);
}

MB.openFind = function () {
  findBar.hidden = false;
  findInput.focus();
  findInput.select();
};

MB.closeFind = function () {
  findBar.hidden = true;
  clearHits();
  findState.query = '';
  findCount.textContent = '0／0';
};

MB.findNext = function () { step(1); };

/* 標記重畫時要先清掉搜尋命中、畫完再補回來（見 highlights.js 的 paint）。
 * 後半是給 book.js 共用的。 */
MB.internal = {
  clearHits,
  rerunFind() { if (findState.query) runFind(findState.query, false); },
  slugify,
  captureAnchor,
  restoreAnchor,
  normHeading,
  bestHeading,
  landSync,
  setPendingSync(run) { pendingSync = { run }; },
  settleOn,
  afterLayout,
  reveal,
  userMoved(since) { return lastUserInput > (since || renderedAt); },
  noteUserInput() { lastUserInput = Date.now(); },
  markRendered() { renderedAt = Date.now(); },
  toSwift,
  closeFind() { if (!findBar.hidden) MB.closeFind(); },
};
MB.findPrev = function () { step(-1); };

findInput.addEventListener('input', () => runFind(findInput.value, true));
findInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
  else if (e.key === 'Escape') { e.preventDefault(); MB.closeFind(); }
});
document.getElementById('find-next').addEventListener('click', () => step(1));
document.getElementById('find-prev').addEventListener('click', () => step(-1));
document.getElementById('find-close').addEventListener('click', () => MB.closeFind());

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !findBar.hidden) { e.preventDefault(); MB.closeFind(); }
});

/* 對照、兩欄並排時，心得這欄的 ←／→／空白鍵歸書（docs/SPEC.md 13.5）。
 * 要不要轉由 Swift 決定（tab 模式不轉：翻一本看不見的書沒有回饋）；
 * 但正在打字（搜尋框、註記）只有這裡知道。⇧←／⇧→ 是延伸選取，不轉。 */
let forwardPageKeys = false;
MB.setForwardPageKeys = function (on) { forwardPageKeys = !!on; };
document.addEventListener('keydown', (e) => {
  if (!forwardPageKeys || e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
  const t = e.target;
  if (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable) return;
  const k = e.key;
  if (k !== ' ' && (e.shiftKey || (k !== 'ArrowLeft' && k !== 'ArrowRight'))) return;
  e.preventDefault();
  toSwift({ type: 'pageKey', key: k, shift: e.shiftKey });
});

/* 對照時 Tab／⇧Tab 切到另一欄（docs/SPEC.md 13.3）：並排時切焦點欄，tab 模式切顯示哪一欄。
 * 只有兩欄，方向沒有差別。只開一欄時什麼都不做：交給瀏覽器的話，連結輪過一遍後
 * 鍵盤焦點就跳出網頁，接著按 ↓ 翻不了頁，要再點一下內文才回來。正在打字時不攔 */
let paneSwitch = false;
MB.setPaneSwitch = function (on) { paneSwitch = !!on; };
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Tab' || e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
  const t = e.target;
  if (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable) return;
  e.preventDefault();
  if (paneSwitch) toSwift({ type: 'switchPane' });
});

/* 反方向：書在翻頁模式時，書那欄的 ↑／↓／PageUp／PageDown／Home／End 轉過來捲心得
 * （docs/SPEC.md 13.5）。按鍵不是在這一欄發生的，要自己記一筆使用者動過，
 * 否則晚到的版面校正會把剛捲的位置拉回去。行為比照原生捲動 */
MB.scrollKey = function (k) {
  lastUserInput = Date.now();
  const lineGap = parseFloat(getComputedStyle(document.body).lineHeight) || 32;
  const page = Math.max(100, window.innerHeight - lineGap * 2);
  switch (k) {
    case 'ArrowDown': window.scrollBy({ top: 40, behavior: 'auto' }); break;
    case 'ArrowUp': window.scrollBy({ top: -40, behavior: 'auto' }); break;
    case 'PageDown': window.scrollBy({ top: page, behavior: 'auto' }); break;
    case 'PageUp': window.scrollBy({ top: -page, behavior: 'auto' }); break;
    case 'Home': window.scrollTo({ top: 0, behavior: 'auto' }); break;
    case 'End': window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'auto' }); break;
  }
};

toSwift({ type: 'ready' });
