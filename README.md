# Codex Settings

Windows 上的 Codex 全域設定一鍵安裝與管理工具。

所有設定都安裝到使用者層級，不再於 Git、CVS 或其他專案目錄建立 `AGENTS.md`、Rules、Hooks 或登記資料。

## 主要功能

- 安裝或更新全域 `AGENTS.md`、`config.toml` 與權限規則。
- 安裝 Context7、Playwright MCP 設定。
- 安裝或更新 `ccusage`，並維護 `ccsessions`、`cdaily` 指令。
- 選用 `request-execution-optimizer` 與 `mattpocock/skills`。
- 安全合併既有設定，並提供交易備份、中斷回復、備份、還原及移除。
- 首次執行新版安裝器時，自動清除舊登記專案內由本工具管理的設定。

## 需求

- Windows 10 或更新版本。
- PowerShell 7 或更新版本。
- Codex CLI。
- Node.js 20 或更新版本，且 `node`、`npm`、`npx` 可由 PATH 執行。

## 一鍵安裝

下載 Release 的 `CodexSettings-OneClick.zip`，解壓縮後只執行：

```powershell
.\Install.cmd
```

主選單只有四項：

1. 全域安裝／更新
2. 備份目前設定
3. 還原備份
4. 移除受管理設定

安全合併是預設安裝方式，會保留未受管理的既有內容。完整覆蓋只應在確定要用範本取代目標設定時使用。

非互動安裝：

```powershell
.\Install.cmd -Mode Global
```

常用參數：

```powershell
# 不詢問 Context7 API Key
.\Install.cmd -Mode Global -SkipContext7Key

# ccusage 已安裝時只更新 ccsessions、cdaily 指令
.\Install.cmd -Mode Global -SkipCcusageInstall

# 安裝 request-execution-optimizer
.\Install.cmd -Mode Global -InstallRequestExecutionOptimizer

# 啟動 mattpocock/skills 安裝器
.\Install.cmd -Mode Global -InstallMattPocockSkills

# 在 config.toml 啟用預設 request_user_input 功能
.\Install.cmd -Mode Global -EnableDefaultModeRequestUserInput

# 完整覆蓋受管理目標
.\Install.cmd -Mode Global -InstallStyle Replace
```

## 舊專案設定清理

新版全域安裝會讀取舊版 `%LOCALAPPDATA%\CodexSettings\projects.json`，逐一清理已登記專案：

- 刪除舊安裝 manifest 所列的專案 `AGENTS.md`／`agent.md` 與 Rules。
- 移除 CVS CRLF Hooks；其他 Hook 予以保留。
- 移除 `.codex-root`、CRLF Hook 腳本與專案 manifest。
- 清理完成後刪除舊專案登記清單。

所有變更都納入同一筆交易備份；安裝失敗時會回復。找不到登記清單時直接略過，不會掃描或修改未登記的專案。

## 設定位置

主要全域設定安裝到：

```text
%USERPROFILE%\.codex\
├─ AGENTS.md
├─ config.toml
├─ rules\default.rules
└─ .codex-settings-manifest.json
```

選用技能安裝到 `%USERPROFILE%\.codex\skills`。`ccsessions` 與 `cdaily` 的受管理區塊寫入目前使用者的 PowerShell Profile。

## 安全機制

安全合併會依檔案類型處理：

- `AGENTS.md`、Rules：只更新受管理區塊。
- `config.toml`：保留既有鍵值與區段，只加入缺少的設定。
- `hooks.json`：保留非本工具管理的 Hook。
- 其他檔案：只覆寫本工具擁有的版本；遇到未受管理的同名檔案會停止。

安裝前會建立交易備份：

```text
%LOCALAPPDATA%\CodexSettingsBackup\<時間>-global-transaction
```

若上次執行中斷，下次安裝、還原或移除會先回復未完成交易。

## 備份、還原與移除

```powershell
# 建立全域手動備份
.\backup.ps1 -Mode Global

# 選擇最近備份並還原
.\restore.ps1

# 移除全域受管理設定
.\uninstall.ps1 -Mode Global
```

手動備份預設位於 `%LOCALAPPDATA%\CodexSettingsBackup`。Context7 Key 只記錄是否存在，不會把明文密鑰寫入備份或儲存庫。

## ccusage、ccsessions、cdaily

安裝器會先檢查 `ccusage`：

- 尚未安裝：安裝最新版。
- 已安裝：沿用現有套件，不重複安裝。
- 使用 `-SkipCcusageInstall`：不安裝套件，只新增或更新 Profile 指令。

```powershell
ccsessions
ccsessions -Since 2026-08-01 -Until 2026-08-06
cdaily
```

`ccsessions` 的時間會以台北時區顯示。

## 發佈一鍵安裝包

```powershell
.\build-release.ps1
```

輸出為 `dist\CodexSettings-OneClick.zip`。壓縮包包含必要範本與支援程式，但使用者只需要執行 `Install.cmd`。

推送 `v*` Git tag 時，GitHub Actions 會建立同名 Release 附件。
