#!/usr/bin/env bash
# check-iommu.sh — enumerate IOMMU groups so you can see which devices share
# a group with your Nvidia dGPU.
#
# Usage:
#     scripts/check-iommu.sh              # list every group
#     scripts/check-iommu.sh nvidia       # only groups containing the pattern
#
# Interpretation: for VFIO passthrough to work cleanly, the Nvidia VGA
# (class 0300) and its Audio (0403) functions should be in a group either
# alone or with only their PCIe root port. If they share a group with an
# unrelated device (NIC, NVMe, SATA controller) either move the card to a
# different slot or apply the ACS override kernel patch — see
# docs/09-troubleshooting.md.

set -euo pipefail

filter="${1:-}"

if [[ ! -d /sys/kernel/iommu_groups ]]; then
    echo "IOMMU is not enabled. Confirm 'intel_iommu=on' (Intel) or"
    echo "'amd_iommu=on' (AMD) in kernel cmdline:"
    echo "    $(cat /proc/cmdline)"
    exit 1
fi

shopt -s nullglob
# Sort IOMMU group ids numerically. Using `-printf %f` keeps the sort
# independent of the /sys/kernel/iommu_groups path depth.
while IFS= read -r gid; do
    [[ -z "$gid" ]] && continue
    g="/sys/kernel/iommu_groups/$gid"
    block=""
    for d in "$g"/devices/*; do
        addr=${d##*/}
        info=$(lspci -nns "${addr#0000:}")
        block+="  ${info}"$'\n'
    done
    if [[ -z "$filter" || "$block" == *"$filter"* ]]; then
        printf "IOMMU group %s:\n%s\n" "$gid" "$block"
    fi
done < <(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -n)
