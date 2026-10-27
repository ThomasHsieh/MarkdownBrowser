# Issue tracker：GitHub

這個 repo 的 issue 與 PRD 都放在 GitHub Issues，一律用 `gh` CLI 操作。

## 慣例

- **建 issue**：`gh issue create --title "..." --body "..."`，多行內文用 heredoc
- **讀 issue**：`gh issue view <number> --comments`，用 `jq` 篩留言，標籤也一起拿
- **列 issue**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，
  視需要加 `--label`、`--state` 篩選
- **留言**：`gh issue comment <number> --body "..."`
- **加／拿掉標籤**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **關閉**：`gh issue close <number> --comment "..."`

repo 由 `git remote -v` 推得，在 clone 裡跑 `gh` 會自動帶上。

## PR 是否列入 triage

**把外部 PR 當成需求來源：否。**（這個 repo 要把外部 PR 當功能需求時改成「是」，`/triage` 會讀這個設定。）

設成「是」時，PR 跟 issue 走同一套標籤與狀態，改用對應的 `gh pr` 指令：

- **讀 PR**：`gh pr view <number> --comments`，diff 用 `gh pr diff <number>`
- **列出要 triage 的外部 PR**：`gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`，
  只留 `authorAssociation` 是 `CONTRIBUTOR`、`FIRST_TIME_CONTRIBUTOR`、`NONE` 的（拿掉 `OWNER`／`MEMBER`／`COLLABORATOR`）
- **留言／標籤／關閉**：`gh pr comment`、`gh pr edit --add-label`／`--remove-label`、`gh pr close`

GitHub 的 issue 與 PR 共用同一組編號，單寫 `#42` 可能是任一種：先試 `gh pr view 42`，不是再用 `gh issue view 42`。

## skill 說「發到 issue tracker」時

建一個 GitHub issue。

## skill 說「拿相關的 ticket」時

跑 `gh issue view <number> --comments`。

## Wayfinding 的操作

給 `/wayfinder` 用。**地圖**是一個 issue，底下的**子 issue** 是一張張 ticket。

- **地圖**：一個標了 `wayfinder:map` 的 issue，內文分 Notes／Decisions-so-far／Fog 三段。`gh issue create --label wayfinder:map`
- **子 ticket**：用 GitHub sub-issue 掛在地圖底下（`gh api` 打 sub-issues endpoint）。沒開 sub-issue 時，
  加進地圖內文的 task list，並在子 issue 內文開頭寫 `Part of #<map>`。標籤是 `wayfinder:<type>`
  （`research`／`prototype`／`grilling`／`task`）。被認領後指派給正在推進的人
- **阻擋關係**：用 GitHub **原生的 issue dependencies**，這是 UI 上看得到的正式寫法。加一條邊用
  `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`，
  `<blocker-db-id>` 是擋住它的那個 issue 的數字 **database id**（`gh api repos/<owner>/<repo>/issues/<n> --jq .id`，
  不是 `#number` 也不是 `node_id`）。GitHub 回報的 `issue_dependencies_summary.blocked_by` 只算還開著的阻擋者，
  也就是當下真正擋住的。沒有 dependencies 可用時，退回在子 issue 內文開頭寫 `Blocked by: #<n>, #<n>`。
  所有阻擋者都關閉時，這張 ticket 就解除阻擋
- **找下一張（frontier）**：列出地圖底下還開著的子 issue（`gh issue list --state open`，範圍限在地圖的 sub-issue／task list），
  拿掉還有開著的阻擋者（`issue_dependencies_summary.blocked_by > 0`，或 `Blocked by` 那行有還開著的 issue）或已經有人認領的，
  照地圖上的順序取第一張
- **認領**：`gh issue edit <n> --add-assignee @me`，這是 session 的第一個寫入動作
- **解決**：`gh issue comment <n> --body "<答案>"`，接著 `gh issue close <n>`，再把重點加連結補進地圖的 Decisions-so-far
