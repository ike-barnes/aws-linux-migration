#!/usr/bin/env bash
# collect-facts.sh — print ONE CSV row of facts about this server.
# Read-only. Works on RHEL/CentOS 6-9 and Ubuntu.
#
# Run on a single server:   sudo bash collect-facts.sh
# Run across many servers from a jump host (hostlist.txt = one hostname per line):
#   for h in $(cat hostlist.txt); do ssh "$h" 'sudo bash -s' < scripts/collect-facts.sh; done >> inventory/hosts.csv
#
# Output columns match the first 9 columns of inventory/hosts-template.csv.
# You fill in the rest (environment, application, owner, wave, dates) with the app owners.

set -u
HOST="$(hostname -f 2>/dev/null || hostname)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP" ] && IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"

if [ -r /etc/os-release ]; then
  . /etc/os-release; OS="${ID:-unknown}"; VER="${VERSION_ID:-unknown}"
else
  OS="$(grep -qi centos /etc/redhat-release && echo centos || echo rhel)"
  VER="$(grep -oE '[0-9]+(\.[0-9]+)+' /etc/redhat-release | head -1)"
fi

KERNEL="$(uname -r)"
CPUS="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
RAM_GB="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)"
DISK_GB="$(lsblk -dbno SIZE,TYPE 2>/dev/null | awk '$2=="disk"{s+=$1} END{printf "%.0f", s/1024/1024/1024}')"
[ -d /sys/firmware/efi ] && BOOT="UEFI" || BOOT="BIOS"

echo "${HOST},${IP},${OS},${VER},${KERNEL},${CPUS},${RAM_GB},${DISK_GB},${BOOT},,,,,,,,,"
