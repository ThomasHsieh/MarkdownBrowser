/* 點圖放大的兩段大小與「值不值得放大」（docs/SPEC.md 5.7）。
 * 量 DOM 的部分由 imgzoom.js 的浮層做好傳進來；這裡只驗決策。預期值都是手算的。 */
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { zoomSize } = require('../../Resources/web/imgzoom.js');

test('直式長圖：第一段受欄高限制、碰到上下邊；第二段寬度填滿欄', () => {
  // 原圖 600×1200，現在排成 300×600；欄 1000×800 → 第一段 400×800；第二段寬 1000（原圖 1.67 倍，沒到 2 倍上限）
  assert.deepEqual(
    zoomSize({ natW: 600, natH: 1200, shownW: 300, shownH: 600, boxW: 1000, boxH: 800 }),
    { fit: { w: 400, h: 800 }, wide: { w: 1000, h: 2000 } },
  );
});

test('小圖示：第一段放到原圖 4 倍就停；第二段上限原圖 2 倍反而更小，沒有第二段', () => {
  // 原圖 30×30、排成 1em（16×16）；欄 1000×800 → 放進欄是 800，但原圖 4 倍只有 120；2 倍是 60
  assert.deepEqual(
    zoomSize({ natW: 30, natH: 30, shownW: 16, shownH: 16, boxW: 1000, boxH: 800 }),
    { fit: { w: 120, h: 120 }, wide: null },
  );
});

test('已經跟欄差不多寬的圖：放大不到 1.25 倍，不值得開', () => {
  // 原圖 2000×1000、排成 950×475；欄 1000×800 → 放進欄是 1000×500，只大 1.05 倍
  assert.equal(
    zoomSize({ natW: 2000, natH: 1000, shownW: 950, shownH: 475, boxW: 1000, boxH: 800 }),
    null,
  );
});

test('原圖比欄大的橫式圖：第一段就碰到左右邊、不超出，沒有第二段', () => {
  // 原圖 2000×1000、排成 400×200（書指定 40%）；欄 1000×800 → 1000×500，寬度已經填滿
  assert.deepEqual(
    zoomSize({ natW: 2000, natH: 1000, shownW: 400, shownH: 200, boxW: 1000, boxH: 800 }),
    { fit: { w: 1000, h: 500 }, wide: null },
  );
});

test('剛好大 1.25 倍：算值得放大（門檻含等於）', () => {
  // 原圖 1000×500、排成 400×200；欄 500×800 → 500×250，正好 1.25 倍
  assert.deepEqual(
    zoomSize({ natW: 1000, natH: 500, shownW: 400, shownH: 200, boxW: 500, boxH: 800 }),
    { fit: { w: 500, h: 250 }, wide: null },
  );
});

test('圖還沒載完（原圖像素是 0）：不開', () => {
  // naturalWidth 在載完之前是 0；照算會除以 0 得到 Infinity
  assert.equal(
    zoomSize({ natW: 0, natH: 0, shownW: 0, shownH: 0, boxW: 1000, boxH: 800 }),
    null,
  );
});

test('翻頁模式的直式長圖（實測《書》的專欄圖）：放進欄只大 1.23 倍，但第二段寬度填滿，可以點', () => {
  // 原圖 600×1204、排成 356×714；欄 1710×910 扣四邊 16 → 1678×878
  // 第一段受欄高限制：438×878（1.23 倍，單看這段不夠）；第二段寬度填滿、上限原圖 2 倍：1200×2408
  assert.deepEqual(
    zoomSize({ natW: 600, natH: 1204, shownW: 356, shownH: 714, boxW: 1678, boxH: 878 }),
    { fit: { w: 438, h: 878 }, wide: { w: 1200, h: 2408 } },
  );
});
