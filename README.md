# Codex Settings

用 Git 管理 Codex 全域設定、Git 專案模板、CVS 專案模板、MCP、ccusage，以及 Windows 一鍵安裝工具。

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
├─ lib/
│  ├─ codex-settings-common.ps1
│  ├─ install-functions.ps1
│  └─ project-registry.ps1
└─ templates/
   ├─ global/
   │  ├─ AGENTS.md
   │  ├─ config.toml
   │  └─ rules/default.rules        # 47 條
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

全域模式需要：

- PowerShell 5.1 或更新版本。
- Codex CLI。
- Node.js 20 或更新版本。
- npm 與 npx。
- 可連線到 npm registry。

安裝前會檢查命令、版本、目標目錄寫入權限、PowerShell Profile 寫入權限及內建 TOML 模板。

## 明確模型設定

全域 `config.toml` 使用完整模型名稱，不使用含糊的 `gpt-5.6`：

| 用途 | 模型 | 推理強度 |
|---|---|---|
| 主要對話、預設執行與 `/review` | `gpt-5.6-terra` | `high` |

設定內容：

```toml
model = "gpt-5.6-terra"
model_reasoning_effort = "high"
```

沒有另外設定 `review_model`。Codex 的 `/review` 預設沿用目前 Session 模型，因此在主模型已是 Terra 時，不需要重複指定。Terra 負責一般調查、規劃、審查、驗證與重新規劃；Sol 則保留為模型路由無法解決核心邏輯時的最後唯讀顧問。

## 與 codex-model-router 相容性

搭配 [Honguan/codex-model-router](https://github.com/Honguan/codex-model-router) 時，建議責任分工如下：

| 設定擁有者 | 負責內容 |
|---|---|
| `codex-settings` | 全域主模型、AGENTS、Rules、MCP、Hook、ccusage、PowerShell Profile |
| `codex-model-router` | `terra.toml`、`luna.toml`、`sol.toml`、`model-router` Skill、`implementation-planning` Skill |

模型路由使用的完整名稱：

| Agent | 模型 | 推理強度 | 沙盒 |
|---|---|---|---|
| Terra | `gpt-5.6-terra` | `high` | `read-only` |
| Luna | `gpt-5.6-luna` | `xhigh` | `workspace-write` |
| Sol | `gpt-5.6-sol` | `medium` | `read-only` |

建議安裝順序：

```powershell
./install.ps1 -Mode Global
npx codex-model-router install --global
npx codex-model-router doctor --global
```

不要在此組合中使用：

```powershell
npx codex-model-router install --global --set-default
```

原因是主模型已由 `codex-settings` 明確管理。Router 的一般安裝不修改主模型、AGENTS、Rules、Hooks、MCP、Shell Profile 或環境變數，因此沒有直接檔案衝突。

若先安裝 Router，`codex-settings` 的安全合併會保留既有頂層模型設定；若先安裝 `codex-settings`，Router 一般安裝只新增自己的 Agents 與 Skills。`request-execution-optimizer` 已明確讓程式代理路由與 `implementation-planning` 由 Router 接管，不會重複建立平行計畫。

Git 或 CVS 專案安裝成功後會自動登記到：

```text
%LOCALAPPDATA%\CodexSettings\projects.json
```

登記檔只保存專案類型、路徑與安裝時間，不保存憑證、Token 或專案內容。重複安裝同一專案只會更新現有登記，不會建立重複項目。

## 一次更新全域與所有登記專案

執行：

```powershell
./update.ps1
```

預設流程：

1. 確認設定倉庫沒有未提交變更。
2. 執行 `git pull --ff-only` 更新設定倉庫。
3. 更新全域 Codex 設定、MCP、ccusage、`cs` 與 `cdaily`。
4. 依序更新所有已登記的 Git 與 CVS 專案設定。
5. 顯示每個目標的成功或失敗狀態。

每個目標仍使用獨立的交易式安裝流程。單一專案失敗不會阻止其他登記專案更新；全部執行完成後會列出實際錯誤，並在存在失敗時回傳 Exit Code 1。

可用參數：

```powershell
./update.ps1 -SkipRepositoryPull
./update.ps1 -SkipGlobal
./update.ps1 -SkipCcusageInstall
```

- `-SkipRepositoryPull`：不執行設定倉庫的 `git pull`。
- `-SkipGlobal`：只更新已登記專案。
- `-SkipCcusageInstall`：更新全域設定時不重新安裝 ccusage。

不存在或已移動的登記路徑會標記為失敗，但不會自動刪除登記。重新以新路徑安裝專案，或完整解除安裝舊專案設定後，可更新登記資料。

## 安全合併與交易式安裝

安裝器不再直接覆蓋既有設定：

- `AGENTS.md` 與 `default.rules` 使用管理標記區塊合併。
- `config.toml` 保留既有頂層鍵與 MCP 區段，只加入缺少的設定。
- CVS `hooks.json` 保留既有 Hook，只更新本套件的 CRLF Hook。
- 套件專屬 Skill 與 Hook 腳本只在檔案由本套件管理或內容相同時更新；不會靜默覆蓋不同的未管理檔案。

全域安裝採交易式流程：

1. 保存所有即將修改的檔案、PowerShell Profile、ccusage 狀態與 Context7 環境狀態。
2. 套用設定、MCP、ccusage、`cs` 與 `cdaily`。
3. 全部成功後才寫入新版 Manifest。
4. 任一步驟失敗時，自動回復檔案、Profile、ccusage 與本次建立的 Context7 Key。

Git／CVS 安裝也會把專案登記檔納入交易；登記失敗時會回復本次專案設定與登記內容。

交易備份位於：

```text
%LOCALAPPDATA%\CodexSettingsBackup
```

## ccusage、cs、cdaily

來源：[ccusage/ccusage](https://github.com/ccusage/ccusage)

全域安裝會執行：

```powershell
npm install --global ccusage@latest
```

`cs` 與 `cdaily` 執行時優先使用：

```powershell
npx --yes ccusage@latest
```

因此維持 `latest` 設定；全域套件則提供直接使用 `ccusage` 指令的能力。

### cs

```powershell
cs
cs 20
cs 019fbc31-5856-73f0-91d9-978f388cc223
cs 019fbc31...8cc223
```

失敗時會明確輸出：

- 缺少 npx 或 ccusage。
- 實際執行命令。
- 原始 Exit Code。
- 命令輸出或 JSON 預覽。
- JSON 解析錯誤。
- 不支援的 JSON 根欄位。
- 找不到 Codex Session 資料的位置。
- PowerShell Profile 路徑。

### cdaily

```powershell
cdaily
cdaily 30
```

預設最近 7 天，時區固定為 `Asia/Taipei`。

## 完整生命週期

### 備份

```powershell
./backup.ps1 -Mode Global
```

會備份：

- `~/.codex`
- `~/.agents/skills`
- 已登記 Git／CVS 專案清單
- PowerShell Profile
- ccusage 是否安裝及版本
- Context7 Key 是否存在的狀態

Context7 Key 本身不會寫入備份。

### 還原

```powershell
./restore.ps1
```

會還原設定、已登記專案清單、Profile 與 ccusage 原始安裝狀態。若備份時存在 Context7 Key，但目前已不存在，會提醒重新設定，不會從備份讀取秘密。

### 移除

```powershell
./uninstall.ps1 -Mode Global
./uninstall.ps1 -Mode Project -ProjectPath 'E:\Git\MyProject'
```

全域移除會：

- 只移除本套件管理的 AGENTS、Rules、TOML 與 Hooks 區塊。
- 保留使用者其他設定與已登記專案清單。
- 移除 Profile 中的 `cs`、`cdaily`。
- 還原安裝前的 ccusage 狀態及版本。
- 只在 Key 由本安裝器建立時移除 `CONTEXT7_API_KEY`。
- 備份所有即將移除或更新的內容。

專案設定完整移除且沒有剩餘受管理檔案時，會自動從登記清單移除該專案。若有使用者修改過的受管理檔案被保留，專案仍會維持登記。

## 全域 MCP

### Context7

```toml
[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
env_http_headers = { "CONTEXT7_API_KEY" = "CONTEXT7_API_KEY" }
```

全域安裝時可輸入 Context7 API Key。Key 以目前 Windows 使用者環境變數 `CONTEXT7_API_KEY` 儲存，不會寫入 Git、`config.toml`、Manifest 或備份。

已有使用者層 `CONTEXT7_API_KEY` 時會直接沿用。可使用以下參數略過輸入：

```powershell
./install.ps1 -Mode Global -SkipContext7Key
```

### Playwright

```toml
[mcp_servers.playwright]
command = "npx"
args = ["-y", "@playwright/mcp@latest"]
```

### Pencil

本套件不安裝、不偵測、也不修改 Pencil MCP。

## CVS 更新流程

CVS 專案規則要求每個目標依序執行：

1. `cvs status <target>`
2. `cvs -n update <target>`
3. 檢查衝突、錯誤與非預期變更
4. 必要且安全時執行 `cvs update <target>`
5. 再次執行 `cvs status <target>`

禁止無目標的根目錄 `cvs update`。遇到 `C`、非預期合併或不確定狀態時立即停止。

## CRLF Hook

CVS Hook 保持精簡，只處理：

- `.codex-root` 專案範圍內的普通檔案。
- 明確允許的文字副檔名。
- 不超過 10 MB 的檔案。
- 非符號連結、非 `CVS`／`.codex` 內部檔案。
- 不含 NUL 位元的文字內容。

暫存清單放在 `%LOCALAPPDATA%\CodexSettings\HookState`，超過 7 天會清理。Hook 失敗會輸出實際原因並回傳非零狀態。

安裝 CVS 設定後重新啟動 Codex，使用 `/hooks` 檢查並信任專案 Hook。

## Git 專案提交策略

Git 專案完成修改並通過相關驗證後，可自動 Stage 與 Commit 本次任務的檔案。

Commit Message：

```text
fix: <short description>
feat: <short description>
docs: <short description>
chore: <short description>
```

以下操作必須由使用者明確要求：

- Push 或 Force Push
- 建立或修改 Pull Request
- Merge
- Release
- Tag
- 刪除 Branch
- 遠端 Issue 修改

## 安全範圍

不備份或提交：

- `auth.json`
- API Key、Token、密碼
- Session、歷史紀錄與日誌
- Context7 或其他 MCP 的登入資訊
- 本機私有設定
