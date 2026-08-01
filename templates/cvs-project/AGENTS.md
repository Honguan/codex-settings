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

## Code Changes

- Modify only code directly related to the request.
- Preserve existing architecture, coding style, naming, structure, and backward compatibility.
- Maintain PHP 7.2 compatibility.
- Prefer minimal changes and do not refactor unless requested.
- Do not introduce frameworks, libraries, design patterns, or unrelated security logic.

## File Handling

- Use existing context first.
- Read only required files and sections.
- Start from the specified file, function, class, method, or line range.
- Follow direct dependencies only and expand incrementally.
- Detect and preserve the original encoding, BOM state, and CRLF/LF line endings.
- Files may contain Traditional Chinese, Simplified Chinese, English, Japanese, or Korean.
- For files larger than 1000 lines, inspect only the relevant section first.

## Database Changes

- Inspect the existing query, indexes, execution plan, and direct callers before changing SQL.
- Do not change schemas, indexes, transaction behavior, or migration logic unless requested.
- Keep SQL compatible with MySQL 8.x and the existing PHP database layer.

## Final Response

- Output English only.
- Do not output unchanged code, analysis, diffs, command logs, or unrelated explanations.
- List each modified file as: `Updated <absolute Windows path>:1`.
- End with: `Note: <clear summary within 50 characters>`.
- If no files were modified, output: `No files modified.`
