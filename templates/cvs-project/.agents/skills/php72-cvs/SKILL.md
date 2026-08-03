---
name: php72-cvs
description: Use for focused maintenance of legacy PHP 7.2 and MySQL 8.x codebases managed with CVS. Do not use for Git repositories or broad refactors.
---

# PHP 7.2 CVS Workflow

1. Start from the requested file, function, method, class, or line range.
2. Read only direct callers, callees, inheritance, and required dependencies.
3. Detect the file encoding and line endings before editing.
4. Preserve PHP 7.2 syntax compatibility and the existing application architecture.
5. Inspect existing SQL, bindings, indexes, and execution plans before changing query logic.
6. Do not use Git or GitHub CLI.
7. Prefer CVS read-only commands before any write operation.
8. Never run or propose `cvs add`; leave new-file registration to the user.
9. Never run or propose manual CRLF conversion commands; the CVS PostToolUse Hook is the single line-ending normalizer.
10. Make the smallest change that satisfies the request.
11. Run only validation relevant to the modified code.
12. Report modified files, implemented logic, checks, and unresolved limitations.
