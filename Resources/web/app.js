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

MB.render = function (markdown, opts) {
  opts = opts || {};
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

MB.setTheme = function (name) {
  document.documentElement.setAttribute('data-theme', name);
};

MB.setAppearance = function (mode) {
  document.documentElement.setAttribute('data-appearance', mode);
};

MB.setFontFamily = function (name) {
  document.documentElement.setAttribute('data-font', name);
};

MB.setFontSize = function (px) {
  document.documentElement.style.setProperty('--font-size', px + 'px');
};

MB.setUserTheme = function (css) {
  document.getElementById('user-theme').textContent = css || '';
};

MB.setUserFonts = function (css) {
  document.getElementById('user-fonts').textContent = css || '';
};

MB.scrollToHeading = function (id) {
  const el = document.getElementById(id);
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
};

MB.print = function () {
  window.print();
};

/* ── 大綱高亮 ───────────────────────────────────────── */

let scrollTimer = null;
window.addEventListener('scroll', () => {
  if (scrollTimer) return;
  scrollTimer = setTimeout(() => {
    scrollTimer = null;
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
  if (jump) hit.scrollIntoView({ block: 'center', behavior: 'smooth' });
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

/* 標記重畫時要先清掉搜尋命中、畫完再補回來（見 highlights.js 的 paint）。 */
MB.internal = {
  clearHits,
  rerunFind() { if (findState.query) runFind(findState.query, false); },
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

toSwift({ type: 'ready' });
