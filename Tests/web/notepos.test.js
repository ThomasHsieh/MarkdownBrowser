/* 由書帶動換心得時，要不要留在還原到的位置（docs/SPEC.md 5.6）：
 * 記住的位置在這一章裡就留著，不在就到這一章的標題。
 * 「在不在章內」要量 DOM，由 app.js 算好傳進來；這裡只驗決策。 */
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { keepRestored } = require('../../Resources/web/notepos.js');

test('書要求跳到章標題、心得裡卻找不到那個標題：不留，交給退路', () => {
  // 翻譯版本不同時章名常對不上（SPEC 13.6）。不能當成「整份就是那一章」
  assert.equal(keepRestored({ restored: true, scopeAsked: true, scopeFound: false, inside: false }), false);
});

test('整份心得就是那一章（書沒要求章標題）：留在還原到的位置', () => {
  assert.equal(keepRestored({ restored: true, scopeAsked: false, scopeFound: false, inside: false }), true);
});

test('這份心得沒有記住的位置：不留，交給到章標題的退路', () => {
  assert.equal(keepRestored({ restored: false, scopeAsked: false, scopeFound: false, inside: false }), false);
});

test('單檔心得、還原到的位置就在書選的那一章裡：留著', () => {
  assert.equal(keepRestored({ restored: true, scopeAsked: true, scopeFound: true, inside: true }), true);
});

test('單檔心得、還原到的位置在別章（上次停在第 3 章、書選了第 5 章）：不留，到第 5 章的標題', () => {
  assert.equal(keepRestored({ restored: true, scopeAsked: true, scopeFound: true, inside: false }), false);
});
