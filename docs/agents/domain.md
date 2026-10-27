# Domain docs

engineering 那幾個 skill 探索程式碼時，怎麼讀這個 repo 的領域文件。

## 動手探索之前先讀

- 根目錄的 **`CONTEXT.md`**，或
- 根目錄有 **`CONTEXT-MAP.md`** 時讀它：它指向每個 context 各自的 `CONTEXT.md`，讀跟主題有關的那幾份
- **`docs/adr/`**：讀碰到這次要改的範圍的 ADR。多 context 的 repo 還要看 `src/<context>/docs/adr/` 裡只屬於該 context 的決定

這些檔不存在就**直接往下做**，不要提它們缺了，也不要建議先建起來。`/domain-modeling`
（經由 `/grill-with-docs` 與 `/improve-codebase-architecture` 觸發）會在真的定下用語或決定時才建。

## 檔案結構

單一 context（大多數 repo，包括這個）：

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

多 context（根目錄有 `CONTEXT-MAP.md`）：

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← 整個系統的決定
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← 只屬於這個 context 的決定
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## 用詞彙表裡的說法

產出裡提到領域概念時（issue 標題、重構提案、假設、測試名稱），用 `CONTEXT.md` 定義的詞。
不要換成詞彙表明確說不用的同義詞。

需要的概念還不在詞彙表裡，就是個訊號：不是在發明專案沒在用的說法（重新想想），就是真的有缺口
（記下來給 `/domain-modeling`）。

## 標出跟 ADR 衝突的地方

產出跟既有的 ADR 矛盾時，明白說出來，不要默默蓋過去：

> _跟 ADR-0007（event-sourced orders）衝突，但值得重新討論，因為……_
