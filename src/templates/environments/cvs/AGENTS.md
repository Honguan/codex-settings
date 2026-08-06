# CVS Project Rules

These rules supplement the global rules.

## Environment

- PHP 7.2
- MySQL 8.x
- Apache
- AWS Linux
- CVS / CVSNT

## Version Control

- This project uses CVS only.
- Do not use, run, mention, or suggest Git or GitHub CLI commands.
- Run CVS commands outside the sandbox using the Windows user's saved CVSNT credentials.
- Never expose or place CVS credentials in commands, logs, prompts, environment variables, sandbox files, or repository files.
- Always specify an explicit CVS file or directory target.
- Never run an unscoped `cvs update` from the repository root.
- Never run, propose, schedule, or mark `cvs add` as completed.
- Leave new files untracked and report CVS addition as a user-managed follow-up.
- CRLF normalization is owned exclusively by the global `~/.codex/hooks/normalize-cvs-crlf.ps1` Hook.
- Never run or propose a manual line-ending conversion command; rely on the PostToolUse Hook after edits.
- Begin with read-only inspection and use the smallest target required by the request.

## CVS Update

For every target, use this sequence:

1. Run `cvs status <target>`.
2. Run `cvs -n update <target>`.
3. Review the complete preview for conflicts, errors, unexpected merges, removals, additions, or unrelated files.
4. Run `cvs update <target>` only when the preview is expected and the operation is required by the request.
5. Run `cvs status <target>` again.

Stop immediately when the preview or result contains `C`, an error, an unexpected merge, an unrelated file, or any uncertain state. Do not overwrite, revert, resolve, retry with destructive options, or continue without explicit user instructions.

## CVS Commit

- Never run `cvs commit` or `cvs ci` without explicit user approval.
- Before committing, inspect `cvs status` and `cvs diff` for every approved file.
- Commit only the exact approved files and always provide explicit file targets.
- Do not include unrelated, generated, temporary, cache, log, backup, vendor, or build files.
- If a commit fails or reports an uncertain state, report the actual error and stop.

## PHP 7.2 Workflow

- Start from the requested file, function, method, class, or line range.
- Read only direct callers, callees, inheritance, and required dependencies.
- Detect the file encoding and line endings before editing.
- Preserve PHP 7.2 syntax compatibility and the existing application architecture.
- Inspect existing SQL, bindings, indexes, and execution plans before changing query logic.
- Prefer CVS read-only commands before any write operation.
- Never run or propose `cvs add`; leave new-file registration to the user.
- Never run or propose manual CRLF conversion commands; the CVS PostToolUse Hook is the single line-ending normalizer.
- Make the smallest change that satisfies the request.
- Run only validation relevant to the modified code.
- Report modified files, implemented logic, checks, and unresolved limitations.

## Database Changes

- Inspect the existing query, indexes, execution plan, and direct callers before changing SQL.
- Do not change schemas, indexes, transaction behavior, or migration logic unless requested.
- Keep SQL compatible with MySQL 8.x and the existing PHP database layer.

## Final Response

- Use Traditional Chinese only unless the user explicitly requests another language.
- Keep technical names, commands, file paths, and CVS status values in their original form.
- List each modified file as a Markdown link using the file name as the label and the absolute Windows path as the target.
- End with: `備註：<50 字內摘要>`.
