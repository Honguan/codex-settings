# Codex Settings

Windows 上的 Codex 全域、Git 專案與 CVS 專案設定管理工具。

提供：

- 全域 47 條、Git 13 條、CVS 8 條權限規則。
- 安全合併、備份、還原、移除與中斷回復。
- Context7、Playwright MCP。
- `ccusage@latest`、`ccsessions`、`cdaily`。
- Git／CVS 專案登記與批次更新。
- CVS CRLF Hook。

## 需求

全域安裝需要：

- Windows
- PowerShell 7 或更新版本
- Codex CLI
- Node.js 20 或更新版本
- npm、npx

`ccsessions`、`cdaily` 會安裝到執行安裝器的 PowerShell 7 `CurrentUserAllHosts` 與 `CurrentUserCurrentHost` Profile，避免被主機專屬 Profile 中的同名命令覆蓋。

**PowerShell 7 已測試通過。**

## 快速安裝

```powershell
# 全域設定、MCP、ccusage、ccsessions、cdaily
./install.ps1 -Mode Global

# 另外選用安裝 request-execution-optimizer 全域技能
./install.ps1 -Mode Global -InstallRequestExecutionOptimizer

# 選用啟用 request_user_input 預設模式
./install.ps1 -Mode Global -EnableDefaultModeRequestUserInput

# Git 專案
./install.ps1 -Mode Git -ProjectPath 'E:\Git\MyProject'

# CVS 專案
./install.ps1 -Mode CVS -ProjectPath 'E:\CVS\MyProject'
```

也可雙擊 `Install.cmd`。若系統沒有 PowerShell 7，全域安裝會停止並顯示實際版本。

互動式全域安裝也會詢問是否加入：

```toml
[features]
default_mode_request_user_input = true
```

## 模型設定

全新設定預設加入：

```toml
model = "gpt-5.6-terra"
model_reasoning_effort = "high"
```

安全合併不會覆蓋使用者原本的頂層 `model` 或 `model_reasoning_effort`。既有值會保留。

沒有設定 `review_model`；`/review` 沿用目前 Session 模型。

### codex-model-router

建議順序：

```powershell
./install.ps1 -Mode Global
npx codex-model-router install --global
npx codex-model-router doctor --global
```

不要搭配：

```powershell
npx codex-model-router install --global --set-default
```

責任分工：

| 工具 | 管理內容 |
|---|---|
| `codex-settings` | 主模型模板、AGENTS、Rules、MCP、Hook、ccusage、PowerShell Profile |
| `codex-model-router` | Terra／Luna／Sol Agents 與路由 Skills |

兩者沒有直接檔案衝突；Router 一般安裝不修改主模型。

## 安全機制

### 安全合併

- `AGENTS.md`、Rules 使用管理區塊。
- `config.toml` 保留既有頂層鍵與 MCP 區段。
- CVS `hooks.json` 保留其他 Hook。
- 不覆蓋內容不同的未管理檔案。

### 編碼與換行

支援並保留：

- UTF-8、有／無 BOM
- UTF-16 LE／BE
- 目前 Windows ANSI Code Page，例如繁體中文系統的 Big5／950
- CRLF／LF

檔案無法可靠解碼，或新內容無法用原編碼表示時，安裝會停止，不會猜測寫回。

### 中斷回復

設定寫入使用：

- 單一操作鎖
- 原子檔案替換
- 持續更新的交易 Journal
- 每個檔案修改前備份

PowerShell、程序或電腦異常中止後，下次執行安裝、移除或還原時，會先回復未完成交易。

交易備份位置：

```text
%LOCALAPPDATA%\CodexSettingsBackup
```

## 更新全域與所有專案

Git／CVS 專案安裝成功後會登記到：

```text
%LOCALAPPDATA%\CodexSettings\projects.json
```

執行：

```powershell
./update.ps1
```

會：

1. `git pull --ff-only` 更新本設定倉庫。
2. 更新全域設定、MCP、ccusage、`ccsessions`、`cdaily`。
3. 更新所有已登記 Git／CVS 專案的 Codex 設定。
4. 個別顯示成功或失敗原因。

不會對登記專案執行 `git pull` 或 `cvs update`，也不會更新 `codex-model-router` 套件。

可用參數：

```powershell
./update.ps1 -SkipRepositoryPull
./update.ps1 -SkipGlobal
./update.ps1 -SkipCcusageInstall
```

## 備份與還原

### 手動備份

```powershell
./backup.ps1 -Mode Global
./backup.ps1 -Mode Project -ProjectPath 'E:\Git\MyProject'
```

全域手動備份只包含指定設定元件：

- AGENTS、`config.toml`、Rules、Agents、Hooks、Tools
- codex-settings Manifest
- codex-model-router 狀態與設定備份檔
- `~/.agents/skills`
- `~/.codex/skills`
- 已登記專案清單
- PowerShell 7 Profile
- ccusage 安裝狀態

不備份 Codex 驗證資料、Sessions、History、Logs 或明文 Context7 Key。

### 還原

```powershell
./restore.ps1
```

可還原手動備份、安裝交易備份及新版解除安裝備份。

### 移除

```powershell
./uninstall.ps1 -Mode Global
./uninstall.ps1 -Mode Project -ProjectPath 'E:\Git\MyProject'
```

解除安裝前會建立完整可還原備份，包括：

- 所有即將修改或移除的檔案
- PowerShell Profile
- 專案登記檔
- ccusage 當前版本狀態
- Context7 Key 狀態

Context7 Key 僅以 Windows 使用者 DPAPI 加密後保存於本機解除安裝備份，不會寫入倉庫或明文檔案。

`-Force` 會移除內容已被使用者修改的受管理檔案，只應在確定不需保留時使用。

## ccusage、ccsessions、cdaily

來源：<https://github.com/ccusage/ccusage>

全域安裝維持最新版：

```powershell
npm install --global ccusage@latest
```

使用方式：

```powershell
ccsessions
ccsessions 20
ccsessions <Session ID>
cdaily
cdaily 30
```

`ccsessions` 保留自訂的 Session ID、Models、Token、Total、Cost、Time 資訊與數量／ID 篩選功能；`ccsessions` 與 `cdaily` 的 Token 欄位使用 `K`、`M`、`B` 計數符號，表格框線採用 `ccusage` 的報表風格。

## MCP

### Context7

安裝時可輸入 API Key；Key 儲存在目前 Windows 使用者的 `CONTEXT7_API_KEY` 環境變數。

```toml
[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
env_http_headers = { "CONTEXT7_API_KEY" = "CONTEXT7_API_KEY" }
```

略過 Key：

```powershell
./install.ps1 -Mode Global -SkipContext7Key
```

### Playwright

```toml
[mcp_servers.playwright]
command = "npx"
args = ["-y", "@playwright/mcp@latest"]
```

Pencil 不安裝、不偵測、不修改。

## CVS 流程

每個目標依序：

1. `cvs status <target>`
2. `cvs -n update <target>`
3. 檢查衝突與非預期變更
4. 必要時執行 `cvs update <target>`
5. 再次執行 `cvs status <target>`

遇到 `C`、錯誤、非預期合併或不確定狀態時立即停止。`cvs commit` 必須取得使用者明確核准。

CVS Hook 只處理專案內、白名單文字副檔名且不超過 10 MB 的檔案，並保留原始位元內容，只轉換換行為 CRLF。

安裝 CVS 設定後重新啟動 Codex，使用 `/hooks` 檢查並信任 Hook。
