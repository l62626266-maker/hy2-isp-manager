# Reliability repair implementation plan

> Execution: superpowers:executing-plans, inline implementation and one independent final review.

Goal: fix all concrete audit findings through consistent mutation, state and certificate boundaries; keep existing CLI and standalone distribution.
Architecture: stable cross-process flock outside replaceable state trees; atomic state publication; guard reads verified manager identity rather than duplicating it; certificate deployment uses explicit snapshot/commit/rollback and preserves stopped services.
Spec: user authorized complete local repair on 2026-10-29; no GitHub upload until explicit command.

## Constraints and decisions
- Reuse dev/terminal-ui-0.3.0 and preserve all pre-existing uncommitted work; no commit/push during this repair.
- Keep scripts standalone because published installers download one script; split responsibilities into named internal interfaces rather than introduce missing runtime modules.
- Preserve manual/mixed guard deployments; auto-sync identity only for verified manager-owned certificate paths and services.
- Backup is local configuration rollback, not host/ACME disaster recovery; document this boundary.
- Windows mock verification cannot establish live Linux/systemd/network correctness; add Linux CI checks and report this limit.

## Tasks
- [x] 1. Add failing reliability regressions: atomic write failure; failed firewall deletion; stopped-node port reservation; strict SAN; guard identity refresh; stopped service deployment; failed copy/rename/restart/signal rollback; expired UI; mutation locking.
- [x] 2. Manager mutation layer: with_mutation_lock, atomic write_env, checked firewall ledger updates, shared available-node-port validation; create/delete failure paths retain ownership records.
- [x] 3. Guard lifecycle: refresh managed identity, renewal-method-aware health checks, exact hostname validation, guarded transaction deployment with unique backups and checked rollback; shared lock and installer coexistence.
- [x] 4. Consistency/UX: atomic renewal hook with locking, expired UI and short-lived panel cache, clear unavailable traffic counters and backup scope; clean actionable lint and narrowly annotate genuine static-analysis limitations.
- [x] 5. Run all local regression suites, syntax and ShellCheck; add Linux concurrency CI coverage; independent review and fix material findings; document changes and verification.

## Review focus
- Shared lock survives restore deleting state directory and cannot deadlock parent issuance hooks.
- Old lineage renewal after manager domain migration cannot overwrite new certificate.
- A deliberately stopped node remains stopped on success and rollback.
- A partial file operation or signal retains complete recovery artifacts on rollback failure.
- No shell sourced from backup or manager identity sync without validating trust and fields.

## Progress
- Baseline: 11 shell suites green; syntax green; ShellCheck 0.10.0 fails; PTY skipped on Windows.
- Ruling: current dev checkout retained to avoid losing in-flight development; commits deferred so original work is not silently staged with this repair.
- Implementation: mutation lock, atomic state/file publication, fail-safe firewall ledger, stopped-node reservation, strict guard identity/deployment, managed renewal transaction and panel cache implemented.
- Independent review: one fresh reviewer found lock reentrancy, existing-certificate deployment omission, hook publication, installer hook ownership, background lock contention and firewall journal ordering; each addressed in the final repair pass.
- Review regressions: 20 focused reliability cases passed; manager renewal success/partial-write/restart-failure cases passed; Linux flock test is intentionally skipped on Windows and included in CI.
- Ruling: keep standalone script distribution and centralize internal interfaces; extracting runtime modules would break the pinned single-file installer contract without a separate packaging migration.
- Final verification: all 13 locally runnable shell suites passed; Linux-only locking suite and PTY test skipped on Windows; native symlink-specific UI case also skipped. Bash syntax and ShellCheck 0.10.0 passed; Git diff whitespace check and secret-pattern scan passed.
- Whole-suite run exposed six obsolete install() failure injections after atomic publication refactoring. Updated only their injection boundary to mv(), retained rollback assertions, reran the entire initial-certificate suite (29 cases) and all remaining suites successfully; all six fault markers were independently confirmed.
- Logs: .tmp/repair-complete.log (early suites), .tmp/repair-final-tail.log (updated initial suite and remaining suites), .tmp/repair-shellcheck-verified.log and .tmp/repair-shellcheck-adjusted-test.log.
- No Git staging, commit, push, release or VPS deployment performed.
