# Codex Settings

用 Git 管理 Codex 全域設定、Git 專案模板、CVS 專案模板、MCP 與 Windows 一鍵安裝工具。

## 目前內容

```text
codex-settings/
├─ Install.cmd
├─ install.ps1
├─ install-ccusage.ps1
├─ backup.ps1
├─ restore.ps1
├─ update.ps1
├─ uninstall.ps1
└─ templates/
   ├─ global/
   │  ├─ AGENTS.md
   │  ├─ config.toml
   │  ├─ rules/default.rules        # 47 條
   │  └─ tools/configure-pencil-mcp.ps1
   ├─ powershell/
   │  └─ ccusage-profile.ps1        # cs、cdaily
   ├─ user-skills/
   │  └─ request-execution-optimizer/
   ├─ git-project/
   │  ├─ AGENTS.md
   │  └─ .codex/rules/default.rules # 13 條
   └─ cvs-project/
      ├─ AGENTS.md
      ├─ .codex-root
      ├─ .codex/hooks.json
      ├─ .codex/hooks/crlf-updated-files.ps1
      ├─ .codex/rules/default.rules # 8 條
      └─ .agents/skills/php72-cvs/SKILL.md
```

## 安裝

雙擊 `Install.cmd`，或執行：

```powershell
./install.ps1 -Mode Global
./install.ps1 -Mode Git -ProjectPath 'E:\Git\MyProject'
./install.ps1 -Mode CVS -ProjectPath 'E:\CVS\MyProject'
```

全域模式會安裝：

- `~/.codex` 全域規則與設定。
- `~/.agents/skills` 全域技能。
- Context7、Playwright 與 Pencil MCP。
- [ccusage](https://github.com/ccusage/ccusage) 最新版。
- PowerShell 指令 `cs` 與 `cdaily`。

`cs` 預設顯示最近 10 個 Codex Session；`cs 20` 顯示最近 20 個；`cs <Session ID>` 查詢指定 Session。`cdaily` 預設統計最近 7 天；`cdaily 30` 統計最近 30 天，時區固定為 `Asia/Taipei`。

## 全域 MCP

### Context7

使用官方遠端端點：

```toml
[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
```

沒有 API Key 時仍可使用基本額度。API Key 不存入此倉庫。

### Playwright

使用 Microsoft 官方套件：

```toml
[mcp_servers.playwright]
command = "npx"
args = ["-y", "@playwright/mcp@latest"]
```

### Pencil

Pencil 的 MCP 執行檔包含 IDE 版本及平台路徑，不能安全寫死。全域安裝會執行：

```text
~/.codex/tools/configure-pencil-mcp.ps1
```

它會尋找 VS Code、Cursor 或 Pencil 桌面程式的 MCP 執行檔，找到後將正確的 `[mcp_servers.pencil]` 寫入 `~/.codex/config.toml`。沒有安裝 pen.dev 時只顯示警告，不會產生失效設定。

## CVS 更新流程

CVS 專案規則要求每個目標依序執行：

1. `cvs status <target>`
2. `cvs -n update <target>`
3. 檢查衝突、錯誤與非預期變更
4. 必要且安全時執行 `cvs update <target>`
5. 再次執行 `cvs status <target>`

禁止無目標的根目錄 `cvs update`。遇到 `C`、非預期合併或不確定狀態時立即停止。

## CRLF Hook

CVS Hook 只處理 `.codex-root` 內的普通文字檔，並增加以下保護：

- 拒絕專案外路徑、符號連結、`CVS` 與 `.codex` 內部檔案。
- 排除 shell、patch、diff、憑證與金鑰格式。
- 略過空檔、含 NUL 的二進位檔與 UTF-16 類檔案。
- 狀態檔存放於 `%LOCALAPPDATA%`，不污染 CVS 工作副本。
- 合併重複路徑，失敗時輸出原因並回傳非零狀態。

安裝 CVS 設定後重新啟動 Codex，使用 `/hooks` 檢查並信任專案 Hook。

## 安全範圍

不備份或提交：

- `auth.json`
- API Key、Token、密碼
- Session、歷史紀錄與日誌
- Pencil、Context7 或其他 MCP 的登入資訊
- 本機私有設定

安裝前的檔案備份預設放在：

```text
%LOCALAPPDATA%\CodexSettingsBackup
```
