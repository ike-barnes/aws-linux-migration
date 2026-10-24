# Engineering Log

Problems hit during the migration project, how each was diagnosed, and what changed. Newest first.

| # | Date | Area | Summary | Commit |
|---|---|---|---|---|
| 001 | 2026-10-24 | CI / Bash | ShellCheck SC2045 blocked the first pipeline run; replaced `ls` iteration with a glob | `5486085` |

---

## 001 — CI quality gate caught an unsafe loop in the Nitro preflight script

**Date:** 2026-10-24 · **Area:** CI/CD, Bash · **Severity:** Low (lint gate; no production impact) · **Commit:** `5486085`

### Context

The repository's GitHub Actions pipeline (`.github/workflows/ci.yml`) gates every push and pull request on three checks:

| Job | What it enforces |
|---|---|
| `terraform (terraform)` | `terraform fmt -check`, `init -backend=false`, `validate` for the workload stack |
| `terraform (terraform/org)` | Same for the Organizations SCP stack |
| `shell` | `shellcheck -S warning` on `scripts/*.sh`, `yamllint` on `scripts/*.yaml` |

`scripts/aws-nitro-preflight.sh` is a read-only readiness check run on source servers before an AWS MGN cutover. It verifies ENA/NVMe drivers, initramfs contents, fstab device naming and NIC MAC pinning.

### Symptom

Run #1 (initial commit `4b0a4ff`): both Terraform jobs passed; the `shell` job failed.

```text
In scripts/aws-nitro-preflight.sh line 150:
  for k in $(ls /lib/modules 2>/dev/null); do
           ^-- SC2045 (error): Iterating over ls output is fragile. Use globs.
Error: Process completed with exit code 1.
```

### Root cause

The loop that checks every installed kernel's initramfs iterated over the output of `ls /lib/modules`. Command substitution word-splits on whitespace and expands glob characters, so a directory name containing a space or `*` would be split or mangled. `ls` output is meant for humans, not for parsing. Kernel directory names normally contain neither, but on a server you have never seen, that's an assumption you shouldn't make.

### Fix

Iterate with a shell glob, guard against the no-match case, and derive the kernel version from the path:

```diff
-  for k in $(ls /lib/modules 2>/dev/null); do
+  for kdir in /lib/modules/*/; do
+    [ -d "$kdir" ] || continue
+    k="$(basename "$kdir")"
     [ "$k" = "$KVER" ] && continue
```

- `/lib/modules/*/` matches directories only and never word-splits.
- `[ -d "$kdir" ] || continue` handles an empty directory, where an unmatched glob stays as the literal string `/lib/modules/*/`.

### Verification

- `shellcheck -S warning scripts/*.sh` passes locally (ShellCheck 0.10.0).
- `bash -n` syntax check passes.
- Line endings confirmed LF after editing on Windows. CRLF would break the script on Linux, which is now enforced by `.gitattributes`.
- CI run #2 on `5486085`: see the badge in the README.

### Lessons

1. **Lint gates pay off on the first commit.** The defect was caught before the script ever ran on a server.
2. **Never parse `ls`.** Use globs, `find -print0`, or `while read -r` with controlled input.
3. **Editing Linux scripts on Windows needs guardrails.** Folder ownership (created from an elevated shell) and line endings both caused friction. Fixed with `icacls` and `.gitattributes`.
