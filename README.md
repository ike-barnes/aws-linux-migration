# Linux Estate → AWS Migration

Rehost (AWS MGN) and replatform of the on-premises RHEL / Ubuntu / CentOS estate onto Amazon EC2, aligned to AWS CAF and the Well-Architected Framework.

| Item | Value |
|---|---|
| Migration tool | AWS Application Migration Service (MGN) — block-level continuous replication |
| IaC | Terraform ≥ 1.10, AWS provider `~> 6.0` (`terraform/`) |
| Ops plane | AWS Systems Manager (Session Manager, Run Command, Patch Manager) — **no inbound SSH** |
| RHEL licensing | BYOL via Red Hat Cloud Access (gold images); license-included AMIs blocked by SCP |
| CentOS disposition | Rehost as bridge → ELevate / `migrate2rocky` on EC2, or rebuild on Rocky 9 / AL2023 |
| Encryption | EBS default encryption with customer-managed KMS key; TLS 1.2+ for all replication |

> **Practice-lab edition.** The "on-prem" estate is three VirtualBox VMs built in [Phase 0](docs/phase0-lab-setup.md) (RHEL 9, Ubuntu 22.04, CentOS 7 running a two-tier PHP + MariaDB app). AWS runs in `lab_mode` to keep costs low. Every procedure is the same one used in an enterprise migration; the [lab deviations table](docs/phase0-lab-setup.md#how-the-lab-changes-phases-13) lists the few differences. **Run the teardown when finished.**

---

## Repository layout

```text
.
├── .github/
│   ├── PULL_REQUEST_TEMPLATE.md   # Peer review gate for every migration change
│   └── workflows/ci.yml           # fmt/validate Terraform, shellcheck, yamllint
├── docs/
│   ├── phase0-lab-setup.md        # Lab Days L1–L3: build the VirtualBox "on-prem" servers
│   ├── phase1-assessment.md       # Days 1–5: tooling, discovery, sizing, licensing
│   ├── phase2-replication.md      # Days 6–12: landing zone, MGN, sync, test launch
│   └── phase3-cutover-runbook.md  # Days 13–20: hour-by-hour cutover, rollback, modernization
├── inventory/
│   ├── hosts-template.csv         # Column definitions + example rows
│   └── hosts.csv                  # The lab estate (fill in from collect-facts.sh)
├── scripts/
│   ├── collect-facts.sh           # Prints one inventory CSV row per server (read-only)
│   ├── aws-nitro-preflight.sh     # ENA/NVMe/initramfs/fstab readiness check (read-only)
│   └── 90-aws-ena.yaml            # Ubuntu 22.04 Netplan for post-cutover ENA (ens5)
├── terraform/                     # Target AWS infrastructure (workload account)
│   ├── lab.tfvars.example         # lab_mode = true: no NAT/endpoints, budget alerts
│   ├── env/prod.s3.tfbackend.example
│   └── org/                       # SCP guardrails (apply from management account)
└── README.md
```

---

## Wave plan

| Wave | Servers | OS mix | Disposition | Cutover window | Owner |
|---|---|---|---|---|---|
| 0 – Pilot | `app01.lab.local` | Ubuntu 22.04 | Rehost | `<YYYY-MM-DD 19:00 ET>` | `<you>` |
| 1 | `web01.lab.local` + `db01.lab.local` (web01 → db01:3306, must move together) | RHEL 9, CentOS 7 | Rehost; db01 then ELevate → Rocky 8 | `<YYYY-MM-DD 19:00 ET>` | `<you>` |

> Lab rule of thumb: schedule wave 1 at least 3 days after wave 0 so lessons from the pilot are applied.

---

## Timeline (day-by-day)

Each day's detailed steps, tools, IAM, Definition of Done (DoD), and rollback live in the linked phase doc. Tick a day only when **every** DoD item in the phase doc is met.

### Phase 0 — Build the practice lab ([docs/phase0-lab-setup.md](docs/phase0-lab-setup.md))

- [ ] **Lab Day L1** — VirtualBox network, ISO downloads, Red Hat Developer account *(~3 h)*
- [ ] **Lab Day L2** — Build `centos7-db01` (MariaDB) and `rhel9-web01` (Apache + PHP) *(~4 h)*
- [ ] **Lab Day L3** — Build `ubuntu22-app01`, capture inventory, baseline snapshots *(~3 h)*

### Phase 1 — Assessment ([docs/phase1-assessment.md](docs/phase1-assessment.md))

- [ ] **Day 1** — Access, tooling & repo bootstrap *(~6 h)*
- [ ] **Day 2** — Discovery & inventory collection *(~7 h)*
- [ ] **Day 3** — Dependency mapping, wave grouping, CentOS disposition *(~6 h)*
- [ ] **Day 4** — Nitro preflight + RHEL Cloud Access enrollment *(~7 h)*
- [ ] **Day 5** — Right-sizing, cost model, Phase 1 sign-off *(~5 h)*

### Phase 2 — Landing zone & replication ([docs/phase2-replication.md](docs/phase2-replication.md))

- [ ] **Day 6** — Terraform backend + VPC / endpoints *(~6 h)*
- [ ] **Day 7** — KMS, security groups, IAM, SCP guardrails *(~5 h)*
- [ ] **Day 8** — MGN initialization & replication/launch templates *(~4 h)*
- [ ] **Day 9** — Source remediation + MGN agent install (wave) *(~6 h)*
- [ ] **Day 10** — Initial sync monitoring & lag tuning *(elapsed: data-dependent)*
- [ ] **Day 11** — Test launch & functional validation; lower DNS TTLs *(~7 h)*
- [ ] **Day 12** — Go/No-Go, mark Ready for Cutover, freeze *(~3 h)*

### Phase 3 — Cutover & post-migration ([docs/phase3-cutover-runbook.md](docs/phase3-cutover-runbook.md))

- [ ] **Day 13** — Pre-cutover checks (T-24h) *(~3 h)*
- [ ] **Day 14** — Production cutover window *(4–6 h window)*
- [ ] **Day 15** — Hypercare day 1, finalize cutover *(~6 h)*
- [ ] **Days 16–18** — CentOS modernization (ELevate / migrate2rocky) *(~4 h/server)*
- [ ] **Day 19** — Ops handover: patching, backup, monitoring baselines *(~5 h)*
- [ ] **Day 20** — Close-out; schedule source decommission (T+14d soak) *(~3 h)*

---

## Commit convention

[Conventional Commits](https://www.conventionalcommits.org/) with scope = phase or component.

```text
<type>(<scope>): <imperative summary ≤ 72 chars>

<body: what changed and why>
Refs: <ticket-id>
Wave: <wave-id>            # when applicable
Rollback: <one-line rollback or "n/a">
```

| Type | Use for |
|---|---|
| `feat` | New infra or capability (`feat(network): deploy target VPC and endpoints`) |
| `fix` | Remediation of a defect (`fix(preflight): add nvme to dracut on wave1 hosts`) |
| `docs` | Runbooks, discovery data (`docs(assessment): record wave1 dependency map`) |
| `chore` | Tooling, CI, state ops (`chore(terraform): bump aws provider to 6.x`) |
| `ops` | Executed operational milestone (`ops(cutover): complete wave0 production cutover`) |

Branching: `main` is protected; one branch per day/milestone (`phase2/day06-vpc`); PR uses the template in `.github/`.

---

## Escalation & contacts

| Role | Name | Contact |
|---|---|---|
| Migration lead | `<name>` | `<phone/Slack>` |
| App owner (per wave) | `<name>` | `<…>` |
| Network / DNS | `<name>` | `<…>` |
| AWS Support | Enterprise/Business case | Console → Support |
| Red Hat Support | `<account #>` | access.redhat.com |
