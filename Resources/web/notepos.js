/* notepos.js —— 心得閱讀位置裡不碰 DOM 的決策（docs/SPEC.md 5.6）。
 * 單獨一個檔，make test 才能用 node 直接測，不必模擬整個網頁。 */
'use strict';

(function () {
  /* 由書帶動換心得時，要不要留在開檔還原到的位置。 */
  function keepRestored({ restored, scopeAsked, scopeFound, inside }) {
    if (!restored) return false;           // 沒讀過：照舊到章標題（一章一檔就是開頭）
    if (!scopeAsked) return true;          // 整份心得就是那一章
    // 書要的章名在心得裡找不到（翻譯版本不同，SPEC 13.6）：不能當成整份是那一章而留在舊位置
    return scopeFound && inside;
  }

  const api = { keepRestored };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else window.MBNotePos = api;
})();
