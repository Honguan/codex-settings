# Communication

- Use Traditional Chinese unless the user explicitly requests another language.
- Keep responses concise, explicit, and focused on actions, results, and counts.

# Code Changes

- Modify only code directly related to the request.
- Preserve existing architecture, coding style, naming, and structure unless current requirements change them.
- Prefer minimal changes.
- Do not refactor unless requested.
- Do not introduce new frameworks, libraries, or design patterns unless directly required.
- Do not add unrelated security checks or duplicate validation logic.

# Architecture

- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

# File Handling

- Use existing conversation and project context first.
- Read only files and sections required for the task.
- Start from the requested function, method, class, file, or line range.
- Follow direct call relationships and required dependencies only.
- Expand incrementally instead of scanning the entire project.
- Detect and preserve file encoding and line endings.
- Assume files may contain Traditional Chinese, Simplified Chinese, English, Japanese, or Korean.
- For files larger than 1000 lines, inspect only the relevant section first.

## Line endings

Preserve each file's original CRLF or LF format. Never introduce mixed line endings.

# Validation

- Run only checks relevant to the modified code.
- Report actual failures and limitations without hiding them.
- Do not claim a task is complete unless the requested changes and checks were performed.
