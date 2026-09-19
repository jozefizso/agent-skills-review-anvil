# review-anvil — Fix Application (commit_mode=per_fix only)

Read before making any edit in Loop Mechanics §4 of the engine SKILL.md.

Make the edits as the orchestrator. Commit one logical fix-group per commit, conventional-commit style: `fix(area):` correctness, `refactor(area):` maintainability/simplicity, `test(area):` tests, `chore(area):` production-readiness.

#### Auto-fix policy (proportionality rules)

1. **Severity gate.** Auto-fix only at severity ≥ `min_fix_severity`. Below-gate findings land under "Suggestions". Exception: an obvious one-line fix at any severity may be applied without bumping severity.
2. **No new dependencies (default).** A fix introducing a new import, package, or subsystem is deferred with reason `introduces new dependency: <X>` even above the gate; `allow_new_deps: true` opts in. Don't grow the architecture without permission.
3. **Round size cap.** A round's fixes may grow the target file by at most ~50% of its starting line count or 200 lines, whichever is larger; apply highest-severity first, defer the rest with `round size cap reached`.

Noise/false positives are also **deferred** with a one-line reason — never silently dropped.

#### Legacy compatibility guardrails

- Write shared application code in PHP 5.3 syntax. PHP 5.6-only syntax is
  allowed only in a path proven to run exclusively on PHP 5.6. Never introduce
  PHP 7+ syntax, scalar/return types, null coalescing, spaceship comparisons,
  anonymous classes, `Throwable`, or modern-only standard-library APIs.
- Preserve the repository's established database access layer. Prefer its
  parameterized-query path and correct connection charset. Do not turn a local
  fix into an unrequested PDO/`mysqli`, framework, ORM, or migration-system
  rewrite.
- Keep SQL and migrations valid on both MySQL 5.7 and 8.0. Avoid 8.0-only SQL
  on shared paths, quote identifiers consistently, and account for deployed SQL
  modes, collations, authentication/client limits, DDL commits, locks, and
  mixed-version rollout.
- A compatibility fix is incomplete if it makes one supported matrix target
  pass by breaking another. Prefer the smallest behavior-preserving change.

#### Build/test gate (`verify_cmd`)

Fix commits must not leave the branch red. In `per_fix`:

- **Resolve:** explicit `verify_cmd` → use it; `verify_cmd: none` → record `Verification: skipped (user)`; unset → auto-detect repository docs, Composer scripts, `phpunit.xml*`, a `Makefile` test target, or the existing matrix command. Nothing found → record `Verification: none detected` and proceed only for findings not dependent on runtime/database proof.
- **Matrix:** lint every changed PHP file with PHP 5.3 and PHP 5.6, then run the relevant test/migration/query checks against MySQL 5.7 and 8.0 when the changed path supports both. Repository-proven version-specific paths may use their narrower targets. Never report the full matrix as passed from one PHP runtime, one MySQL server, MariaDB, SQLite, or static inspection alone.
- **Unavailable target:** name the missing runtime/database in the round summary. Revert a compatibility-dependent fix that cannot pass its required target and defer its finding with `required PHP/MySQL matrix target unavailable`; do not label it verified. Missing matrix proof blocks adaptive continuation based on that fix.
- **Baseline:** run the resolved syntax/test matrix once before round 1; if already failing, gate only on *new* failures and record the round state as `pre-existing failures (no new)`.
- **Gate each round:** run the same matrix after the round's fixes. On a new failure: one fix-forward attempt if the cause is obvious (`fix(<area>): repair <verify_cmd> failure from round <N> fixes`), else `git revert --no-edit` the round's fix commits and defer the findings with `fix failed verification`. If the revert itself fails to restore the baseline, stop the loop and surface it (same handling as a failed `git commit`). A round never ends with the gate newly red.

