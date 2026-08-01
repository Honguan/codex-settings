# Codex Settings

用 Git 管理 Codex 全域設定、全域技能、Git 專案模板、CVS 專案模板，以及 Windows 一鍵安裝工具。

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
   ├─ user-skills/
   │  └─ request-execution-optimizer/
   │     ├─ SKILL.md
   │     └─ agents/openai.yaml
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

1. 安裝全域設定與全域技能
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

全域安裝會部署到：

```text
~/.codex/
~/.agents/skills/request-execution-optimizer/
```

## 全域技能

### 請求執行最佳化

技能識別名稱：

```text
request-execution-optimizer
```

原始名稱 `transform-prompts-gpt-5p6` 已改為不綁定模型版本的名稱，避免後續更換模型時再次改名。

此技能會：

- 將請求整理為最小、可執行、可驗證的任務契約。
- 保留使用者指定的數值、語言、格式、範圍、權限與安全要求。
- 避免過度規劃、擴大範圍、重複說明與不必要確認。
- 區分唯讀、修改、外部寫入與破壞性操作的權限邊界。
- 一般情況直接執行，不展示內部契約或隱藏推理。

中文顯示名稱與預設提示位於：

```text
templates/user-skills/request-execution-optimizer/agents/openai.yaml
```

## 設定載入邏輯

- 全域指示：`~/.codex/AGENTS.md`
- 全域設定：`~/.codex/config.toml`
- 全域規則：`~/.codex/rules/*.rules`
- 全域技能：`~/.agents/skills/*/SKILL.md`
- 專案設定：`<project>/.codex/config.toml` 與 `<project>/.codex/rules/*.rules`
- 專案指示：從專案根目錄到目前工作目錄的 `AGENTS.md`
- 專案技能：從目前目錄向上到專案根目錄的 `.agents/skills/*/SKILL.md`

CVS 專案使用 `.codex-root` 作為根目錄標記，避免每層 `CVS` 目錄被誤判為專案根目錄。

## 備份與移除

安裝前會先備份被覆蓋的設定，預設存放於：

```text
%LOCALAPPDATA%\CodexSettingsBackup
```

全域設定與全域技能各自保存安裝清單及 SHA-256。移除時，已被使用者修改的檔案預設不會刪除。

## 安全範圍

此倉庫不備份：

- `auth.json`
- API Key、Token、密碼
- Session、歷史紀錄與日誌
- 本機私有路徑設定
- MCP 機密參數
