# Codex Settings

用 Git 管理 Codex 全域設定、Git 專案模板、CVS 專案模板，以及 Windows 一鍵安裝工具。

## 目錄

```text
codex-settings/
├─ Install.cmd
├─ install.ps1
├─ backup.ps1
├─ restore.ps1
├─ update.ps1
├─ uninstall.ps1
└─ templates/
   ├─ global/
   │  ├─ AGENTS.md
   │  ├─ config.toml
   │  └─ rules/default.rules
   ├─ git-project/
   │  ├─ AGENTS.md
   │  └─ .codex/rules/default.rules
   └─ cvs-project/
      ├─ AGENTS.md
      ├─ .codex-root
      ├─ .codex/rules/default.rules
      └─ .agents/skills/php72-cvs/SKILL.md
```

## 使用方式

### 雙擊安裝

執行 `Install.cmd`，選擇：

1. 安裝全域設定
2. 安裝 Git 專案設定
3. 安裝 CVS 專案設定
4. 備份目前設定
5. 還原備份
6. 更新此設定倉庫
7. 移除由本工具安裝的設定

### PowerShell

```powershell
./install.ps1 -Mode Global
./install.ps1 -Mode Git -ProjectPath 'E:\Git\MyProject'
./install.ps1 -Mode CVS -ProjectPath 'E:\CVS\MyProject'
```

## 設定載入邏輯

- 全域指示：`~/.codex/AGENTS.md`
- 全域設定：`~/.codex/config.toml`
- 全域規則：`~/.codex/rules/*.rules`
- 專案設定：`<project>/.codex/config.toml` 與 `<project>/.codex/rules/*.rules`
- 專案指示：從專案根目錄到目前工作目錄的 `AGENTS.md`
- 專案技能：從目前目錄向上到專案根目錄的 `.agents/skills/*/SKILL.md`

CVS 專案使用 `.codex-root` 作為根目錄標記，避免每層 `CVS` 目錄被誤判為專案根目錄。

## 安全範圍

此倉庫不備份：

- `auth.json`
- API Key、Token、密碼
- Session、歷史紀錄與日誌
- 本機私有路徑設定
- MCP 機密參數

安裝前會先備份被覆蓋的設定，備份預設存放於：

```text
%LOCALAPPDATA%\CodexSettingsBackup
```
