# Phase 0 — Practice Lab: Build the "On-Prem" Servers (Lab Days L1–L3)

**Goal:** build a small fake data center on your Windows PC with VirtualBox: three Linux servers, one per distro, running a real two-tier app. Phases 1–3 then migrate them to AWS exactly as you would at a company.

**Why VirtualBox, not EC2, as the source:** VirtualBox VMs use SATA disks (`/dev/sda`) and Intel e1000 NICs, just like real on-prem servers. Migrating them to AWS (NVMe disks, ENA network) exercises the driver, fstab and network problems this project is about. EC2-to-EC2 migration would skip all of that.

**Phase exit gate:** all three VMs built, app working end to end, baseline snapshots taken, `inventory/hosts.csv` filled in.

---

## The lab you are building

```text
 Your Windows PC (VirtualBox)                                   AWS (later phases)
 ┌──────────────────────────────────────────────────────┐
 │ Host-only network 192.168.56.0/24  ("the data center")│
 │                                                        │
 │  rhel9-web01   192.168.56.21  Apache + PHP  ──┐        │     MGN agent → TCP 443 + 1500
 │  centos7-db01  192.168.56.30  MariaDB  ◄──────┘        │ ──────────────────────────────►  replication
 │  ubuntu22-app01 192.168.56.40 nginx (standalone)       │      over your home internet      server
 │                                                        │
 │  NIC 1 = NAT (internet)   NIC 2 = host-only (static IP)│
 └──────────────────────────────────────────────────────┘
```

| VM | OS | vCPU / RAM / Disk | Role | Wave |
|---|---|---|---|---|
| `ubuntu22-app01` | Ubuntu Server 22.04 LTS | 2 / 2 GB / 20 GB | Static website (nginx) | wave0 (pilot) |
| `rhel9-web01` | RHEL 9 (free Developer subscription) | 2 / 2 GB / 20 GB | PHP app, reads/writes db01 | wave1 |
| `centos7-db01` | CentOS 7.9 (EOL) | 2 / 2 GB / 20 GB | MariaDB database | wave1 (moves with web01), then ELevate → Rocky |

**PC requirements:** 16 GB RAM recommended (VMs use 6 GB). With 8 GB, run at most two VMs at once. ~70 GB free disk. CPU virtualization (VT-x/AMD-V) enabled in BIOS.

---

## Lab Day L1 — VirtualBox network, downloads, Red Hat account

**Estimated time:** 3 h (mostly downloads)

### Tools

| Tool | Version | Get it |
|---|---|---|
| Oracle VirtualBox | 7.x (already installed on your PC) | virtualbox.org |
| Windows PowerShell | 5.1+ (built in) | — |
| Windows OpenSSH client | built in (`ssh` in PowerShell) | Settings → Optional features if missing |
| Git for Windows | latest | git-scm.com |
| ISO: Ubuntu Server 22.04 LTS | 22.04.x | ubuntu.com/download/server (choose 22.04 LTS) |
| ISO: RHEL 9 DVD | 9.x | developers.redhat.com (after registering) |
| ISO: CentOS 7.9 Minimal | 2009 | `https://vault.centos.org/7.9.2009/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso` |

### Accounts / access

- **Red Hat Developer account** (free). The no-cost Developer Subscription for Individuals covers up to 16 systems, physical or virtual, including cloud instances. Your 1 lab VM + 1 AWS instance fits easily.
- **AWS account** with MFA on the root user, plus an IAM Identity Center admin user (Phase 1 Day 1). Never use root day to day.
- Windows admin rights (for the VirtualBox network adapter).

### Tasks

- [ ] Confirm VirtualBox works and check its version. *(10 min)*
- [ ] Create or configure the host-only network `192.168.56.0/24`. *(15 min)*
- [ ] Register at developers.redhat.com and activate the Developer Subscription. *(20 min)*
- [ ] Download the three ISOs into `C:\ISO\`. *(1–2 h, runs in background)*
- [ ] Clone/unzip this repo into `C:\Users\<you>\cloud-portfolio\aws-linux-migration` and commit. *(15 min)*

**System commands — PowerShell (run as Administrator)**

```powershell
$VBM = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $VBM --version

# List host-only adapters; most installs already have one at 192.168.56.1
& $VBM list hostonlyifs

# Only if none exists:
& $VBM hostonlyif create
& $VBM hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter" --ip 192.168.56.1 --netmask 255.255.255.0

New-Item -ItemType Directory -Force -Path C:\ISO | Out-Null
# Verify downloads finished
Get-ChildItem C:\ISO | Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,2)}}
```

```powershell
# Optional: verify ISO integrity against the checksum published on the download page
Get-FileHash C:\ISO\CentOS-7-x86_64-Minimal-2009.iso -Algorithm SHA256
```

### Definition of Done

- [ ] `VBoxManage list hostonlyifs` shows an adapter with IP `192.168.56.1`
- [ ] Three ISOs present in `C:\ISO\` with sizes > 0.9 GB
- [ ] Red Hat Developer Subscription shows as active at access.redhat.com → Subscriptions
- [ ] Repo cloned locally; first commit pushed to your GitHub

**Commit:** `chore(lab): bootstrap practice lab prerequisites and repo`

---

## Lab Day L2 — Build `centos7-db01` and `rhel9-web01`

**Estimated time:** 4 h

### Tools

VirtualBox, PowerShell, the CentOS 7 and RHEL 9 ISOs, Windows `ssh`.

### Tasks

- [ ] Create both VMs with the PowerShell function below. *(20 min)*
- [ ] Install CentOS 7 (Minimal). *(40 min)*
- [ ] Configure db01: hostname, static IP, vault repos, MariaDB, firewall. *(50 min)*
- [ ] Install RHEL 9 ("Server" or "Minimal Install"). *(40 min)*
- [ ] Configure web01: register subscription, static IP, Apache + PHP app. *(50 min)*
- [ ] Test the app from your Windows browser. *(10 min)*

**Step 1 — Create the VMs (PowerShell)**

```powershell
$VBM = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$HostOnly = "VirtualBox Host-Only Ethernet Adapter"   # name from 'list hostonlyifs'

function New-LabVM {
    param([string]$Name, [string]$OsType, [string]$Iso)
    & $VBM createvm --name $Name --ostype $OsType --register
    & $VBM modifyvm $Name --cpus 2 --memory 2048 --firmware bios `
        --nic1 nat --nic2 hostonly --hostonlyadapter2 $HostOnly `
        --graphicscontroller vmsvga --audio-enabled off
    $vdi = Join-Path $env:USERPROFILE "VirtualBox VMs\$Name\$Name.vdi"
    & $VBM createmedium disk --filename $vdi --size 20480 --format VDI
    & $VBM storagectl $Name --name SATA --add sata --controller IntelAhci
    & $VBM storageattach $Name --storagectl SATA --port 0 --device 0 --type hdd --medium $vdi
    & $VBM storageattach $Name --storagectl SATA --port 1 --device 0 --type dvddrive --medium $Iso
}

New-LabVM -Name "centos7-db01" -OsType "RedHat_64" -Iso "C:\ISO\CentOS-7-x86_64-Minimal-2009.iso"
New-LabVM -Name "rhel9-web01"  -OsType "RedHat_64" -Iso "C:\ISO\rhel-9.6-x86_64-dvd.iso"   # match your file name
& $VBM startvm "centos7-db01"
```

**Step 2 — Install CentOS 7 (in the VM window)**

1. Choose **Install CentOS 7**, then your language.
2. **Installation Destination:** select the 20 GB disk and keep "Automatically configure partitioning" (LVM, like most real servers).
3. **Network & Host Name:** switch **both** Ethernet adapters to **ON**. Set the hostname to `db01.lab.local`.
4. **Begin Installation.** Set a root password and create an admin user with **"Make this user administrator"** ticked.
5. **Reboot.** Then remove the ISO: VM window → Devices → Optical Drives → Remove disk.

**Step 3 — Configure db01 (log in on the VM console as your user)**

```bash
# Find the host-only NIC (usually enp0s8) and its NetworkManager connection name
nmcli -g NAME,DEVICE con show
sudo nmcli con mod enp0s8 ipv4.method manual ipv4.addresses 192.168.56.30/24 connection.autoconnect yes
sudo nmcli con up enp0s8
ip -4 addr show enp0s8
```

From here, work over SSH from PowerShell: `ssh <user>@192.168.56.30`

```bash
# CentOS 7 is end-of-life: point yum at the archive (vault) repos
sudo sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
  -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/CentOS-*.repo
sudo yum clean all && sudo yum -y update

# Lab "DNS": every server knows the others by name
sudo tee -a /etc/hosts <<'EOF'
192.168.56.21 web01.lab.local web01
192.168.56.30 db01.lab.local db01
192.168.56.40 app01.lab.local app01
EOF

# MariaDB
sudo yum -y install mariadb-server
sudo systemctl enable --now mariadb
sudo mysql_secure_installation          # set root password, answer Y to the rest
sudo mysql -uroot -p -e "
  CREATE DATABASE labapp;
  CREATE USER 'labapp'@'192.168.56.%' IDENTIFIED BY 'ChangeMe-Lab1!';
  GRANT ALL ON labapp.* TO 'labapp'@'192.168.56.%';
  FLUSH PRIVILEGES;"
sudo mysql -uroot -p labapp -e "
  CREATE TABLE visits (id INT AUTO_INCREMENT PRIMARY KEY,
                       ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                       host VARCHAR(64));"

# Allow MySQL only from the lab network
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=192.168.56.0/24 port port=3306 protocol=tcp accept'
sudo firewall-cmd --reload
```

**Step 4 — Install RHEL 9**

`& $VBM startvm "rhel9-web01"`, then follow the same installer steps as CentOS:
- Hostname: `web01.lab.local`.
- Both NICs **ON**.
- Software Selection: **Minimal Install**.
- Create an admin user.
- Under **Connect to Red Hat**, you can register with your developer login, or do it later with the command below.

**Step 5 — Configure web01**

```bash
# Static IP on host-only NIC
sudo nmcli con mod enp0s8 ipv4.method manual ipv4.addresses 192.168.56.21/24 connection.autoconnect yes
sudo nmcli con up enp0s8
```

Then `ssh <user>@192.168.56.21` from PowerShell:

```bash
# Register with your Red Hat Developer account (skip if done in installer)
sudo subscription-manager register --username <redhat-login>
sudo subscription-manager status

sudo tee -a /etc/hosts <<'EOF'
192.168.56.21 web01.lab.local web01
192.168.56.30 db01.lab.local db01
192.168.56.40 app01.lab.local app01
EOF

sudo dnf -y install httpd php php-mysqlnd
sudo setsebool -P httpd_can_network_connect_db 1   # SELinux: let Apache reach the database

sudo tee /var/www/html/index.php <<'EOF'
<?php
$db = new mysqli('db01.lab.local', 'labapp', 'ChangeMe-Lab1!', 'labapp');
if ($db->connect_error) { http_response_code(500); die('DB error: ' . $db->connect_error); }
$db->query("INSERT INTO visits (host) VALUES ('" . $db->real_escape_string(gethostname()) . "')");
$r = $db->query('SELECT COUNT(*) AS c FROM visits')->fetch_assoc();
echo "<h1>Lab app served by " . htmlspecialchars(gethostname()) . "</h1><p>Total visits: {$r['c']}</p>";
EOF

sudo systemctl enable --now httpd
sudo firewall-cmd --permanent --add-service=http && sudo firewall-cmd --reload
```

Open **http://192.168.56.21** in your Windows browser and refresh a few times: the visit count goes up. That count is your **migration proof**. After cutover it must continue from the same number, which shows the data moved intact.

### Rollback Procedure — a VM build goes wrong

Nothing is precious yet, so delete and rebuild:

```powershell
& $VBM controlvm "centos7-db01" poweroff
& $VBM unregistervm "centos7-db01" --delete
New-LabVM -Name "centos7-db01" -OsType "RedHat_64" -Iso "C:\ISO\CentOS-7-x86_64-Minimal-2009.iso"
```

### Definition of Done

- [ ] `ssh` works to 192.168.56.21 and 192.168.56.30 from Windows
- [ ] Both VMs reach the internet (`curl -sI https://aws.amazon.com | head -1` → `HTTP/... 200` or `301`)
- [ ] `sudo subscription-manager status` on web01 → `Overall Status: Current` (or `Registered` with Simple Content Access)
- [ ] Browser shows "Total visits: N" and N increments on refresh

**Commit:** `feat(lab): build centos7-db01 and rhel9-web01 two-tier app`

---

## Lab Day L3 — Build `ubuntu22-app01`, snapshot, inventory

**Estimated time:** 3 h

### Tools

VirtualBox, Ubuntu 22.04 ISO, `scripts/collect-facts.sh`, `scripts/aws-nitro-preflight.sh`.

### Tasks

- [ ] Create and install Ubuntu Server 22.04. *(45 min)*
- [ ] Configure static IP with Netplan, install nginx. *(30 min)*
- [ ] Run `collect-facts.sh` on all three VMs → `inventory/hosts.csv`. *(30 min)*
- [ ] Run `aws-nitro-preflight.sh` on all three and **save the output**. These are your "before" results for Phase 1 Day 4. *(30 min)*
- [ ] Take a `baseline` snapshot of every VM. *(15 min)*

**Step 1 — Create and install**

```powershell
New-LabVM -Name "ubuntu22-app01" -OsType "Ubuntu_64" -Iso "C:\ISO\ubuntu-22.04.5-live-server-amd64.iso"
& $VBM startvm "ubuntu22-app01"
```

Installer choices:
- Keep the default network settings (DHCP for now).
- Storage: **Use entire disk** with **Set up this disk as an LVM group** ticked.
- Profile: hostname `app01`, create your user.
- **Install OpenSSH server**: ticked.
- No snaps.
- Reboot, then remove the ISO.

**Step 2 — Static IP (Netplan) and nginx**

```bash
ip -br link          # expect enp0s3 (NAT) and enp0s8 (host-only)
sudo hostnamectl set-hostname app01.lab.local

sudo tee /etc/netplan/00-installer-config.yaml <<'EOF'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses: [192.168.56.40/24]
EOF
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan apply
```

> This file is your "on-prem" network config, bound to VirtualBox's `enp0s3`/`enp0s8` names. On AWS those interfaces won't exist and the NIC becomes `ens5`. That's exactly what `scripts/90-aws-ena.yaml` fixes in Phase 2 Day 9.

Then `ssh <user>@192.168.56.40` from PowerShell:

```bash
sudo tee -a /etc/hosts <<'EOF'
192.168.56.21 web01.lab.local web01
192.168.56.30 db01.lab.local db01
192.168.56.40 app01.lab.local app01
EOF
sudo apt update && sudo apt -y install nginx
echo "<h1>app01 - Ubuntu 22.04 pilot server</h1>" | sudo tee /var/www/html/index.html
```

**Step 3 — Inventory and "before" preflight (PowerShell, from the repo folder)**

```powershell
cd $env:USERPROFILE\cloud-portfolio\aws-linux-migration
$hosts = "192.168.56.40","192.168.56.21","192.168.56.30"
foreach ($h in $hosts) {
    Get-Content scripts\collect-facts.sh -Raw | ssh "<user>@$h" "sudo bash -s" | Add-Content inventory\hosts.csv
    Get-Content scripts\aws-nitro-preflight.sh -Raw | ssh "<user>@$h" "sudo bash -s" | Out-File "preflight-before-$h.log"
}
Get-Content inventory\hosts.csv
```

> `sudo` over SSH prompts for your password. If it hangs, run `sudo -v` in an SSH session first or allow passwordless sudo for your user in the lab only.

Then open `inventory/hosts.csv` in Excel/VS Code and fill in the columns the script leaves blank: environment, application, owner, wave and window. For a practice project **you are every app owner**; record your own decisions.

**Step 4 — Baseline snapshots (power off first for clean snapshots)**

```powershell
foreach ($vm in "ubuntu22-app01","rhel9-web01","centos7-db01") {
    & $VBM controlvm $vm acpipowerbutton; Start-Sleep 30
    & $VBM snapshot $vm take "baseline" --description "Clean build before migration work"
    & $VBM startvm $vm --type headless
}
```

### Rollback Procedure — restore a VM to its clean build

Use this any time a remediation step (dracut, fstab, netplan) breaks a VM:

```powershell
& $VBM controlvm "centos7-db01" poweroff
& $VBM snapshot "centos7-db01" restore "baseline"
& $VBM startvm "centos7-db01" --type headless
```

### Definition of Done

- [ ] All three VMs reachable by SSH on their static IPs and running headless
- [ ] http://192.168.56.40 shows the app01 page; http://192.168.56.21 shows the visit counter
- [ ] `inventory/hosts.csv` has 3 rows with every column filled
- [ ] Preflight "before" logs saved (expect WARN/FAIL items; you fix them in Phase 2 Day 9)
- [ ] `baseline` snapshot exists on all three VMs (`VBoxManage snapshot <vm> list`)

**Commit:** `feat(lab): build ubuntu22-app01, capture inventory and baseline snapshots`

---

## How the lab changes Phases 1–3

| Phase / Day | Real company | Practice lab |
|---|---|---|
| P1 Day 1 | Firewall change request | None: your home router already allows outbound 443/1500 |
| P1 Day 2 | Application Discovery Service | Skip; `collect-facts.sh` + `ss -tnp` is enough for 3 servers |
| P1 Day 3 | Meet app owners | You decide. Write the dependency (web01 → db01:3306) in `hosts.csv` |
| P2 Day 6 | `terraform.tfvars` | Use `terraform/lab.tfvars.example` (`lab_mode = true`): no NAT gateways, no interface endpoints, no TGW. Saves ≈ $100+/month |
| P2 Day 8 | `--data-plane-routing PRIVATE_IP --create-public-ip false` | `--data-plane-routing PUBLIC_IP --create-public-ip true`, staging subnet = public subnet (Terraform output handles it) |
| P2 Day 9 | STS creds from installer role | Same; works from home internet |
| P2 Day 11 | Private subnet, SSM via endpoints | Launch in the **public** subnet with a public IP so SSM works without NAT (SG still has **no inbound rules**) |
| P3 Day 14 | Route 53 DNS switch | Update `/etc/hosts` on web01 to the new db01 IP (or create a Route 53 private hosted zone `lab.local` in the VPC). Browse to the EC2 public IP to verify the visit counter continues |
| P3 Days 16–18 | ELevate | Practice ELevate on the migrated `centos7-db01` → Rocky 8 |

---

## Lab cost control (do not skip)

| Item | Approx. cost | Control |
|---|---|---|
| MGN service fee | Free for 2,160 hours (90 days) per source server | Finish within 90 days |
| Replication server (t3.small) + staging EBS | ≈ $0.50–1/day while replicating | Disconnect agents when not practicing |
| Test/cutover EC2 + EBS | Cents per hour | `--launch-disposition STOPPED`; terminate after testing |
| NAT gateway / interface endpoints | ≈ $33 per NAT/month; ≈ $7 per endpoint per AZ/month | **Disabled** by `lab_mode = true` |
| KMS key | $1/month | Destroyed in teardown (30-day deletion window) |

Set `budget_email` in `lab.tfvars` and Terraform creates an AWS Budget that emails you at 50 %, 80 % and 100 % of `budget_limit_usd` (default $30).

### Lab teardown (when you are finished, or pausing for weeks)

```bash
# 1. Stop replication and clean up MGN
for s in $(aws mgn describe-source-servers --query 'items[].sourceServerID' --output text); do
  aws mgn disconnect-from-service --source-server-id "$s" || true
  aws mgn mark-as-archived --source-server-id "$s" || true
done
# 2. Terminate any MGN-launched instances (check the console for leftovers)
aws ec2 describe-instances --filters "Name=tag:AWSApplicationMigrationServiceManaged,Values=*" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
# 3. Destroy the Terraform stack
cd terraform && terraform destroy -var-file=lab.tfvars
# 4. Check for orphaned EBS volumes/snapshots and EIPs
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
```

> Before step 3, screenshot or export everything you want for your portfolio (MGN console, test-launch validation, the visit counter on EC2).

**Commit:** `chore(lab): tear down practice environment and record final costs`
