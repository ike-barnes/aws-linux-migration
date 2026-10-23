# Phase 3 — Cutover Runbook & Post-Migration (Days 13–20)

**Goal:** move production traffic to EC2 within the approved window with a tested rollback path, then stabilize, modernize CentOS, hand over to operations, and schedule source decommission.

**Point of no return:** `aws mgn finalize-cutover` (Day 15). Before it, rollback to the on-prem source is a DNS flip plus data reconciliation. After it, MGN replication is gone and rollback requires manual reverse migration.

### Common variables

```bash
export AWS_PROFILE=migration-prod
export AWS_REGION=us-east-1
export WAVE=wave0
export ZONE_ID=<ROUTE53_ZONE_ID>
# One line per server: <source_server_id> <onprem_host> <app_service_units>
cat > cutover/${WAVE}-servers.txt <<'EOF'
s-1111111111111111 app01.corp.example.com httpd,app-backend
s-2222222222222222 app02.corp.example.com nginx
EOF
```

---

## Day 13 — Pre-cutover checks (T-24h)

**Estimated time:** 3 h

### Tools

AWS CLI, `dig`, SSM Session Manager plugin, on-prem backup console, bridge call tool.

### IAM

`MigrationEngineer` (MGN, EC2, SSM), `route53:ChangeResourceRecordSets` on `$ZONE_ID`, on-prem `sudo`.

### Tasks

- [ ] Replication: every wave server `CONTINUOUS`, lag ≤ 1 min. *(15 min)*
- [ ] DNS TTL = 60 s visible from on-prem and VPC resolvers. *(15 min)*
- [ ] Verify cutover/rollback JSON change sets match current records (no drift since Day 12). *(30 min)*
- [ ] Confirm fresh on-prem backups (≤ 24 h) for every wave host. *(30 min)*
- [ ] EC2 Serial Console enabled; break-glass local account tested on test launch. *(30 min)*
- [ ] Send stakeholder comms: window, expected downtime, bridge link, rollback criteria. *(30 min)*
- [ ] Confirm roles: cutover lead, executor, validator per app, DNS operator, scribe. *(15 min)*

```bash
aws mgn describe-source-servers \
  --query 'items[].[sourceProperties.identificationHints.hostname,lifeCycle.state,dataReplicationInfo.dataReplicationState,dataReplicationInfo.lagDuration]' \
  --output table
dig +noall +answer app01.corp.example.com
aws ec2 get-serial-console-access-status
```

### Definition of Done

- [ ] All checks green and recorded in the PR for this wave
- [ ] Comms sent; bridge scheduled

**Commit:** `docs(cutover): ${WAVE} T-24h readiness checks`

---

## Day 14 — Production cutover window

**Window:** `<YYYY-MM-DD 22:00–04:00 ET>` · **Expected user-facing downtime:** 30–60 min per application (writes stopped → DNS switched)

### Tools

AWS CLI, SSM plugin, `dig`, `ssh` to on-prem, app smoke-test scripts.

### Rollback decision criteria (any one → rollback)

- Instance fails to boot or is unreachable via SSM/Serial Console within 30 min of launch
- Any P1 functional test fails and is not fixable by T+120m
- Data integrity check (row counts / checksums) mismatch
- App owner withholds sign-off at the T+150m hold point

### Hour-by-hour

| Time | Step | Owner | Est. |
|---|---|---|---|
| T-60m | Open bridge, roll call, final lag check | Cutover lead | 15 min |
| T-45m | Put apps in maintenance mode; stop inbound at LB/firewall | App owner | 15 min |
| T-30m | Stop app services on source; confirm no writes | Executor | 15 min |
| T-15m | Wait for final blocks to replicate; lag = 0 | Executor | 15 min |
| T+0 | `start-cutover` | Executor | 5 min |
| T+5m – T+35m | MGN conversion + launch (STOPPED) → start instances | Executor | 30 min |
| T+35m – T+75m | Technical validation | Validator | 40 min |
| T+75m | **DNS switch** | DNS operator | 10 min |
| T+85m – T+150m | Functional validation, data integrity, monitoring | App owner | 65 min |
| T+150m | **Hold point: Go / Rollback** | Cutover lead | 10 min |
| T+160m – T+180m | Close window, comms, disable maintenance mode | Cutover lead | 20 min |

### Step 1 — Stop source writes (T-30m)

```bash
# On each on-prem source (RHEL/CentOS 7+ and Ubuntu use systemd)
while read -r SRC HOST UNITS; do
  ssh "$HOST" "sudo systemctl stop ${UNITS//,/ } && sudo systemctl is-active ${UNITS//,/ } || true"
done < cutover/${WAVE}-servers.txt
# CentOS/RHEL 6 (SysV): ssh "$HOST" 'sudo service httpd stop'
```

```bash
# Flush filesystem buffers so the final blocks are replicated
while read -r SRC HOST UNITS; do ssh "$HOST" 'sudo sync'; done < cutover/${WAVE}-servers.txt
watch -n 30 "aws mgn describe-source-servers --query 'items[].[sourceProperties.identificationHints.hostname,dataReplicationInfo.lagDuration]' --output table"
```

### Step 2 — Launch cutover instances (T+0)

```bash
IDS=$(awk '{print $1}' cutover/${WAVE}-servers.txt | xargs)
aws mgn start-cutover --source-server-i-ds $IDS --query 'job.jobID' --output text | tee cutover/${WAVE}-job.txt
aws mgn describe-jobs --filters jobIDs=$(cat cutover/${WAVE}-job.txt) \
  --query 'items[0].participatingServers[].[sourceServerID,launchStatus,launchedEc2InstanceID]' --output table
```

```bash
# Launch disposition is STOPPED: start once all are LAUNCHED
INSTANCES=$(aws mgn describe-jobs --filters jobIDs=$(cat cutover/${WAVE}-job.txt) \
  --query 'items[0].participatingServers[].launchedEc2InstanceID' --output text)
aws ec2 start-instances --instance-ids $INSTANCES
aws ec2 wait instance-status-ok --instance-ids $INSTANCES
```

### Step 3 — Technical validation (T+35m)

```bash
for i in $INSTANCES; do
  aws ssm describe-instance-information --filters Key=InstanceIds,Values=$i \
    --query 'InstanceInformationList[0].[InstanceId,PingStatus,PlatformName,PlatformVersion]' --output text
done
```

```bash
# Inside each instance (aws ssm start-session --target <i-xxx>)
lsblk -o NAME,TYPE,SIZE,MOUNTPOINT | grep nvme
ethtool -i ens5 | grep -E 'driver|version'
findmnt --verify && systemctl --failed --no-legend
sudo systemctl start <app units> && sudo systemctl is-active <app units>
# RHEL: BYOL subscription still valid
sudo subscription-manager status
# Ubuntu: networkd owns ens5
networkctl status ens5 | grep -E 'State|Address'
```

```bash
# Confirm BYOL billing on RHEL targets (RunInstances = BYOL, RunInstances:0010 = license-included)
aws ec2 describe-instances --instance-ids $INSTANCES \
  --query 'Reservations[].Instances[].[InstanceId,PlatformDetails,UsageOperation]' --output table
```

### Step 4 — DNS switch (T+75m)

```bash
# dns/cutover-app01.json (prepared Day 12)
# {"Comment":"wave0 cutover","Changes":[{"Action":"UPSERT","ResourceRecordSet":{
#   "Name":"app01.corp.example.com","Type":"A","TTL":60,"ResourceRecords":[{"Value":"<EC2_PRIVATE_IP>"}]}}]}
for f in dns/cutover-${WAVE}-*.json; do
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$f" \
    --query 'ChangeInfo.Id' --output text | xargs -I{} aws route53 wait resource-record-sets-changed --id {}
done
dig +noall +answer app01.corp.example.com @<onprem-dns>
dig +noall +answer app01.corp.example.com @169.254.169.253   # from inside VPC
```

> **On-prem AD/BIND DNS instead of Route 53:** use `nsupdate -g` (Kerberos) or `dnscmd`; keep the rollback record set prepared identically.

### Rollback Procedure — DNS switch

```bash
for f in dns/rollback-${WAVE}-*.json; do
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$f" \
    --query 'ChangeInfo.Id' --output text | xargs -I{} aws route53 wait resource-record-sets-changed --id {}
done
```

### Rollback Procedure — full cutover (before `finalize-cutover`)

```bash
# 1. Stop traffic to AWS: DNS back to on-prem (above), then stop app on targets
for i in $INSTANCES; do
  aws ssm send-command --instance-ids "$i" --document-name AWS-RunShellScript \
    --parameters 'commands=["systemctl stop <app units>"]' >/dev/null
done

# 2. DATA RECONCILIATION — required if the target accepted writes after the DNS switch.
#    Files: reverse rsync target -> source (dry run first)
ssh <onprem_host> "sudo rsync -aHAX --numeric-ids --delete --dry-run \
  -e 'ssh -i /root/.ssh/rollback_key' ec2-user@<EC2_PRIVATE_IP>:/srv/app/ /srv/app/"
#    Databases: export delta from target and import to source per app runbook.
#    If no writes reached the target, skip this step.

# 3. Restart source services
while read -r SRC HOST UNITS; do
  ssh "$HOST" "sudo systemctl start ${UNITS//,/ } && sudo systemctl is-active ${UNITS//,/ }"
done < cutover/${WAVE}-servers.txt

# 4. Return MGN to pre-cutover state; replication resumes from source
for SRC in $(awk '{print $1}' cutover/${WAVE}-servers.txt); do
  aws mgn change-server-life-cycle-state --source-server-id "$SRC" --life-cycle state=READY_FOR_CUTOVER
done
aws ec2 stop-instances --instance-ids $INSTANCES   # keep for forensics; terminate after RCA
```

**Downtime impact of rollback:** ≈ 15–30 min (DNS TTL 60 s + service restart), plus reconciliation time if writes occurred.

### Definition of Done

- [ ] All wave apps served from EC2; DNS answers EC2 IPs from all resolvers
- [ ] App owner sign-off recorded at T+150m hold point
- [ ] RHEL targets show `UsageOperation=RunInstances`
- [ ] On-prem sources **powered off but retained** (not deleted)

**Commit:** `ops(cutover): complete ${WAVE} production cutover to EC2`

---

## Day 15 — Hypercare day 1, finalize cutover

**Estimated time:** 6 h (on-call coverage 24 h)

### Tasks

- [ ] Monitor CloudWatch (CPU, memory via CW agent, `StatusCheckFailed`, EBS latency) and app logs. *(ongoing)*
- [ ] Confirm backups: AWS Backup first recovery point created for every instance. *(30 min)*
- [ ] Compare app KPIs with on-prem baseline (latency, error rate). *(1 h)*
- [ ] App owners confirm stable operation for ≥ 24 h. *(—)*
- [ ] `finalize-cutover` (**point of no return for MGN**). *(15 min)*
- [ ] Disconnect source agents and archive source servers in MGN. *(15 min)*
- [ ] Restore DNS TTL to normal (e.g., 300–3600 s). *(15 min)*

```bash
for SRC in $(awk '{print $1}' cutover/${WAVE}-servers.txt); do
  aws mgn finalize-cutover --source-server-id "$SRC"
  aws mgn disconnect-from-service --source-server-id "$SRC"
  aws mgn mark-as-archived --source-server-id "$SRC"
done
```

### Rollback Procedure — after finalize

No automated path. Options in order of preference: (1) fix forward on EC2; (2) restore from AWS Backup recovery point; (3) power on retained on-prem source and reconcile data manually (sources retained until Day 20 + 14 days).

### Definition of Done

- [ ] 24 h without P1/P2 incidents attributable to migration
- [ ] MGN lifecycle `CUTOVER` finalized; source agents disconnected
- [ ] DNS TTL restored

**Commit:** `ops(cutover): finalize ${WAVE} cutover and archive MGN source servers`

---

## Days 16–18 — CentOS modernization on EC2

**Estimated time:** ~4 h per server (≈ 1 h prep, 1.5 h upgrade, 1.5 h validation). Schedule in a maintenance window; expect 30–60 min downtime per server.

### Tools

ELevate (Leapp + `leapp-data-rocky` or `leapp-data-almalinux`), `migrate2rocky.sh`, EBS snapshots, SSM.

### IAM

`ec2:CreateSnapshots`, `ec2:CreateReplaceRootVolumeTask`, `ec2:CreateImage`, `ssm:StartSession`.

### Tasks

- [ ] Snapshot all volumes (crash-consistent with services stopped) or create AMI. *(20 min)*
- [ ] **Optional but recommended:** run the upgrade first on a clone launched from the AMI. *(+2 h)*
- [ ] CentOS 7 → Rocky/Alma 8 via ELevate; then 8 → 9 via ELevate. *(1.5 h each hop)*
- [ ] CentOS 8 → Rocky 8 via `migrate2rocky.sh`. *(45 min)*
- [ ] Re-run `scripts/aws-nitro-preflight.sh` (new kernel/initramfs). *(10 min)*
- [ ] App validation by owner. *(1.5 h)*

```bash
# Pre-upgrade backup (from workstation)
INSTANCE=<i-xxxxxxxx>
aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop <app units>","sync"]'
aws ec2 create-snapshots --instance-specification InstanceId=$INSTANCE,ExcludeBootVolume=false \
  --copy-tags-from-source volume --description "pre-elevate-$(date +%F)" \
  --query 'Snapshots[].[SnapshotId,VolumeId]' --output table | tee cutover/${INSTANCE}-pre-elevate.txt
```

```bash
# CentOS 7 -> Rocky 8 (inside instance). CentOS 7 repos are archived: point to vault first.
sudo sed -i -e 's|^mirrorlist=|#mirrorlist=|' -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/CentOS-*.repo
sudo yum -y update && sudo reboot
sudo yum install -y http://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm
sudo yum install -y leapp-upgrade leapp-data-rocky        # or leapp-data-almalinux
sudo leapp preupgrade
sudo less /var/log/leapp/leapp-report.txt                 # resolve every "inhibitor"
sudo leapp answer --section remove_pam_pkcs11_module_check.confirm=True
sudo leapp upgrade && sudo reboot
cat /etc/os-release && uname -r
```

```bash
# CentOS 8 -> Rocky 8 (in place)
curl -fsSLO https://raw.githubusercontent.com/rocky-linux/rocky-tools/main/migrate2rocky/migrate2rocky.sh
sudo bash migrate2rocky.sh -r
sudo reboot
```

### Rollback Procedure — failed OS upgrade

```bash
# Restore root volume in place (keeps instance ID, ENI, IP)
ROOT_SNAP=<snap-xxxxxxxx>   # root volume snapshot from cutover/${INSTANCE}-pre-elevate.txt
aws ec2 create-replace-root-volume-task --instance-id "$INSTANCE" --snapshot-id "$ROOT_SNAP" \
  --delete-replaced-root-volume false
aws ec2 describe-replace-root-volume-tasks --filters Name=instance-id,Values=$INSTANCE
# Data volumes changed? Detach, create volume from snapshot, attach to the same device name.
```

### Definition of Done

- [ ] Every CentOS host on a supported EL (Rocky/Alma 9 target; 8 acceptable as interim with dated ticket)
- [ ] Preflight exit 0 post-upgrade
- [ ] Pre-upgrade snapshots retained 30 days

**Commit:** `feat(os): modernize ${WAVE} CentOS hosts to Rocky Linux <ver>`

---

## Day 19 — Operations handover

**Estimated time:** 5 h

### Tools

Terraform (`backup.tf`), SSM Patch Manager, CloudWatch agent, Compute Optimizer.

### Tasks

- [ ] Confirm AWS Backup plan (from Terraform) covers all `Backup=daily` tagged instances; perform one test restore. *(1.5 h)*
- [ ] Patch Manager: patch baselines per OS (RHEL, Rocky, Ubuntu, AL2023), maintenance windows, patch group tags. *(1.5 h)*
- [ ] CloudWatch agent config + alarms (CPU, mem, disk, status checks) to SNS → on-call. *(1 h)*
- [ ] Opt in to Compute Optimizer; schedule right-sizing review at T+30 days. *(30 min)*
- [ ] Ops runbook handover session with operations team. *(30 min)*

```bash
aws backup list-protected-resources --query 'Results[].ResourceArn' --output table
aws ssm describe-instance-patch-states-for-patch-group --patch-group linux-prod
aws compute-optimizer update-enrollment-status --status Active
```

### Definition of Done

- [ ] Successful test restore documented
- [ ] All instances in a patch group with a maintenance window
- [ ] Alarms routed and acknowledged by on-call

**Commit:** `feat(ops): hand over ${WAVE} with backup, patching and monitoring baselines`

---

## Day 20 — Close-out & decommission scheduling

**Estimated time:** 3 h

### Tasks

- [ ] Schedule source decommission at **T+14 days** after cutover (keep VMs powered off, not deleted, until then). *(30 min)*
- [ ] Unregister on-prem RHEL sources to free subscriptions (after decommission date). *(15 min)*
- [ ] Remove MGN staging resources if no further waves in this region. *(15 min)*
- [ ] Retrospective: issues, timings vs estimates; update this runbook for the next wave. *(1.5 h)*
- [ ] Update README wave table and tick Phase 3 days. *(30 min)*

```bash
# On-prem RHEL source, at decommission date only
sudo subscription-manager unregister
# Confirm no remaining active source servers
aws mgn describe-source-servers --filters isArchived=false --query 'length(items)'
```

### Rollback Procedure — decommission

Do not delete source VMs before T+14d. Until deletion, rollback = power on VM, re-register subscription (`subscription-manager register --activationkey <key> --org <org>`), reverse DNS, reconcile data.

### Definition of Done

- [ ] Decommission ticket with date and approver
- [ ] Retrospective notes merged; next-wave estimates updated

**Commit:** `docs(closeout): ${WAVE} retrospective and decommission schedule`
