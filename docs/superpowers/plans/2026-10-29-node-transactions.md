# Node transaction and Linux validation plan

User approved execution of the four-step plan on 2026-10-29; retain existing remote branches/history and use codex/reliability-repair-20261029 for additive commits.

## Design
- One node transaction takes a node ID and explicit mutation callback, snapshots config/URI/state/unit and runtime/enablement before any mutation, and restores only runtime it touched. Preserve recovery artifacts when rollback cannot finish.
- Creation, ISP replacement, rename and explicit power actions use this boundary. All writes check status even in if/|| contexts; node records publish metadata atomically.
- Persist DESIRED_STATE and STOP_BOOT_ID. An intentional stop applies only to the current Linux boot ID, preserving existing reboot/autostart behavior. Legacy nodes default to running intent. Health suppresses only inactive intentional stops in the same boot, never failed units or unexpected stops.
- OpenSSL hostname validation requires an affirmative verdict, not just exit status; older OpenSSL can exit successfully for a mismatch. Manager and guard apply the same rule.
- No VPS deployment without an identified authorized target. Run full Linux GitHub CI by pushing verified changes to the existing repair branch; do not merge stable branches.

## Tasks
- [x] Reproduce zero-exit mismatch in both scripts and fix hostname verification; retain real-certificate tests.
- [x] Add failing create/replace/rename/power transaction fault-injection suite, implement common boundary and atomic record publication.
- [x] Add boot-scoped stop intent, backup schema compatibility and guard health tests.
- [x] Verify local suites/lint, independent review, push additive commits, inspect complete Linux CI and fix failures.

## Review focus
- Snapshot failures occur before service/firewall changes; late write errors/signals roll back files and runtime.
- New node rollback never removes pre-existing unrelated artifacts; rollback failure retains recovery materials.
- Replacement never enables or starts previously stopped nodes.
- Rename cannot leave state and URI names divergent.
- An old stop marker cannot hide a failure after reboot; legacy/manual guard targets stay checked.

## Ledger
- Baseline: 5cef8ff, clean worktree; remote Linux CI fails strict-certificate-domain despite Windows tests passing.
- Decision: retain standalone distribution and explicit internal interfaces; no new runtime package dependency.
- Ruling: port changes also use the shared node transaction, because their previous start_checked call reactivated stopped nodes; regression port_stopped reproduced the defect.
- Local certificate, node (10 cases), guard discovery/stop intent and existing functional suites pass; static annotations pending validation.

- Verification: original functional suites, 11 node transaction regressions, hostname mismatch, full guard health/discovery, Bash syntax, ShellCheck 0.10.0 and diff whitespace all pass locally.
- Final review: independent gpt-6-astra read-only review found no Critical/Important items; Linux CI remains the completion gate.
- Final: minor (deferred): interrupted writes may leave protected .install/.state temporary files outside the transaction snapshot directory; these do not replace live configuration. Track cleanup refinement separately.
- Final: Ruling: real VPS/systemd/UFW validation remains outside this run because no authorized target exists; simulated systemctl cannot prove host-level networking.

- Completion: commit 4c157a0 pushed additively; Linux CI https://github.com/l62626266-maker/hy2-isp-manager/actions/runs/40854190011 succeeded in every step, including actual flock competition, PTY and pinned Hysteria direct/ISP smoke. No original branches or tracked files deleted; main/dev branch SHAs unchanged.
