# Phase 2 — Landing Zone & Replication (Days 6–12)

**Goal:** target infrastructure deployed by Terraform, MGN replicating every wave server with lag < 1 min, and a successful test launch validated by app owners.

**Phase exit gate:** wave servers in MGN lifecycle `READY_FOR_CUTOVER`, Go decision recorded, change freeze in effect.

> Days 9–12 repeat per production wave. Days 6–8 run once per account/region.

### Common variables (export in every session)

```bash
export AWS_PROFILE=migration-prod
export AWS_REGION=us-east-1
export TF_DIR=terraform
export WAVE=wave0
```

---

## Day 6 — Terraform backend + VPC / endpoints

**Estimated time:** 6 h

### Tools

| Tool | Version |
|---|---|
| Terraform | ≥ 1.10 (S3 native state locking via `use_lockfile`) |
| AWS provider | `~> 6.0` |
| AWS CLI | v2 |
| Git | any |

### IAM

- One-time (bootstrap): `s3:CreateBucket`, `s3:PutBucketVersioning`, `s3:PutEncryptionConfiguration`, `s3:PutBucketPublicAccessBlock`.
- Terraform apply role: `ec2:*` on VPC resources, `logs:*` on `/aws/vpc/flow-logs/*`, `iam:CreateRole`/`PassRole` for flow-log role. Use a dedicated `TerraformDeploy` permission set; never apply from personal admin.

### Tasks

- [ ] Create versioned, encrypted, private state bucket. *(30 min)*
- [ ] Copy `terraform/env/prod.s3.tfbackend.example` → `prod.s3.tfbackend`, fill bucket name. *(10 min)*
- [ ] Create `terraform.tfvars` from `terraform.tfvars.example`. *(30 min)*
- [ ] `terraform init` / `plan` / peer review / `apply` for VPC, subnets, NAT, flow logs, VPC endpoints, TGW attachment. *(3 h)*
- [ ] Validate on-prem ↔ VPC routing (ping/traceroute from jump host to a test ENI; Reachability Analyzer). *(1.5 h)*

```bash
# State bucket bootstrap (one-time)
BUCKET="tfstate-<ACCOUNT_ID>-${AWS_REGION}"
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  $( [ "$AWS_REGION" != "us-east-1" ] && echo --create-bucket-configuration LocationConstraint=$AWS_REGION )
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

```bash
# Deploy network layer
cd "$TF_DIR"
terraform init -backend-config=env/prod.s3.tfbackend
terraform fmt -check -recursive && terraform validate
terraform plan -target=module.vpc -target=module.vpc_endpoints \
  -target=aws_ec2_transit_gateway_vpc_attachment.this -out=day06.tfplan
terraform apply day06.tfplan
```

> `-target` is used only to stage the first build. From Day 7 onward run full plans.

### Rollback Procedure — network deploy

```bash
# Nothing is attached to the VPC yet; destroy is safe on Day 6 only.
cd terraform
terraform plan -destroy -target=module.vpc_endpoints -target=module.vpc \
  -target=aws_ec2_transit_gateway_vpc_attachment.this -out=rollback-day06.tfplan
terraform apply rollback-day06.tfplan
# Revert the code
git revert <commit-sha> && git push
```

### Definition of Done

- [ ] `terraform plan` shows no drift after apply
- [ ] Private, staging, and public subnets exist in ≥ 2 AZs
- [ ] VPC endpoints (S3 gateway; SSM, SSMMessages, EC2, EC2Messages, MGN, KMS, Logs, STS interface) `available`
- [ ] Reachability Analyzer path on-prem CIDR → staging subnet TCP 1500: reachable
- [ ] VPC flow logs delivering to CloudWatch Logs

**Commit:** `feat(network): deploy target VPC, endpoints and TGW attachment`

---

## Day 7 — KMS, security groups, IAM, SCP guardrails

**Estimated time:** 5 h

### Tools

Terraform, AWS CLI, IAM Access Analyzer.

### IAM

- Workload account: `kms:CreateKey`, `kms:PutKeyPolicy`, `ec2:EnableEbsEncryptionByDefault`, `ec2:ModifyEbsDefaultKmsKeyId`, `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:CreateInstanceProfile`.
- Management account (SCP): `organizations:CreatePolicy`, `organizations:AttachPolicy` — run by the org admin only.

### Tasks

- [ ] Apply KMS CMK + EBS default encryption, security groups, IAM roles/instance profile. *(2 h)*
- [ ] Run IAM Access Analyzer policy validation on new roles. *(30 min)*
- [ ] Org admin applies `terraform/org` SCP (deny RHEL license-included AMIs) to the workload OU — test in sandbox OU first. *(1.5 h)*
- [ ] Verify SCP: launching a public RHEL LI AMI fails; gold image succeeds. *(1 h)*

```bash
cd terraform
terraform plan -out=day07.tfplan   # expect: KMS key, SGs, IAM, launch templates
terraform apply day07.tfplan
aws ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault
aws ec2 get-ebs-default-kms-key-id
```

```bash
# SCP (management account, separate state)
cd terraform/org
terraform init -backend-config=../env/org.s3.tfbackend
terraform plan -var 'target_ou_id=<ou-xxxx-sandbox>' -out=scp.tfplan && terraform apply scp.tfplan
# Negative test in sandbox account — must fail with UnauthorizedOperation (explicit deny)
LI_AMI=$(aws ec2 describe-images --owners 309956199498 --filters "Name=is-public,Values=true" "Name=name,Values=RHEL-9*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
aws ec2 run-instances --dry-run --image-id "$LI_AMI" --instance-type t3.micro --subnet-id <subnet>
```

### Rollback Procedure — EBS default encryption / SCP

```bash
# EBS default encryption: disabling affects only NEW volumes; existing stay encrypted.
aws ec2 disable-ebs-encryption-by-default
# KMS key: NEVER delete during migration. If it must go, schedule (7–30 day window):
aws kms schedule-key-deletion --key-id <key-id> --pending-window-in-days 30
aws kms cancel-key-deletion --key-id <key-id>      # undo
# SCP detach (management account) — immediate effect
aws organizations detach-policy --policy-id <p-xxxx> --target-id <ou-xxxx>
```

### Definition of Done

- [ ] `EbsEncryptionByDefault = true` with CMK
- [ ] No SG allows `0.0.0.0/0` ingress; replication SG allows TCP 1500 only from on-prem CIDRs
- [ ] SCP negative test fails (deny) and gold-image dry run succeeds (`DryRunOperation`)
- [ ] Access Analyzer: zero security warnings on new policies

**Commit:** `feat(security): add KMS, EBS default encryption, SGs, IAM and RHEL LI SCP`

---

## Day 8 — MGN initialization & replication/launch templates

**Estimated time:** 4 h

### Tools

AWS CLI v2 (`aws mgn`), Terraform outputs.

### IAM

`AWSApplicationMigrationFullAccess`; `iam:CreateServiceLinkedRole` (first-time `initialize-service` creates MGN service roles).

### Tasks

- [ ] Initialize MGN in the region. *(15 min)*
- [ ] Create replication configuration template: private data plane, CMK encryption, no public IP, staging subnet from Terraform output. *(1 h)*
- [ ] Configure launch settings template defaults: right-sizing off (we size explicitly), copy tags, launch STOPPED, BYOL licensing for RHEL. *(1 h)*
- [ ] Enable post-launch actions: install SSM Agent, CloudWatch agent, and (Ubuntu) netplan validation document. *(1 h)*
- [ ] Generate short-lived agent install credentials procedure (no IAM user keys). *(45 min)*

```bash
aws mgn initialize-service

cd terraform
STAGING_SUBNET=$(terraform output -raw mgn_staging_subnet_id)
REPL_SG=$(terraform output -raw mgn_replication_sg_id)
KMS_ARN=$(terraform output -raw ebs_kms_key_arn)

DATA_PLANE=$(terraform output -raw mgn_data_plane_routing)   # PRIVATE_IP (prod) / PUBLIC_IP (lab)
if [ "$(terraform output -raw mgn_create_public_ip)" = "true" ]; then PUBIP=--create-public-ip; else PUBIP=--no-create-public-ip; fi

aws mgn create-replication-configuration-template \
  --staging-area-subnet-id "$STAGING_SUBNET" \
  --no-associate-default-security-group \
  --replication-servers-security-groups-i-ds "$REPL_SG" \
  --replication-server-instance-type t3.small \
  --no-use-dedicated-replication-server \
  --default-large-staging-disk-type GP3 \
  --ebs-encryption CUSTOM \
  --ebs-encryption-key-arn "$KMS_ARN" \
  --bandwidth-throttling 0 \
  --data-plane-routing "$DATA_PLANE" \
  $PUBIP \
  --staging-area-tags Project=linux-aws-migration,Component=mgn-staging

aws mgn describe-replication-configuration-templates --output table
```

```bash
# Agent install credentials: assume the installer role (created by Terraform) for 1 h
CREDS=$(aws sts assume-role --role-arn "$(cd terraform && terraform output -raw mgn_agent_installer_role_arn)" \
  --role-session-name "mgn-install-${WAVE}" --duration-seconds 3600 --query Credentials --output json)
export MGN_AKID=$(echo "$CREDS" | jq -r .AccessKeyId)
export MGN_SAK=$(echo "$CREDS"  | jq -r .SecretAccessKey)
export MGN_TOK=$(echo "$CREDS"  | jq -r .SessionToken)
```

### Definition of Done

- [ ] `describe-replication-configuration-templates` shows `dataPlaneRouting=PRIVATE_IP`, `ebsEncryption=CUSTOM`, `createPublicIP=false`
- [ ] Post-launch actions enabled (SSM Agent install)
- [ ] Installer role assumable only by `MigrationEngineer`; session ≤ 1 h

**Commit:** `feat(mgn): initialize service and private, encrypted replication template`

---

## Day 9 — Source remediation + MGN agent install

**Estimated time:** 6 h per wave (≈ 20 min/host + remediation)

### Tools

`scripts/aws-nitro-preflight.sh`, MGN replication agent (`aws-replication-installer-init`), `dracut` (EL) / `update-initramfs` (Ubuntu), `wget`/`curl`.

### Prerequisites

- Firewall open: source → MGN regional endpoint **TCP 443**, source → staging subnet **TCP 1500**.
- Root disk free space ≥ 2 GB in `/var/lib`; Python not required for current agent on supported OSes.
- Day 8 STS credentials exported.

### Tasks

- [ ] Remediate every exit-2 / exit-1 finding from Day 4 (scripted below). *(2 h)*
- [ ] Re-run preflight; require exit 0 (or documented accepted warnings). *(30 min)*
- [ ] Install MGN agent on each host. *(2 h)*
- [ ] Ubuntu hosts: stage `scripts/90-aws-ena.yaml` and remove cloud-init network disable. *(30 min)*
- [ ] Verify each source server appears in MGN with replication `INITIATING`/`INITIAL_SYNC`. *(1 h)*

**System commands — remediation (RHEL / CentOS 7+)**

```bash
sudo cp -a /boot/initramfs-$(uname -r).img /boot/initramfs-$(uname -r).img.pre-aws
echo 'add_drivers+=" nvme nvme_core ena "' | sudo tee /etc/dracut.conf.d/90-aws-nitro.conf
sudo dracut -f -v /boot/initramfs-$(uname -r).img $(uname -r)
sudo grubby --update-kernel=ALL --args='nvme_core.io_timeout=4294967295'
# fstab: convert /dev/sdX to UUID (review before writing!)
sudo cp -a /etc/fstab /etc/fstab.pre-aws
sudo blkid -s UUID -o export
# Kernel too old for ENA (EL7 < 7.4)
sudo yum -y update kernel && sudo reboot
```

**System commands — remediation (Ubuntu)**

```bash
sudo cp -a /boot/initrd.img-$(uname -r) /boot/initrd.img-$(uname -r).pre-aws
printf 'nvme\nena\n' | sudo tee -a /etc/initramfs-tools/modules
sudo update-initramfs -u -k "$(uname -r)"
sudo apt-get update && sudo apt-get install -y linux-aws   # optional: AWS-tuned kernel, needs reboot
sudo install -m 600 -o root -g root scripts/90-aws-ena.yaml /etc/netplan/90-aws-ena.yaml
sudo netplan generate
sudo grep -rl 'config: disabled' /etc/cloud/cloud.cfg.d/ | xargs -r sudo mv -t /root/
```

**System commands — MGN agent install (all distros)**

```bash
# Run on the source host; credentials passed from Day 8 (expire in 1 h)
wget -O ./aws-replication-installer-init \
  "https://aws-application-migration-service-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/latest/linux/aws-replication-installer-init"
chmod +x aws-replication-installer-init
sudo ./aws-replication-installer-init --region "$AWS_REGION" \
  --aws-access-key-id "$MGN_AKID" --aws-secret-access-key "$MGN_SAK" --aws-session-token "$MGN_TOK" \
  --no-prompt
# EL6 / legacy kernels: use the legacy installer documented in the MGN supported-OS page.
```

```bash
# Confirm registration
aws mgn describe-source-servers \
  --query 'items[].{id:sourceServerID,host:sourceProperties.identificationHints.hostname,state:dataReplicationInfo.dataReplicationState}' \
  --output table
```

### Rollback Procedure — source remediation

```bash
# Initramfs (RHEL/CentOS): restore and reboot into known-good
sudo cp -a /boot/initramfs-$(uname -r).img.pre-aws /boot/initramfs-$(uname -r).img
sudo rm -f /etc/dracut.conf.d/90-aws-nitro.conf
sudo grubby --update-kernel=ALL --remove-args='nvme_core.io_timeout'
# Ubuntu
sudo cp -a /boot/initrd.img-$(uname -r).pre-aws /boot/initrd.img-$(uname -r)
sudo rm -f /etc/netplan/90-aws-ena.yaml && sudo netplan generate
# fstab
sudo cp -a /etc/fstab.pre-aws /etc/fstab && sudo mount -a
```

### Rollback Procedure — MGN agent

```bash
# Stops replication, removes the agent from the source, deletes staging resources for this server
aws mgn disconnect-from-service --source-server-id <s-xxxxxxxx>
aws mgn mark-as-archived       --source-server-id <s-xxxxxxxx>
```

### Definition of Done

- [ ] Preflight exit 0 on 100 % of wave hosts (or accepted warnings signed in PR)
- [ ] `.pre-aws` backups exist for initramfs and fstab on every remediated host
- [ ] Every wave host registered in MGN; no host in `STALLED`/`DISCONNECTED`

**Commit:** `fix(preflight): remediate Nitro drivers and fstab on ${WAVE}` and `ops(replication): install MGN agents on ${WAVE}`

---

## Day 10 — Initial sync monitoring & lag tuning

**Estimated time:** 2 h active; elapsed depends on data volume and bandwidth (rule of thumb: TB × 8 / Mbps ≈ hours × 2.3)

### Tools

AWS CLI, CloudWatch, MGN console.

### Tasks

- [ ] Monitor every 2 h until all servers reach `CONTINUOUS` with lag `PT0S`–`PT1M`. *(2 h total)*
- [ ] If WAN saturates during business hours, apply bandwidth throttling (Mbps) to the template. *(15 min)*
- [ ] Investigate any `STALLED` server (agent log: `/var/lib/aws-replication-agent/agent.log.0`). *(as needed)*

```bash
watch -n 300 "aws mgn describe-source-servers --query \
 'items[].[sourceProperties.identificationHints.hostname,dataReplicationInfo.dataReplicationState,dataReplicationInfo.lagDuration,dataReplicationInfo.etaDateTime]' \
 --output table"

# Throttle during business hours (value in Mbps, 0 = unlimited)
TPL=$(aws mgn describe-replication-configuration-templates --query 'items[0].replicationConfigurationTemplateID' --output text)
aws mgn update-replication-configuration-template --replication-configuration-template-id "$TPL" --bandwidth-throttling 200
```

```bash
# Source-side agent health
sudo tail -n 100 /var/lib/aws-replication-agent/agent.log.0
sudo systemctl status aws-replication-agent 2>/dev/null || sudo service aws-replication-agent status
```

### Definition of Done

- [ ] All wave servers `CONTINUOUS`, lag ≤ 1 min sustained for 24 h
- [ ] WAN impact accepted by network team

**Commit:** `docs(replication): record ${WAVE} initial sync completion and throughput`

---

## Day 11 — Test launch, functional validation, DNS TTL reduction

**Estimated time:** 7 h

### Tools

AWS CLI, SSM Session Manager plugin, app test plans, EC2 Serial Console (enabled at account level).

### IAM

`ssm:StartSession` on tagged instances, `ec2-instance-connect:SendSerialConsoleSSHPublicKey`, `route53:ChangeResourceRecordSets` on the app zone.

### Tasks

- [ ] Set per-server launch configuration (instance type, BYOL, private IP) and update the MGN-generated EC2 launch template. *(1.5 h)*
- [ ] `start-test` for the wave; wait for `LAUNCHED`. *(1 h elapsed)*
- [ ] Validate: boot, NVMe root, ENA (`ethtool -i ens5`), mounts, services, SSM online, app smoke test by owner. *(3 h)*
- [ ] Ubuntu: confirm `ens5` up via netplan; RHEL: `subscription-manager status` = Current. *(30 min)*
- [ ] Lower DNS TTL to 60 s on every record that will move (≥ 48 h before cutover). *(30 min)*
- [ ] Terminate test instances, mark `READY_FOR_CUTOVER`. *(30 min)*

```bash
SRC=<s-xxxxxxxx>
aws mgn update-launch-configuration --source-server-id "$SRC" \
  --target-instance-type-right-sizing-method NONE \
  --copy-private-ip false --copy-tags true \
  --launch-disposition STOPPED \
  --licensing osByol=true
LT=$(aws mgn get-launch-configuration --source-server-id "$SRC" --query ec2LaunchTemplateID --output text)
SUBNET=$(cd terraform && terraform output -raw launch_subnet_id)
SGS=$(cd terraform && terraform output -raw workload_baseline_sg_id)          # add app/db SG IDs per server
PUBLIC=false   # set true ONLY in lab mode (public subnet, no NAT)
aws ec2 create-launch-template-version --launch-template-id "$LT" --source-version '$Latest' \
  --launch-template-data "{
    \"InstanceType\":\"m7i.large\",
    \"IamInstanceProfile\":{\"Name\":\"migrated-ec2-ssm\"},
    \"MetadataOptions\":{\"HttpTokens\":\"required\"},
    \"NetworkInterfaces\":[{\"DeviceIndex\":0,\"SubnetId\":\"$SUBNET\",\"Groups\":[\"$SGS\"],\"AssociatePublicIpAddress\":$PUBLIC}]
  }"
aws ec2 modify-launch-template --launch-template-id "$LT" --default-version '$Latest'

aws mgn start-test --source-server-i-ds "$SRC"
aws mgn describe-jobs --query 'items[0].[jobID,status,participatingServers[0].launchStatus]' --output table
```

```bash
# Validation inside the test instance (via Session Manager)
aws ssm start-session --target <i-xxxxxxxx>
lsblk -o NAME,TYPE,SIZE,MOUNTPOINT | grep nvme
ethtool -i ens5 | grep -E 'driver|version'
findmnt --verify
systemctl --failed
# RHEL
sudo subscription-manager status
# Ubuntu
networkctl status ens5
```

```bash
# DNS TTL reduction (Route 53) — keep current target, change TTL only
cat > dns/ttl-${WAVE}.json <<'EOF'
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"app01.corp.example.com","Type":"A","TTL":60,
  "ResourceRecords":[{"Value":"<ONPREM_IP>"}]}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id <ZONE_ID> --change-batch file://dns/ttl-${WAVE}.json
```

```bash
# After sign-off
aws mgn terminate-target-instances --source-server-i-ds "$SRC"
aws mgn change-server-life-cycle-state --source-server-id "$SRC" --life-cycle state=READY_FOR_CUTOVER
```

### Rollback Procedure — failed test launch

```bash
# Test instances are disposable; replication continues unaffected.
aws mgn terminate-target-instances --source-server-i-ds "$SRC"
# Fix launch template / source remediation, then re-run start-test.
# Boot debugging: EC2 Serial Console
aws ec2 get-serial-console-access-status
aws ec2 get-console-output --instance-id <i-xxxxxxxx> --latest --output text | tail -50
```

### Rollback Procedure — DNS TTL

```bash
# Restore original TTL (e.g. 3600) — no traffic impact
sed -i 's/"TTL":60/"TTL":3600/' dns/ttl-${WAVE}.json
aws route53 change-resource-record-sets --hosted-zone-id <ZONE_ID> --change-batch file://dns/ttl-${WAVE}.json
```

### Definition of Done

- [ ] Test instance for every wave server boots, SSM `Online`, app smoke test signed by owner
- [ ] RHEL test instances: `UsageOperation=RunInstances` (BYOL), not `RunInstances:0010`
- [ ] DNS TTL = 60 s confirmed with `dig +noall +answer <record>`
- [ ] All wave servers `READY_FOR_CUTOVER`; test instances terminated

**Commit:** `ops(test-launch): validate ${WAVE} test launch and lower DNS TTLs`

---

## Day 12 — Go/No-Go, freeze

**Estimated time:** 3 h

### Tasks

- [ ] Go/No-Go meeting: replication lag, test results, rollback owners, comms plan. *(1 h)*
- [ ] Announce change freeze on wave hosts (no app deploys, no config changes) through Day 15. *(15 min)*
- [ ] Pre-generate cutover and rollback DNS change files (`dns/cutover-*.json`, `dns/rollback-*.json`). *(1 h)*
- [ ] Confirm on-prem backup of each wave host completed in last 24 h. *(45 min)*

### Definition of Done

- [ ] Go decision recorded in PR with approvers: migration lead, app owners, security
- [ ] Rollback files committed and peer-reviewed

**Commit:** `docs(cutover): ${WAVE} go decision, freeze and DNS change sets`
