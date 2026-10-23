# Phase 1 — Assessment (Days 1–5)

**Goal:** a complete, validated inventory with per-server disposition (rehost / replatform / retire), wave assignment, Nitro readiness status, and RHEL licensing path — signed off before any AWS infrastructure is built.

**Phase exit gate:** all Day 1–5 DoD items met; `docs(assessment): phase 1 sign-off` merged to `main`.

---

## Day 1 — Access, tooling & repo bootstrap

**Estimated time:** 6 h (2 engineers)

### Tools

| Tool | Version | Where |
|---|---|---|
| AWS CLI | v2.x (latest) | Engineer workstations |
| Terraform | ≥ 1.10 | Engineer workstations + CI |
| Git + GitHub CLI (`gh`) | Git ≥ 2.40 | Engineer workstations |
| `shellcheck` | ≥ 0.9 | Workstations + CI |
| `jq` | ≥ 1.6 | Workstations |
| Ansible *(optional, for fleet SSH)* | ≥ 2.15 | Jump host |

### IAM / access prerequisites

- IAM Identity Center permission sets (no IAM users, no long-lived keys):
  - `MigrationEngineer` — `AWSApplicationMigrationFullAccess`, `AmazonEC2FullAccess` scoped by tag condition `Project=linux-aws-migration`, `AmazonSSMFullAccess`, `AWSLicenseManagerConsumptionPolicy`, read on `AWSCloudFormationReadOnlyAccess`.
  - `MigrationReadOnly` — `ReadOnlyAccess` (app owners, auditors).
- Terraform state bucket permissions (created Day 6) — `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on the state prefix.
- On-prem: `sudo` on all in-scope hosts via jump host; network team contact for firewall changes (TCP 443 + TCP 1500 outbound).
- Red Hat Customer Portal org admin (for Cloud Access, Day 4).

### Tasks

- [ ] Create GitHub repo, protect `main` (require PR + 1 review + status checks). *(30 min)*
- [ ] Commit this repo skeleton. *(15 min)*
- [ ] Configure Identity Center permission sets and assign the migration group to the workload account. *(1.5 h)*
- [ ] Verify CLI SSO login for every engineer. *(30 min)*
- [ ] Add CI workflow: `terraform fmt -check`, `terraform validate`, `shellcheck scripts/*.sh`. *(1.5 h)*
- [ ] Open firewall change request: on-prem source subnets → AWS (TCP 443 to MGN/S3 endpoints; TCP 1500 to staging subnet CIDR). Lead time is usually the critical path. *(30 min)*
- [ ] Confirm hybrid connectivity method (Site-to-Site VPN or Direct Connect) and Transit Gateway ID. *(1 h)*

```bash
# Workstation verification
aws --version
terraform version
aws configure sso --profile migration-prod
aws sts get-caller-identity --profile migration-prod
```

### Definition of Done

- [ ] Every engineer can run `aws sts get-caller-identity` via SSO against the workload account
- [ ] `main` is protected; CI runs on PRs
- [ ] Firewall change request ticket number recorded in README

**Commit:** `chore(repo): bootstrap migration repo, CI checks and access model`

---

## Day 2 — Discovery & inventory collection

**Estimated time:** 7 h

### Tools

| Tool | Purpose |
|---|---|
| AWS Migration Hub + Application Discovery Service (agentless collector for VMware, or Discovery Agent) | Utilization, network connections |
| Ansible ad-hoc or `ssh` loop | OS/kernel/package facts |
| `ss`, `lsof` | Listening ports / established connections |

### IAM

- `AWSApplicationDiscoveryServiceFullAccess`, `AWSMigrationHubFullAccess` on the `MigrationEngineer` set.
- Set Migration Hub home region once: `aws migrationhub-config create-home-region-control --home-region us-east-1 --target Type=ACCOUNT,Id=<ACCOUNT_ID>` (**irreversible per account — confirm region first**).

### Tasks

- [ ] Deploy ADS agentless collector (VMware) or Discovery Agent on hosts; collect ≥ 7 days of utilization (runs in background through Day 5). *(2 h)*
- [ ] Collect host facts into `inventory/raw/` (git-ignored) and a sanitized `inventory/hosts.csv`. *(2 h)*
- [ ] Capture listening ports and established connections per host for dependency mapping. *(1.5 h)*
- [ ] Record per-host: OS/version, kernel, vCPU/RAM, disk layout (LVM/partitions), boot mode (BIOS/UEFI), databases, app owner. *(1.5 h)*

```bash
# Fact collection (run from jump host). RHEL/CentOS and Ubuntu compatible.
for h in $(cat inventory/hostlist.txt); do
  ssh -o BatchMode=yes "$h" 'sudo bash -s' <<'EOF' > "inventory/raw/${h}.txt" 2>&1
echo "host=$(hostname -f)"
cat /etc/os-release 2>/dev/null || cat /etc/redhat-release
echo "kernel=$(uname -r)"
echo "cpus=$(nproc) mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)"
[ -d /sys/firmware/efi ] && echo "boot=UEFI" || echo "boot=BIOS"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
df -hT -x tmpfs -x devtmpfs
ss -tlnpH
ss -tnpH state established
command -v rpm >/dev/null && rpm -qa --qf '%{NAME}\n' | grep -Ei 'mysql|mariadb|postgres|oracle|java|httpd|nginx|tomcat' 
command -v dpkg >/dev/null && dpkg-query -W -f='${Package}\n' | grep -Ei 'mysql|mariadb|postgres|java|apache2|nginx|tomcat'
EOF
done
```

### Definition of Done

- [ ] 100 % of in-scope hosts present in `inventory/hosts.csv` with all required columns
- [ ] ADS collecting data for every host (Migration Hub → Servers shows "Collecting")
- [ ] Unreachable hosts listed with owner and resolution date

**Commit:** `docs(assessment): add sanitized inventory for <N> hosts`

---

## Day 3 — Dependency mapping, wave grouping, CentOS disposition

**Estimated time:** 6 h

### Tools

Migration Hub network diagram, spreadsheet/CSV, Day 2 `ss` output.

### Tasks

- [ ] Build application groups in Migration Hub from connection data; validate with app owners. *(2 h)*
- [ ] Assign waves: tightly coupled hosts (chatty, low-latency DB links) must share a wave. *(1.5 h)*
- [ ] Apply CentOS disposition rules (table below) to every CentOS host. *(1 h)*
- [ ] Identify databases to move to Amazon RDS via AWS DMS instead of MGN (managed-service preference) — tracked in a separate DMS runbook. *(1 h)*
- [ ] Populate wave table in README. *(30 min)*

| Source OS | Default disposition | Post-migration action |
|---|---|---|
| CentOS 6 | **Replatform** (rebuild on Rocky 9 / AL2023 via Terraform) | Data copied with `rsync`/app-native tooling |
| CentOS 7 | Rehost (MGN) as bridge | ELevate/Leapp → Rocky/Alma 8 → 9 on EC2 (Phase 3 Days 16–18) |
| CentOS 8 / Stream 8 | Rehost (MGN) | `migrate2rocky.sh -r` on EC2 |
| CentOS 7 needing vendor support | Rehost | `convert2rhel` → RHEL (BYOL) |
| RHEL 6 | Replatform to RHEL 9 gold image | — |
| RHEL 7/8/9 | Rehost (BYOL retained) | Leapp upgrade where < 8 |
| Ubuntu 18.04/20.04 | Rehost | `do-release-upgrade` post-cutover (20.04 standard support ended 2025-05) |
| Ubuntu 22.04/24.04 | Rehost | — |

### Definition of Done

- [ ] Every host has: wave ID, disposition, app owner sign-off
- [ ] No cross-wave dependency with latency sensitivity < 5 ms left unresolved
- [ ] DB-to-RDS candidates listed

**Commit:** `docs(assessment): record dependency map, waves and CentOS disposition`

---

## Day 4 — Nitro preflight + RHEL Cloud Access enrollment

**Estimated time:** 7 h

### Tools

`scripts/aws-nitro-preflight.sh`, Red Hat Hybrid Cloud Console, `subscription-manager`.

### IAM

- Red Hat org admin role in the Customer Portal.
- AWS: `ec2:DescribeImages` (to verify gold image share).

### Tasks

- [ ] Run preflight on every rehost host; store output in `preflight/raw/` and a summary CSV. *(2 h)*
- [ ] Classify results: exit 0 = ready, 1 = warnings (fix before Day 9), 2 = blocking. *(1 h)*
- [ ] Create remediation tickets for every exit-2 host (missing `nvme` in initramfs, `/dev/sdX` in fstab, missing ENA on EL7 < 7.4, EL6 ENA). *(1 h)*
- [ ] Enroll **each** workload AWS account ID in Red Hat Cloud Access (Org IDs are not supported); enable gold images. *(1 h)*
- [ ] Inventory RHEL subscriptions: count, type, Cloud Access eligibility; confirm no double-consumption during parallel run. *(1.5 h)*
- [ ] Verify gold images are shared (can take up to 24 h). *(30 min)*

```bash
# Run preflight via jump host
for h in $(cat inventory/wave0.txt); do
  scp -q scripts/aws-nitro-preflight.sh "$h":/tmp/
  ssh "$h" 'sudo bash /tmp/aws-nitro-preflight.sh' > "preflight/raw/${h}.log"; echo "$h exit=$?"
done | tee preflight/wave0-summary.txt
grep -h '^RESULT' preflight/raw/*.log
```

```bash
# Verify gold images are visible in the workload account
aws ec2 describe-images --owners 309956199498 \
  --filters "Name=is-public,Values=false" "Name=name,Values=RHEL-9*Access*" \
  --query 'sort_by(Images,&CreationDate)[-3:].[ImageId,Name]' --output table
```

```bash
# Record current subscription state on each RHEL source host
sudo subscription-manager status
sudo subscription-manager identity
sudo subscription-manager list --consumed | grep -E 'Subscription Name|SKU|Pool ID'
```

### Definition of Done

- [ ] Preflight result recorded for 100 % of rehost hosts
- [ ] Zero exit-2 hosts without a remediation ticket and owner
- [ ] Gold images visible via `describe-images` in every target account
- [ ] RHEL subscription count ≥ RHEL hosts migrating (or procurement ticket open)

**Commit:** `docs(assessment): add Nitro preflight results and RHEL Cloud Access status`

---

## Day 5 — Right-sizing, cost model, Phase 1 sign-off

**Estimated time:** 5 h

### Tools

Migration Hub EC2 recommendations (from ADS data), AWS Pricing Calculator, Compute Optimizer (post-migration).

### Tasks

- [ ] Export Migration Hub EC2 instance recommendations (P95 CPU/RAM, Nitro families only: m7i/m7g/c7i/r7i/t3). *(1.5 h)*
- [ ] Map each host to instance type + gp3 volume sizing (IOPS/throughput from ADS disk metrics). *(1.5 h)*
- [ ] Build cost estimate (On-Demand for first 30 days; Savings Plans decision after Compute Optimizer baseline). *(1 h)*
- [ ] Phase 1 review with app owners + security; record sign-off. *(1 h)*

> Graviton (`*g`) instances only apply to **replatformed** workloads rebuilt on arm64 AMIs — MGN rehost keeps x86_64.

### Definition of Done

- [ ] Every host has a target instance type and volume spec in `inventory/hosts.csv`
- [ ] Cost estimate link recorded
- [ ] Written sign-off (PR approval) from migration lead, security, and each wave's app owner

**Commit:** `docs(assessment): phase 1 sign-off with sizing and cost model`

---

## Phase 1 risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Firewall change lead time | Blocks Day 9 agent install | Raised Day 1; escalate by Day 4 |
| Undocumented dependencies | Post-cutover outages | ≥ 7 days ADS connection data + owner validation |
| Migration Hub home region set wrong | Cannot change per account | Confirm region in design review before Day 2 |
| Gold images not shared in time | RHEL rebuilds blocked | Enroll Day 4; 24 h buffer before Day 7 |

> Phase 1 makes **no production changes**; rollback = none required. Preflight is read-only.
