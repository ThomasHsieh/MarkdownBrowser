/* imgzoom.js —— 點圖放大（心得與流動版面的書共用）。
 * 浮層只蓋這一欄（每欄是各自的 WKWebView），不經 Swift。
 * 不碰 DOM 的決策（zoomSize）單獨匯出，make test 才能用 node 直接測。 */
'use strict';

(function () {
  const MAX_UPSCALE = 4;   // 第一段：原圖像素最多放大幾倍，再大只是更糊
  const WIDE_UPSCALE = 2;  // 第二段：單欄全寬時不設限的話，字大到一行只剩幾個字
  const MIN_GAIN = 1.25;   // 比前一個大小大不到這個倍數就不算：點了看起來像沒反應

  /* 兩段放大的大小（docs/SPEC.md 5.7）。
   * fit：等比放進欄的可視範圍，看全貌。直式長圖在翻頁模式本來就排到接近欄高，這段常常幾乎沒變大
   * wide：寬度填滿欄、上下捲動看，才是讓圖裡的字變大的那段；不比 fit 寬就沒有這段
   * 兩段都不比現在顯示的大時回傳 null（游標不變、點了不開）。 */
  function zoomSize({ natW, natH, shownW, boxW, boxH }) {
    if (!natW || !natH) return null;       // 還沒載完：naturalWidth 是 0
    const kFit = Math.min(boxW / natW, boxH / natH, MAX_UPSCALE);
    const kWide = Math.min(boxW / natW, WIDE_UPSCALE);
    const size = (k) => ({ w: Math.round(natW * k), h: Math.round(natH * k) });
    const wide = natW * kWide >= natW * kFit * MIN_GAIN ? size(kWide) : null;
    if (natW * Math.max(kFit, kWide) < shownW * MIN_GAIN) return null;
    return { fit: size(kFit), wide };
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { zoomSize };
    return;
  }

  /* ── 網頁端 ─────────────────────────────────────────── */

  const MARGIN = 16;       // 放大的圖跟欄緣留一點距離，不貼邊
  const content = document.getElementById('content');
  const overlay = document.createElement('div');
  overlay.id = 'mb-zoom';
  const big = document.createElement('img');
  big.alt = '';
  overlay.appendChild(big);
  document.body.appendChild(overlay);
  /* 關掉之後游標要自己回來（見 close）：一個看不見、蓋滿這一欄的捲動框 */
  const nudge = document.createElement('div');
  nudge.id = 'mb-zoom-nudge';
  nudge.appendChild(document.createElement('div'));
  document.body.appendChild(nudge);
  let current = null;      // 放大中的那張圖（內文裡的原件）

  const isOpen = () => current !== null;

  /* 哪些圖能點：心得與流動版面的書。固定版面與 PDF 不做（canvas、整頁圖，放大等於縮放視窗）；
   * 連結裡的圖交給連結；書的章首圖點了是同步心得（app.js 的 chapterImageHeading） */
  function candidate(target) {
    // 看標籤名、不用 instanceof：書的節點在 book.js 的 iframe 裡建好才搬過來，
    // JS 物件屬於 iframe 那個環境，instanceof 這一頁的 HTMLImageElement 永遠是 false
    if (!target || target.localName !== 'img' || !content.contains(target)) return false;
    const book = window.MBBook;
    if (book && book.active && (book.fixed || book.pdf)) return false;
    return !target.closest('a, section.mb-chapter-link');
  }

  function sizeFor(img) {
    const r = img.getBoundingClientRect();
    return zoomSize({
      natW: img.naturalWidth, natH: img.naturalHeight,
      shownW: r.width, shownH: r.height,
      boxW: window.innerWidth - 2 * MARGIN, boxH: window.innerHeight - 2 * MARGIN,
    });
  }

  let wideMode = false;     // 在第二段（寬度填滿、上下捲動）

  /* 照目前的欄寬重算並套用這一段的大小。回傳這次的兩段大小，算不出來（圖被換掉）就收起來 */
  function layout() {
    const s = sizeFor(current);
    if (!s) { close(); return null; }
    if (!s.wide) wideMode = false;          // 欄變窄後沒有第二段了：退回第一段
    const z = wideMode ? s.wide : s.fit;
    big.style.width = z.w + 'px';
    big.style.height = z.h + 'px';
    overlay.classList.toggle('mb-wide', wideMode);
    // 還能進第二段就是放大鏡，否則下一次點擊是關閉
    overlay.classList.toggle('mb-more', !wideMode && !!s.wide);
    return s;
  }

  function open(img) {
    current = img;
    wideMode = false;
    big.src = img.currentSrc || img.src;
    if (layout()) overlay.classList.add('show');
  }

  function close() {
    current = null;
    wideMode = false;
    overlay.classList.remove('show', 'mb-wide', 'mb-more');
    big.removeAttribute('src');
    // WebKit 只在滑鼠移動時重算游標，遮罩消失後會停在放大鏡、要動一下滑鼠才恢復。
    // 例外是捲動框捲動之後：滑鼠在那個框裡的話，它會補送一個假的滑鼠移動（WebKit 的
    // dispatchFakeMouseMoveEventSoonInQuad），游標就照底下的內文重算。框要蓋到滑鼠所在處，
    // 所以蓋滿整欄；不接滑鼠、看不見。試過不行的：改用 visibility 藏遮罩、cursor 樣式改變、
    // 角落的小捲動框、改在 mousedown 關（實測都要動滑鼠才恢復）
    nudge.scrollTop = nudge.scrollTop ? 0 : 5;
  }

  /* 第一段 → 第二段：捲到點的那一處，點了圖的哪裡就放大哪裡，不必從頂端往下找 */
  function toWide(clickY) {
    const before = big.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (clickY - before.top) / before.height));
    wideMode = true;
    if (!layout()) return;
    const h = big.getBoundingClientRect().height;
    overlay.scrollTop = MARGIN + ratio * h - clickY;
  }

  /* 游標：值得放大的圖才變放大鏡。欄寬隨時會變，移上去當下才算 */
  content.addEventListener('mouseover', (e) => {
    const img = e.target;
    if (!candidate(img)) return;
    img.classList.toggle('mb-zoomable', !!sizeFor(img));
  });

  /* 掛在 document 的捕獲階段，比 app.js、highlights.js 掛在 #content 的點擊先到：
   * 圖若在標題或心得的引文裡，放大了就不該同時帶動另一欄 */
  document.addEventListener('click', (e) => {
    const img = e.target;
    if (!candidate(img) || !window.getSelection().isCollapsed) return;
    if (!sizeFor(img)) return;
    e.preventDefault();
    e.stopPropagation();
    open(img);
  }, true);

  /* 兩段式（docs/SPEC.md 5.7）：第一次點放進欄、第二次寬度填滿、第三次關。沒有第二段就第二次關 */
  overlay.addEventListener('click', (e) => {
    if (!wideMode && overlay.classList.contains('mb-more')) toWide(e.clientY);
    else close();
  });
  // 底下的頁面不跟著捲或翻：看不到的變化只會讓人關掉後迷路。
  // 只 preventDefault 不夠：book.js 翻頁模式的滾輪、app.js 的滑鼠滾輪都掛在 window 上。
  // 第二段要讓遮罩自己捲，只擋往下傳
  overlay.addEventListener('wheel', (e) => {
    if (!wideMode) e.preventDefault();
    e.stopPropagation();
  }, { passive: false });

  /* 開著時：Esc 關；翻頁與捲動鍵也只關、不動底下的頁面。
   * 掛在 window 的捕獲階段，比 app.js、book.js 掛在 document 的按鍵處理先到 */
  const CLOSE_KEYS = new Set([
    'Escape', ' ', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
    'PageUp', 'PageDown', 'Home', 'End',
  ]);
  window.addEventListener('keydown', (e) => {
    if (!isOpen() || !CLOSE_KEYS.has(e.key)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    close();
  }, true);

  window.addEventListener('resize', () => { if (isOpen()) layout(); });

  window.MBImgZoom = {
    zoomSize,
    close,
    /* 另一欄轉過來的翻頁、捲動鍵（MB.pageKey、MB.scrollKey）：開著就只關，回傳 true 表示吃掉了 */
    closeIfOpen() {
      if (!isOpen()) return false;
      close();
      return true;
    },
  };
})();
