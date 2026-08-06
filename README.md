# Codex Settings

Windows 上的 Codex 全域設定一鍵安裝與管理工具。

所有設定都安裝到使用者層級，不再於 Git、CVS 或其他專案目錄建立 `AGENTS.md`、Rules、Hooks 或登記資料。

## 主要功能

- 安裝或更新全域 `AGENTS.md`、`config.toml` 與權限規則。
- 在全域安裝流程選擇 Git 或 CVS，合併對應的全域 AGENTS 與 Rules。
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

下載 Release 的單一檔案 `CodexSettings-Setup.cmd`，不需解壓縮，直接執行：

```powershell
.\CodexSettings-Setup.cmd
```

安裝器會在 `%TEMP%` 解開內嵌程式、執行後立即清理。從原始碼執行時則使用根目錄的 `Install.cmd`。

主選單只有四項：

1. 全域安裝／更新
2. 備份目前設定
3. 還原備份
4. 移除受管理設定

安全合併是預設安裝方式，會保留未受管理的既有內容。完整覆蓋只應在確定要用範本取代目標設定時使用。

選擇「全域安裝／更新」後會選擇開發環境：

- Git（首次安裝預設）：加入 Git 專屬 AGENTS 與 Rules，並移除全域 CVS CRLF Hook。
- CVS：加入 CVS 專屬 AGENTS、Rules 與全域 CRLF Hook。Hook 只在目前目錄屬於 CVS 工作副本時執行。

安裝成功後會將選擇記錄為預設專案體系。下次互動安裝按 Enter，或非互動安裝未提供 `-DevelopmentEnvironment` 時，會沿用上次的 Git／CVS 選擇。

非互動安裝：

```powershell
.\Install.cmd -Mode Global
.\Install.cmd -Mode Global -DevelopmentEnvironment Git
.\Install.cmd -Mode Global -DevelopmentEnvironment CVS
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
├─ hooks.json                 # 僅 CVS
├─ hooks\normalize-cvs-crlf.ps1 # 僅 CVS
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
.\Install.cmd -Mode Backup

# 選擇最近備份並還原
.\Install.cmd -Mode Restore

# 移除全域受管理設定
.\Install.cmd -Mode Uninstall
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

確認版本後再建立對應的 Git tag。GitHub Actions 僅接受完整的 `v主版.次版.修訂版` 標籤。

```powershell
.\tools\build-installer.ps1
```

輸出為唯一的 `dist\CodexSettings-Setup.cmd`，內嵌所有必要模組與範本。

原始碼依職責整理為：

```text
src\
├─ installer.ps1
├─ modules\
├─ operations\
└─ templates\
tests\
tools\
├─ build-installer.ps1
└─ plan-release.ps1
```

推送符合 `v主版.次版.修訂版` 的 Git tag 時，GitHub Actions 會建立同名 Release 附件。
