# Git Project Rules

These rules supplement the global rules.

## Repository Safety

- This project uses Git.
- Inspect repository status and relevant diffs before modifying files.
- Modify only files required by the request.
- Preserve the existing branch strategy, architecture, style, naming, and compatibility.
- Do not rewrite history, force-push, delete branches, or discard unrelated local changes.
- Do not commit generated files, credentials, local configuration, temporary files, logs, caches, backups, vendor files, or unrelated changes.

## Validation and Commit

- Run the smallest relevant validation after completing the requested changes.
- After validation succeeds, Codex may stage and commit only files directly related to the completed request.
- Do not create an empty commit when no file changed.
- If staging or committing fails, report the actual error and stop without discarding the working tree or index.
- Use one of these commit-message formats:
  - Bug fix: `fix: <short description>`
  - New feature: `feat: <short description>`
  - Documentation: `docs: <short description>`
  - Maintenance or settings: `chore: <short description>`

## Issue Completion Workflow

- When fixing a GitHub Issue, read its number, title, body, acceptance criteria, and relevant comments before changing code.
- Complete the fix and relevant validation before staging. If validation fails, do not commit or close the Issue.
- Stage and commit only files related to that Issue. The commit body must contain `Fixes #<issue-number>`; avoid combining unrelated Issues in one commit.
- Close the Issue only after the fixing commit is on the default branch. A commit on a feature branch must leave the Issue open until it is merged.
- After an authorized push to the default branch, verify that GitHub closed the Issue. If automatic closing fails, report the error instead of claiming completion.
- Add at most one concise completion comment containing the commit hash and validation summary. Before repeating the workflow, check the existing commit and Issue state to avoid duplicate commits, comments, or close operations.

## Explicit Authorization Required

- Never push, force-push, open or modify a pull request, merge, publish a release, create a tag, delete a branch, or modify remote issues unless the user explicitly requests that action.
- A request to modify code authorizes local staging and commit after successful validation, but does not authorize any remote write.

## Final Response

- Use Traditional Chinese unless another language is explicitly requested.
- List modified files and summarize the implemented logic.
- Report validation results and any remaining limitations.
- Include the commit hash when a local commit was created.
