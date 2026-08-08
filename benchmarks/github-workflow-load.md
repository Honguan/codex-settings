# GitHub workflow load baseline

Issue #32 的比較以 `main` 上的 workflow 與本分支的 workflow contract 為基準；API 數量是正常成功路徑的靜態計數，runner 與 checkout 是 workflow 設定計數。Receipt 本身是必要的新寫入，不以省略它換取較低數字。

| Path | Before | After | Change |
| --- | --- | --- | --- |
| PR metadata API | Issue GET + commits GET（2） | Issue GET（1） | -1 API；title contract 取代 commit list |
| PR stale runs | 每次事件都可能保留 | 同 PR concurrency，取消舊 run | superseded run 減少 |
| PR policy runner | `windows-latest` | `ubuntu-latest` | API-only runner |
| Main provenance API | merged PR lookup（1） | lookup + receipt POST（2） | +1 必要 receipt |
| Issue close guard API | closed PR list + compare + run list（3） | receipt comments + compare（2） | -1 API；不再 polling workflow |
| Close race | close → reopen → close 可能重跑 | pending receipt defer，不 reopen | 移除正常競態重跑 |
| Close guard runner | `windows-latest` | `ubuntu-latest` | API-only runner |
| Release checkout | `fetch-depth: 0` | `fetch-depth: 1` | 不下載完整歷史 |
| Release tag check | local `git merge-base` | GitHub compare API（1） | 保留 main reachability |
| Performance/workflow tests | Release 全部 blocking | 明確 deferred；changed-area workflow 執行 workflow contract | 減少 release blocking 負載 |

## Observed baseline

以合併 #26、#27、#28、#30、#31 後可見的最近 30 次 run 為基線：`Pull request validation` 6 次、`Main validation` 12 次、`Issue close guard` 12 次；其中 close guard 有 6 次先失敗再成功。run wall-time（含排隊）P50 約為 PR 17 秒、main 11 秒、close guard 13 秒。這是目前 close/reopen race 的可重現證據。

Issue #32 的正常成功路徑預期每個 Issue 為 1 次 PR policy、1 次 main receipt、1 次 close guard；只有 workflow 相關變更才額外啟動 1 次 changed-area regression。合併後以 Actions run history 補記實際 P50/P95，不以本地執行時間代替 GitHub runner 數據。

目前無法從 GitHub Actions API 取得每一個 runner 的實際 API call 數與 checkout bytes；PR、main 與 close guard 會輸出 API 路徑計數，合併後可用 run duration 與 workflow run list 補上實測 wall time。這份表保留設計前後的可核對基線，不把推估值冒充 runtime 實測。
