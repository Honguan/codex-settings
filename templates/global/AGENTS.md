# Communication

- Use Traditional Chinese unless the user explicitly requests another language.
- Keep responses concise, explicit, and focused on actions, results, and counts.

# Code Changes

- Modify only code directly related to the request.
- Preserve existing architecture, coding style, naming, structure, and backward compatibility.
- Prefer minimal changes.
- Do not refactor unless requested.
- Do not introduce new frameworks, libraries, or design patterns unless directly required.
- Do not add unrelated security checks or duplicate validation logic.

# File Handling

- Use existing conversation and project context first.
- Read only files and sections required for the task.
- Start from the requested function, method, class, file, or line range.
- Follow direct call relationships and required dependencies only.
- Expand incrementally instead of scanning the entire project.
- Detect and preserve file encoding and line endings.
- Assume files may contain Traditional Chinese, Simplified Chinese, English, Japanese, or Korean.
- For files larger than 1000 lines, inspect only the relevant section first.

# Validation

- Run only checks relevant to the modified code.
- Report actual failures and limitations without hiding them.
- Do not claim a task is complete unless the requested changes and checks were performed.
