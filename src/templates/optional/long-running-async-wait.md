# Long-running asynchronous work

For genuinely long-running asynchronous work:

- Empty `write_stdin` polls MUST use `yield_time_ms >= 180000`; prefer `300000` when intermediate output is not needed.
- `functions.wait` MUST use `yield_time_ms >= 180000`.
- `functions.exec` MUST set its outer `@exec yield_time_ms` at least 30000 ms longer than the longest nested tool wait, so the outer code cell does not yield first.
- Do not apply the long wait to non-empty `write_stdin` calls that send interactive input.
- These tools return early when the process or cell completes. Do not wake the model merely to report that work is still running.
- Do not apply these long waits to short or synchronous work.

This managed policy applies to new Codex sessions/tasks; already-running sessions are not guaranteed to reload it.
