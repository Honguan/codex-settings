# Codex Settings

Windows 上的 Codex 全域設定一鍵安裝與管理工具。

所有設定都安裝到使用者層級，不再於 Git、CVS 或其他專案目錄建立 `AGENTS.md`、Rules、Hooks 或登記資料。

## 主要功能

- 安裝或更新全域 `AGENTS.md`、`config.toml` 與權限規則。
- 可選安裝全域 Windows 通知 Hook，提示任務完成、等待權限與等待回答；通知不查詢 Token／Cost 用量。
- 在全域安裝流程選擇 Git 或 CVS，合併對應的全域 AGENTS 與 Rules。
- 安裝 Playwright MCP 設定。
- 安裝或更新 `ccusage`，並新增或更新 `ccsessions`（Session 用量）與 `cdaily`（每日用量）指令。
- 選用 `request-execution-optimizer` 與 `mattpocock/skills`。
- 安全合併既有設定，並提供交易備份、中斷回復、備份、還原及移除。
- 安裝時顯示動態階段、百分比、耗時與永久結果列，並將詳細 timing 寫入 `~/.codex/logs/installer/`。
- 首次執行新版安裝器時，自動清除舊登記專案內由本工具管理的設定。

## 需求

- Windows 10 或更新版本。
- PowerShell 7 或更新版本。
- Codex CLI。
- Node.js 20 或更新版本，且 `node`、`npm`、`npx` 可由 PATH 執行。

## 一鍵安裝

下載 Release 中含版本號的單一檔案，例如 `CodexSettings-Setup-v1.8.6.cmd`，不需解壓縮，直接執行：

```powershell
.\CodexSettings-Setup-v1.8.6.cmd
```

安裝器會在 `%TEMP%` 解開內嵌程式、執行後立即清理；全域安裝成功或失敗後會保留結果畫面，按任意鍵才關閉。自動化可使用 `-NoPause` 或設定 `CODEX_SETTINGS_NO_PAUSE=1`。安裝或更新後必須完全關閉並重新啟動 VS Code、Codex 與 PowerShell；config.toml／MCP 與 Hook 可能由既有程序快取，在舊 App 中建立新對話仍可能沿用修復前設定。從原始碼執行時則使用根目錄的 `Install.cmd`。

主選單只有四項：

1. 全域安裝／更新
2. 備份目前設定
3. 還原備份
4. 移除受管理設定

主選單直接按 Enter 會預設選擇 `[1]`。安全合併是預設安裝方式，會保留未受管理的既有內容。完整覆蓋只應在確定要用範本取代目標設定時使用。

選擇「全域安裝／更新」後會選擇開發環境：

- Git（首次安裝預設）：加入 Git 專屬 AGENTS、Rules 與 Issue 完成工作流；修正必須從最新 `main` 建立 `issue/<N>-<slug>` 分支，先驗證再提交，透過 PR 合併並驗證 `main` 後才能關閉 Issue。
- CVS：加入 CVS 專屬 AGENTS、Rules 與全域／專案換行保護 Hooks。`PreToolUse` 依「專案路徑＋Session」記錄 CVS 追蹤檔的原始狀態，`PostToolUse` 在每次工具完成後立即恢復，`Stop` 負責最終補漏與清理。

換行保護使用 wildcard matcher，因此直接 `apply_patch`、code mode 的 `exec → tools.apply_patch`、Shell、MCP 與其他本機工具都使用同一份修改前基準。它以檔案大小與最後寫入時間略過已驗證且未變更的檔案，只對實際變更內容讀取位元組與計算雜湊，精確恢復原本的 CRLF／LF、檔尾換行與 BOM，不會重新編碼文字；若修改前快照缺失，`PostToolUse` 仍會辨識 patch 指向的 CVS 追蹤檔並修復混合換行。`Stop` 保留最終補漏能力並在完成後清除 session 狀態，不再於對話結束時重讀所有未變更內容。Codex 的檔案修改卡片是工具執行當下的靜態 diff，PostToolUse 修復後不會回寫卡片；請以 Hook 診斷與最終 `cvs diff`／`cvs status` 判定實際結果。

安裝或更新時會清理全域與目前 CVS 專案中的受管理通知、Token、舊 CRLF 腳本與重複換行 Hook；會以安全的舊版簽章與 manifest fingerprint 清理 codex-settings 過去版本，未受管理的自訂 Hook 不會被刪除。通知 Hook 不再使用 Codex `statusMessage`，Toast 主程序與 60 秒背景清理程序也會隔離標準輸入、輸出與錯誤管線，避免 Hook 卡住或重複閃爍。全域 manifest 會記錄 `managedId`、`managedVersion`、`handlerId` 與 Handler fingerprint；安裝後會驗證全域與 CVS 專案合併後只有一個有效 Completed 通知。每次執行會將事件、來源、命令、Session／turn、程序、耗時、結束碼與全域／專案 Hook 計數寫入 `~/.codex/logs/hooks/<session-id>.log`；CVS 狀態則依「專案路徑＋Session」隔離。

安裝器會單獨詢問是否安裝 Windows 通知：首次安裝預設為否，已安裝時預設保留並更新；選擇不安裝會移除受管理通知，但保留其他自訂 Hook。通知使用 `PermissionRequest`、`request_user_input` 的 `PreToolUse` 與 `notify` 完成事件；Claim 儲存在 `~/.codex/state/notifications/claims/<hash>.json`，同一事件以跨程序 mutex 原子宣告，`showing`／`shown` Claim 會立即略過後續觸發。完成通知只顯示工作完成狀態，不會呼叫 `ccsessions`、讀寫 Token baseline 或顯示 Token／Cost；用量仍可透過 `ccusage`、`ccsessions` 與 `cdaily` 手動查詢。Native Toast 已成功後，後續 active-toast 儲存或 cleanup 失敗不會觸發 Balloon fallback；執行結果寫入 `~/.codex/logs/hooks/<session-id>.log`，其中包含 Claim、Native/Fallback 與 finality 診斷欄位。Toast 優先使用 `long`／`urgent` 與 High priority，系統不支援時降級為 `long`；聲音預設開啟，可在通知設定的 `sound` 設為 `false` 靜音；Toast 項目最多保留 60 秒，背景清理不阻塞主 Hook。安裝器仍會清理過往由 codex-settings 管理的獨立 Token Hook，且只信任本工具管理的通知及換行保護 Hook。

安裝成功後會將選擇記錄為預設專案體系。下次互動安裝按 Enter，或非互動安裝未提供 `-DevelopmentEnvironment` 時，會沿用上次的 Git／CVS 選擇。

Codex-Orchestration 是預設不安裝的選用 plugin。只有選擇安裝後才會檢查 Codex CLI 與 Python 3.11+、處理 marketplace/plugin，並詢問是否設定 Planner、Advisor、Designer、Executor。Planner 預設由目前 Root 模型負責，Advisor／Designer 預設關閉，Executor 的模型與推理強度必須由使用者確認。官方 setup/status 目前是 Codex Prompt 而非 PowerShell 指令，因此安裝器會先顯示完整預覽，再產生需於新 Codex Task 貼上的 setup Prompt，並在 manifest／摘要標示 `Pending user setup`，不會假裝 workflow 已生效；更新既有 plugin 時預設保留 workflow。

非互動安裝：

```powershell
.\Install.cmd -Mode Global
.\Install.cmd -Mode Global -DevelopmentEnvironment Git
.\Install.cmd -Mode Global -DevelopmentEnvironment CVS
.\Install.cmd -Mode Global -InstallWindowsNotifications $true
.\Install.cmd -Mode Global -InstallWindowsNotifications $false
```

常用參數：

```powershell
# ccusage 已安裝時只更新 ccsessions、cdaily 指令
.\Install.cmd -Mode Global -SkipCcusageInstall

# 安裝 request-execution-optimizer
.\Install.cmd -Mode Global -InstallRequestExecutionOptimizer

# 安裝或更新 mattpocock/skills 的 10 個預設全域技能
.\Install.cmd -Mode Global -InstallMattPocockSkills

# 安裝／更新 Codex-Orchestration plugin；非互動模式只處理 plugin，不猜測 workflow
.\Install.cmd -Mode Global -InstallCodexOrchestration

# 明確略過 Codex-Orchestration（非互動模式的預設行為）
.\Install.cmd -Mode Global -SkipCodexOrchestration

# 在 config.toml 啟用預設 request_user_input 功能
.\Install.cmd -Mode Global -EnableDefaultModeRequestUserInput

# 完整覆蓋受管理目標
.\Install.cmd -Mode Global -InstallStyle Replace

# 強制執行既有 ccusage 的 runtime validation 與通知測試
.\Install.cmd -Mode Global -ForceValidation -ForceNotificationTest

# CI / 自動化不等待按鍵
.\Install.cmd -Mode Global -NoPause
```

第二次安裝若目標內容、Hook 與通知腳本都未變更，會走 `Unchanged`／`Skipped` 快速路徑；必要的交易備份、Hook 安全驗證與 rollback 不會被移除。

## 設定位置

主要全域設定安裝到：

```text
%USERPROFILE%\.codex\
├─ AGENTS.md
├─ config.toml
├─ rules\default.rules
├─ hooks.json                         # 僅 CVS
├─ hooks\preserve-line-endings.ps1   # 僅 CVS
└─ .codex-settings-manifest.json
```

`request-execution-optimizer` 安裝到 `%USERPROFILE%\.codex\skills`。`ccsessions` 與 `cdaily` 的受管理區塊寫入目前使用者的 PowerShell Profile。

`mattpocock/skills` 會安裝到 Codex 的全域技能目錄。首次安裝會詢問且預設為 `N`；只要偵測到曾由 `mattpocock/skills` 安裝任一全域技能，後續執行安裝器就會自動安裝或更新下列 10 個預設技能：

- `setup-matt-pocock-skills`
- `grill-with-docs`
- `to-spec`
- `to-tickets`
- `implement`
- `tdd`
- `code-review`
- `diagnosing-bugs`
- `handoff`
- `wait-what`

安裝器會以非互動模式執行：

```powershell
npx --yes skills@latest add mattpocock/skills -g -a codex -y --skill setup-matt-pocock-skills --skill grill-with-docs --skill to-spec --skill to-tickets --skill implement --skill tdd --skill code-review --skill diagnosing-bugs --skill handoff --skill wait-what
```

## 安全機制

安全合併會依檔案類型處理：

- `AGENTS.md`、Rules：只更新受管理區塊。
- `config.toml`：保留既有鍵值與區段，只加入缺少的設定。
- `hooks.json`：只更新本工具管理的換行 Hook，保留其他使用者 Hook。
- 其他檔案：只覆寫本工具擁有的版本；遇到未受管理的同名檔案會停止。

安裝前會建立交易備份：

```text
%LOCALAPPDATA%\CodexSettingsBackup\<時間>-global-transaction
```

若上次執行中斷，下次安裝、還原或移除會先回復未完成交易。

## 備份、還原與移除

```powershell
# 建立全域手動備份
.\Install.cmd -Mode Backup

# 選擇最近備份並還原
.\Install.cmd -Mode Restore

# 移除全域受管理設定
.\Install.cmd -Mode Uninstall
```

手動備份預設位於 `%LOCALAPPDATA%\CodexSettingsBackup`。

## ccusage、ccsessions、cdaily

安裝器會先檢查 `ccusage`：

- 尚未安裝：安裝最新版。
- 已安裝：沿用現有套件，不重複安裝。
- 使用 `-SkipCcusageInstall`：不安裝套件，只新增或更新 Profile 指令。

```powershell
ccsessions                       # 顯示最近 10 筆 Session
ccsessions 20                    # 顯示最近 20 筆 Session
ccsessions 019fd1f8...4a87a2     # 顯示指定 Session
ccsessions -Json <Session ID>    # 輸出機器可讀 JSON
cdaily                           # 顯示最近 7 天的每日統計
cdaily 30                        # 顯示最近 30 天的每日統計
```

- `ccsessions [數量或 Session ID]`：顯示 Session ID、使用模型、Token、費用與台北時間；同一 Session 切換過的模型會分行顯示。加上 `-Json` 可輸出機器可讀資料。
- `cdaily [天數]`：顯示指定天數內每天的模型、Token 與費用統計，預設為 7 天。

## Issue 修正與主分支驗證

修正 GitHub Issue 時，先同步最新主分支，再建立獨立的 `issue/<issue-number>-<short-description>` 分支；禁止直接在 `main` 修改或提交，也不能從其他 Issue 分支分叉。PR 必須以 `main` 為 base，標題或提交包含 Issue 編號，內容使用 `Refs #<issue-number>`，在主分支驗證完成前不得使用 `Fixes`、`Closes` 或 `Resolves`。

合併前必須完成 Issue 驗收條件、相關本機測試、PR 規則檢查、工作樹與 PR 差異檢查。合併後先執行 `git switch main` 與 `git pull --ff-only origin main`，確認合併提交、檔案、主分支來源驗證與驗收條件，再在 Issue 留下以下紀錄並關閉：

```text
Issue=<number>
Branch=issue/<number>-<description>
PR=<number>
MergeCommit=<sha>
MainVerification=passed
Tests=<commands and results>
```

`.github/workflows/pull-request-validation.yml` 先以事件資料檢查分支、PR 標題、引用與禁止自動關閉關鍵字，再只查一次 Issue 狀態；PR 標題必須包含 Issue 編號，因此不再取得完整 commit 清單。它使用 Ubuntu runner、三分鐘 timeout 與同一 PR 的 concurrency cancellation。`.github/workflows/changed-area-regression.yml` 只在 workflow、Git 工作流文件或對應測試變更時執行 workflow contract regression。

`main-validation.yml` 對由 PR 合併至 main 的提交保留 merged-PR provenance 驗證，成功後寫入 `codex-settings-main-verification:v1` machine-readable Issue receipt；必要的無 PR 維護提交則記錄訊息並成功結束，不建立 Issue receipt。`issue-close-guard.yml` 只讀取 receipt 並比較 merge commit 是否仍可由 `main` 到達，不再掃描最近 100 個 PR 或重新搜尋 workflow runs；若合併已完成但 receipt 尚未產生，會延後驗證而不觸發 close → reopen 競態。純 API workflow 使用 Ubuntu runner、短 timeout 與 concurrency cancellation。

Release 保留必要的 Windows installer build 與 correctness regression，但以 GitHub API compare 驗證 tag 可由 `main` 到達，checkout 改為 `fetch-depth: 1`；CVS performance benchmark 與 Issue workflow contract test 明確列為非 release-blocking，改由變更相關 workflow 或專門驗證執行。儲存庫仍應將 `main` 設定為必須經 PR、分支符合命名規則與必要 CI 通過後才能合併。

## 發佈一鍵安裝包

版本使用 `v主版.次版.修訂版` 格式，依本次變更中影響最大的類型升版：

| 變更類型 | 升版規則 | 範例（目前為 `v1.3.4`） |
| --- | --- | --- |
| 大架構修正 | 主版本 `+1.0.0`，次版與修訂版歸零 | `v2.0.0` |
| 主功能修改 | 次版本 `+0.1.0`，修訂版歸零 | `v1.4.0` |
| 小功能或錯誤修正 | 修訂版本 `+0.0.1` | `v1.3.5` |

同一版本包含多種類型時採最高層級，不重複累加。可用下列指令依最新 Git tag 計算下一版：

```powershell
.\tools\plan-release.ps1 -ChangeType Architecture
.\tools\plan-release.ps1 -ChangeType Feature
.\tools\plan-release.ps1 -ChangeType Fix
```

確認版本後再建立對應的 Git tag。GitHub Actions 僅接受完整的 `v主版.次版.修訂版` 標籤，且標籤提交必須位於 `main`；Release 工作流會先執行全部測試，再建置與發佈安裝器。

```powershell
.\tools\build-installer.ps1 -Version v1.8.6
```

輸出為唯一的 `dist\CodexSettings-Setup-v1.8.6.cmd`，內嵌所有必要模組與範本。正式發佈時，檔名版本會直接取自 Git tag。

原始碼依職責整理為：

```text
src\
├─ install.ps1
├─ load-core.ps1
├─ load-operations.ps1
├─ load-installation.ps1
├─ commands\
│  ├─ backup-settings.ps1
│  ├─ restore-settings.ps1
│  └─ uninstall-settings.ps1
├─ core\
│  ├─ file-system.ps1
│  ├─ hook-configuration.ps1
│  ├─ managed-content.ps1
│  └─ file-transactions.ps1
├─ installation\
│  ├─ prompts.ps1
│  ├─ prerequisites.ps1
│  ├─ installation-context.ps1
│  ├─ installation-plan.ps1
│  ├─ installation-runner.ps1
│  ├─ installation-state.ps1
│  ├─ hook-validation.ps1
│  ├─ hook-trust.ps1
│  └─ target-installer.ps1
├─ integrations\
│  ├─ ccusage-state.ps1
│  ├─ external-state-recovery.ps1
│  └─ install-usage-tools.ps1
└─ templates\
tests\
tools\
├─ build-installer.ps1
└─ plan-release.ps1
```

`install.ps1` 只負責參數解析與啟動 runner；context 集中解析安裝選項與路徑，runner 負責流程與回復，state 負責 manifest。`load-core.ps1`、`load-operations.ps1` 與 `load-installation.ps1` 集中定義模組載入順序；Ponytail、Codex-Orchestration 與 Serena 只在明確選用後載入實作，略過時不執行其 discovery 或 CLI。核心檔案不依賴外部套件，安裝層也不直接實作原子寫入與交易回復。

推送符合 `v主版.次版.修訂版` 的 Git tag 時，GitHub Actions 會建立同名 Release 附件。
