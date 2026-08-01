# Environment

- PHP 7.2
- MySQL 8.x
- Apache
- AWS Linux
- CVS

# Version Control

- This project uses CVS only.
- Do not use, run, or suggest Git or GitHub CLI commands.
- Use CVS read-only inspection first.
- Run CVS write operations only when explicitly required.

# Code Changes

- Modify only code directly related to the request.
- Preserve existing architecture, coding style, naming, structure, and backward compatibility.
- Maintain PHP 7.2 compatibility.
- Prefer minimal changes and do not refactor unless requested.
- Do not introduce frameworks, libraries, design patterns, or unrelated security logic.

# File Handling

- Use existing context first.
- Read only required files and sections.
- Start from the specified file, function, class, method, or line range.
- Follow direct dependencies only and expand incrementally.
- Detect and preserve the original encoding and CRLF/LF line endings.
- Files may contain Traditional Chinese, Simplified Chinese, English, Japanese, or Korean.
- For files larger than 1000 lines, inspect only the relevant section first.

# Database Changes

- Inspect the existing query, indexes, execution plan, and direct callers before changing SQL.
- Do not change schemas, indexes, transaction behavior, or data migration logic unless requested.
- Keep SQL compatible with MySQL 8.x and the existing PHP database layer.

# Final Response

- Output English only.
- Do not output unchanged code, analysis, diffs, command logs, or unrelated explanations.
- List each modified file as: `Updated <absolute Windows path>:1`.
- End with: `Note: <clear summary within 50 characters>`.
- If no files were modified, output: `No files modified.`
