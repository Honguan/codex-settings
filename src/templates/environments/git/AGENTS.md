# Git Project Rules

These rules supplement the global rules.

## Repository Safety

- This project uses Git.
- Inspect repository status and relevant diffs before modifying files.
- Modify only files required by the request.
- Preserve the existing branch strategy, architecture, style, naming, and compatibility.
- Do not rewrite history, force-push, delete branches, or discard unrelated local changes.
- Do not commit generated files, credentials, local configuration, temporary files, logs, caches, backups, vendor files, or unrelated changes.

## Issue Branch Workflow

- When fixing a GitHub Issue, first update the local `main` from `origin/main` with a fast-forward-only pull.
- Create the working branch from that updated `main` using `issue/<issue-number>-<short-description>`.
- Never modify or commit an Issue fix directly on `main`, and never branch an Issue fix from another Issue branch.
- Keep one primary Issue per branch and keep unrelated changes out of the branch.

## Pull Request and Main Verification

- Open every Issue branch PR with `main` as the base and the `issue/<issue-number>-<short-description>` branch as the head.
- The PR title or at least one commit must contain the Issue number.
- Before merge, the PR body must contain `Refs #<issue-number>` and must not contain `Fixes`, `Closes`, or `Resolves` for that Issue.
- Merge only after the Issue acceptance criteria, relevant tests, CI, clean working tree, and complete PR diff have been verified.
- After merge, update local `main` with `git pull --ff-only origin main`, verify the merge commit, files, CI, and acceptance criteria, and record `Branch`, `PR`, `Merge commit`, `Main verification`, and `Tests` in the Issue.
- Close the Issue only after that main-branch verification succeeds. If verification fails, keep the Issue open and continue on a follow-up Issue branch.

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
- Keep the PR body and final merge message on `Refs #<issue-number>` until main-branch verification is complete; do not use an automatic-closing keyword in the PR.
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
