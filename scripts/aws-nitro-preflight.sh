#!/usr/bin/env bash
# aws-nitro-preflight.sh
# Pre-cutover readiness check for AWS Nitro (ENA + NVMe) on RHEL/CentOS 6/7/8/9.
# Also runs on Ubuntu/Debian (lsinitramfs path) for convenience.
#
# Read-only. Makes NO changes. Run as root.
#   Local:   sudo bash aws-nitro-preflight.sh
#   Fleet:   aws ssm send-command --document-name AWS-RunShellScript \
#              --targets Key=tag:MigrationWave,Values=wave1 \
#              --parameters commands="$(cat aws-nitro-preflight.sh)" \
#              --output-s3-bucket-name <bucket> --output-s3-key-prefix preflight/
#   Then grep the S3 output for '^RESULT' to build the wave readiness table.
#
# Exit codes: 0 = ready, 1 = warnings only, 2 = one or more blocking failures, 3 = not root

set -u
export LC_ALL=C

PASS=0; WARN=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
fix()  { printf '       fix: %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (initramfs inspection needs it)."; exit 3; }

KVER="$(uname -r)"
HOST="$(hostname -f 2>/dev/null || hostname)"
MODDIR="/lib/modules/${KVER}"

# ---------- OS detection (EL6 has no /etc/os-release) ----------
OS_ID="unknown"; OS_VER="0"; FAMILY="unknown"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-0}"
elif [ -r /etc/redhat-release ]; then
  grep -qi centos /etc/redhat-release && OS_ID="centos" || OS_ID="rhel"
  OS_VER="$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)"
fi
case "$OS_ID" in
  rhel|centos|rocky|almalinux|ol|amzn) FAMILY="el" ;;
  ubuntu|debian)                       FAMILY="deb" ;;
esac
OS_MAJOR="${OS_VER%%.*}"

echo "=== AWS Nitro preflight: ${HOST} | ${OS_ID} ${OS_VER} | kernel ${KVER} ==="

# ---------- 1. OS lifecycle ----------
case "${OS_ID}:${OS_MAJOR}" in
  centos:6|rhel:6) warn "EL6 detected: in-tree kernel has no ENA driver; out-of-tree ENA (amzn-drivers, DKMS) required. Strongly consider replatform." ;;
  centos:7)        warn "CentOS 7 is EOL (2024-06-30). Plan ELevate/Leapp to Rocky/Alma 8+ or convert2rhel post-cutover." ;;
  centos:8)        warn "CentOS Linux 8 is EOL. Plan migrate2rocky / almalinux-deploy post-cutover." ;;
esac

# ---------- helpers ----------
# Module available on disk or built into the running kernel?
mod_available() {
  local m="$1"
  modinfo -k "$KVER" "$m" >/dev/null 2>&1 && return 0
  [ -r "${MODDIR}/modules.builtin" ] && grep -qE "/${m}\.ko(\.[gx]z|\.zst)?$" "${MODDIR}/modules.builtin" && return 0
  return 1
}
mod_builtin() {
  local m="$1"
  [ -r "${MODDIR}/modules.builtin" ] && grep -qE "/${m}\.ko(\.[gx]z|\.zst)?$" "${MODDIR}/modules.builtin"
}

# Locate initramfs and a lister
INITRD=""; LISTCMD=""
if [ "$FAMILY" = "deb" ]; then
  INITRD="/boot/initrd.img-${KVER}"
  command -v lsinitramfs >/dev/null 2>&1 && LISTCMD="lsinitramfs"
else
  INITRD="/boot/initramfs-${KVER}.img"
  command -v lsinitrd >/dev/null 2>&1 && LISTCMD="lsinitrd"
fi

INITRD_LIST=""
if [ -n "$LISTCMD" ] && [ -r "$INITRD" ]; then
  INITRD_LIST="$($LISTCMD "$INITRD" 2>/dev/null)"
else
  fail "Cannot inspect initramfs (${INITRD:-none}; lister ${LISTCMD:-missing})."
fi

in_initrd() { printf '%s\n' "$INITRD_LIST" | grep -qE "/${1}\.ko(\.[gx]z|\.zst)?$"; }

# ---------- 2. Driver presence in kernel ----------
for m in ena nvme; do
  if mod_available "$m"; then
    if mod_builtin "$m"; then pass "Driver '$m' is built into kernel ${KVER}."
    else pass "Driver '$m' module present for ${KVER} ($(modinfo -k "$KVER" -F filename "$m" 2>/dev/null))."; fi
  else
    fail "Driver '$m' NOT available for running kernel ${KVER}."
    if [ "$m" = "ena" ]; then
      case "${FAMILY}:${OS_MAJOR}" in
        el:6)  fix "Build ENA via DKMS from github.com/amzn/amzn-drivers (kernel/linux/ena), or replatform." ;;
        el:7)  fix "ENA is in-tree from RHEL/CentOS 7.4 (kernel 3.10.0-693). Update kernel: yum -y update kernel && reboot." ;;
        deb:*) fix "apt-get install -y linux-aws  (or linux-modules-extra-\$(uname -r))" ;;
        *)     fix "Update to a current vendor kernel." ;;
      esac
    else
      fix "NVMe is in-tree on EL6.5+/EL7+. Update kernel; on Ubuntu: apt-get install -y linux-aws"
    fi
  fi
done

ENA_VER="$(modinfo -k "$KVER" -F version ena 2>/dev/null || true)"
[ -n "$ENA_VER" ] && info "ENA driver version: ${ENA_VER} (compare against amzn-drivers release notes for your instance family)."

# ---------- 3. Drivers inside initramfs (the cutover killer) ----------
# Root volume on Nitro is NVMe. If nvme is a loadable module and not in the initramfs,
# the instance drops to the dracut emergency shell at boot.
if [ -n "$INITRD_LIST" ]; then
  for m in nvme nvme_core ena; do
    if mod_builtin "$m"; then
      pass "'$m' built into kernel; initramfs inclusion not required."
    elif in_initrd "$m"; then
      pass "'$m' present in ${INITRD}."
    elif [ "$m" = "nvme_core" ] && ! mod_available nvme_core; then
      info "nvme_core not a separate module on this kernel (expected on older EL7)."
    elif [ "$m" = "ena" ]; then
      warn "'ena' not in initramfs (non-blocking: ENA loads from rootfs; only needed for network root)."
    else
      fail "'$m' MISSING from ${INITRD} -> boot will fail on Nitro."
      if [ "$FAMILY" = "el" ]; then
        fix "echo 'add_drivers+=\" nvme nvme_core ena \"' > /etc/dracut.conf.d/90-aws-nitro.conf && dracut -f -v ${INITRD} ${KVER}"
      else
        fix "printf 'nvme\nena\n' >> /etc/initramfs-tools/modules && update-initramfs -u -k ${KVER}"
      fi
    fi
  done
fi

# dracut hostonly strips drivers for hardware not present on the source (VMware/KVM/physical)
if [ "$FAMILY" = "el" ]; then
  if grep -rqsE '^\s*hostonly\s*=\s*"?yes' /etc/dracut.conf /etc/dracut.conf.d/ 2>/dev/null \
     || { [ "${OS_MAJOR:-0}" -ge 7 ] 2>/dev/null && ! grep -rqsE '^\s*hostonly\s*=\s*"?no' /etc/dracut.conf /etc/dracut.conf.d/ 2>/dev/null; }; then
    if grep -rqsE 'add_drivers\+?=.*nvme' /etc/dracut.conf /etc/dracut.conf.d/ 2>/dev/null; then
      pass "dracut hostonly mode but nvme pinned via add_drivers (survives kernel updates)."
    else
      warn "dracut hostonly mode without persistent nvme/ena add_drivers: next kernel update will drop them."
      fix "echo 'add_drivers+=\" nvme nvme_core ena \"' > /etc/dracut.conf.d/90-aws-nitro.conf"
    fi
  fi
fi

# ---------- 4. All installed kernels (grub may boot a different one) ----------
if [ "$FAMILY" = "el" ]; then
  for kdir in /lib/modules/*/; do
    [ -d "$kdir" ] || continue
    k="$(basename "$kdir")"
    [ "$k" = "$KVER" ] && continue
    img="/boot/initramfs-${k}.img"
    [ -r "$img" ] || continue
    if ! lsinitrd "$img" 2>/dev/null | grep -qE '/nvme\.ko' && ! grep -qE '/nvme\.ko' "/lib/modules/${k}/modules.builtin" 2>/dev/null; then
      warn "Non-running kernel ${k}: nvme absent from ${img} (bad if it becomes default)."
    fi
  done
fi

# ---------- 5. fstab device naming ----------
BAD_FSTAB="$(grep -vE '^\s*(#|$)' /etc/fstab | awk '{print $1}' | grep -E '^/dev/(sd|xvd|hd|vd)[a-z]+' || true)"
if [ -n "$BAD_FSTAB" ]; then
  fail "fstab references kernel device names that change on NVMe: $(echo $BAD_FSTAB)"
  fix "Replace with UUID= (blkid) or LABEL=. Add 'nofail' to non-root data volumes."
else
  pass "fstab uses UUID/LABEL/LVM paths."
fi
NOFAIL_MISSING="$(grep -vE '^\s*(#|$)' /etc/fstab | awk '$2!="/" && $2!="/boot" && $2!="/boot/efi" && $3!="swap" && $4!~/nofail/ && $3~/^(xfs|ext[234])$/ {print $2}' || true)"
[ -n "$NOFAIL_MISSING" ] && warn "Data mounts without 'nofail' (instance won't boot if volume missing): $(echo $NOFAIL_MISSING)"

# ---------- 6. Kernel cmdline root= ----------
if grep -qE 'root=/dev/(sd|xvd|hd|vd)[a-z]' /proc/cmdline; then
  fail "Kernel cmdline uses raw device root=: $(grep -oE 'root=[^ ]+' /proc/cmdline)"
  fix "Set root=UUID=<uuid> in /etc/default/grub, then grub2-mkconfig -o /boot/grub2/grub.cfg (EL7+) / update-grub (Ubuntu)."
elif grep -qE 'root=' /proc/cmdline; then
  pass "Root device on cmdline is UUID/LVM-based: $(grep -oE 'root=[^ ]+' /proc/cmdline)"
else
  warn "No root= on kernel cmdline; verify /etc/default/grub GRUB_CMDLINE_LINUX and grub.cfg."
fi

# NVMe I/O timeout (AWS recommends max value so EBS latency spikes don't fail I/O)
if grep -qE 'nvme(_core)?\.io_timeout=' /proc/cmdline; then
  pass "NVMe io_timeout set on cmdline."
else
  warn "NVMe io_timeout not set. EBS recommends nvme_core.io_timeout=4294967295 (EL7: may be nvme.io_timeout)."
  [ "$FAMILY" = "el" ] && [ "${OS_MAJOR:-0}" -ge 7 ] 2>/dev/null && fix "grubby --update-kernel=ALL --args='nvme_core.io_timeout=4294967295'"
fi

# ---------- 7. Network naming / MAC pinning ----------
if [ -s /etc/udev/rules.d/70-persistent-net.rules ]; then
  warn "70-persistent-net.rules exists: pins NIC names to on-prem MACs; ENA will come up as eth1/renamed."
  fix "Move it aside after replication starts (MGN post-launch action) or: mv /etc/udev/rules.d/70-persistent-net.rules /root/"
fi
if [ "$FAMILY" = "el" ] && ls /etc/sysconfig/network-scripts/ifcfg-* >/dev/null 2>&1; then
  HW="$(grep -lE '^\s*HWADDR=' /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v ifcfg-lo || true)"
  [ -n "$HW" ] && warn "ifcfg files pin HWADDR (won't match ENA MAC): $(echo $HW)"
  ST="$(grep -lE '^\s*BOOTPROTO=["]?(static|none)' /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v ifcfg-lo || true)"
  [ -n "$ST" ] && warn "Static IP config found: $(echo $ST). EC2 requires DHCP on the primary ENI."
fi
if ls /etc/NetworkManager/system-connections/*.nmconnection >/dev/null 2>&1; then
  grep -lE '^\s*mac-address=' /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | \
    while read -r f; do warn "NM keyfile pins MAC: $f"; done
fi
grep -qE 'net\.ifnames=0' /proc/cmdline && info "net.ifnames=0 set: ENA will be eth0." || info "Predictable naming active: ENA will be ens5 (primary ENI on Nitro)."

# ---------- 8. /boot headroom for dracut rebuilds ----------
BOOT_AVAIL_KB="$(df -Pk /boot 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${BOOT_AVAIL_KB:-}" ] && [ "$BOOT_AVAIL_KB" -lt 102400 ]; then
  warn "/boot has <100MB free (${BOOT_AVAIL_KB}KB); initramfs rebuild may fail."
fi

# ---------- 9. Post-cutover management prerequisites ----------
if command -v amazon-ssm-agent >/dev/null 2>&1 || [ -x /snap/bin/amazon-ssm-agent ] || [ -x /usr/bin/amazon-ssm-agent ]; then
  pass "SSM Agent installed."
else
  info "SSM Agent not installed (install via MGN post-launch action or pre-stage)."
fi

# ---------- Summary ----------
echo "RESULT host=${HOST} os=${OS_ID}-${OS_VER} kernel=${KVER} pass=${PASS} warn=${WARN} fail=${FAIL}"
[ "$FAIL" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 1
exit 0
