#!/usr/bin/env bash
# detect-host.sh — print a one-page report on this host's suitability for
# the oma-eng VFIO setup, and print the vendor-specific kernel
# command line to append to /boot/limine.conf.
#
# Works on both Intel and AMD hosts; the discrete GPU is expected to be
# Nvidia in both cases (this repo doesn't do AMD dGPU passthrough).
#
# Usage:  scripts/detect-host.sh
#         scripts/detect-host.sh --cmdline    # print only the cmdline snippet
#         scripts/detect-host.sh --vcpupin    # print a suggested libvirt
#                                             # <vcpupin> block based on this
#                                             # host's live CPU topology

set -euo pipefail

only_cmdline=0
only_vcpupin=0
for arg in "$@"; do
    case "$arg" in
        --cmdline) only_cmdline=1 ;;
        --vcpupin) only_vcpupin=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# --- CPU vendor -----------------------------------------------------------

cpu_vendor="$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)"
cpu_model="$(awk -F: '/model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"

case "$cpu_vendor" in
    GenuineIntel)
        vendor_short="intel"
        virt_flag="vmx"
        iommu_param="intel_iommu=on"
        ucode_pkg="intel-ucode"
        iommu_msg_pattern="DMAR"
        bios_virt_name="VT-x / Intel Virtualization Technology"
        bios_iommu_name="VT-d / Intel Directed I/O"
        ;;
    AuthenticAMD)
        vendor_short="amd"
        virt_flag="svm"
        iommu_param="amd_iommu=on"
        ucode_pkg="amd-ucode"
        iommu_msg_pattern="AMD-Vi|IVRS"
        bios_virt_name="SVM / AMD-V"
        bios_iommu_name="IOMMU / AMD-Vi"
        ;;
    *)
        vendor_short="unknown"
        virt_flag="unknown"
        iommu_param="# UNKNOWN CPU VENDOR"
        ucode_pkg="# unknown"
        iommu_msg_pattern="DMAR|AMD-Vi|IVRS"
        bios_virt_name="virtualization"
        bios_iommu_name="IOMMU"
        ;;
esac

# Suggested cmdline
suggested_cmdline="$iommu_param iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24"

if [[ $only_cmdline -eq 1 ]]; then
    echo "$suggested_cmdline"
    exit 0
fi

# --- Suggested <vcpupin> block --------------------------------------------
#
# Walks `lscpu -e=CPU,CORE` to group logical CPUs by physical core, then
# assigns whole physical cores (with their SMT siblings) to the guest —
# leaving 2 physical cores for the host as a floor. This is a hint, not
# a prescription; users should still verify against `lstopo`.

print_vcpupin_block() {
    if ! command -v lscpu >/dev/null 2>&1; then
        echo "  (lscpu not available — cannot suggest a vcpupin block.)" >&2
        return 1
    fi

    # Map: for each physical core, list its logical CPUs.
    declare -A core_cpus=()
    local order=()
    while read -r cpu core; do
        [[ "$cpu" == "CPU" ]] && continue
        if [[ -z "${core_cpus[$core]+set}" ]]; then
            order+=("$core")
        fi
        core_cpus[$core]+="$cpu "
    done < <(lscpu -e=CPU,CORE 2>/dev/null | awk 'NR>1 {print $1, $2}')

    local total_cores=${#order[@]}
    if (( total_cores < 4 )); then
        echo "  (Only $total_cores physical cores detected — too few to safely pin a CAD guest.)" >&2
        return 1
    fi

    # Reserve the first 2 physical cores for the host; pin the rest.
    local host_cores=2
    local guest_cores=$(( total_cores - host_cores ))

    echo "<!-- Suggested pinning: guest gets $guest_cores physical cores,"
    echo "     host keeps ${host_cores}. Verified against live topology on"
    echo "     $(hostname) at $(date -Iseconds). -->"
    echo "<vcpu placement='static'>$(( guest_cores * 2 ))</vcpu>"
    echo "<cputune>"
    local vcpu=0
    local host_cpus=""
    for i in "${!order[@]}"; do
        local core="${order[$i]}"
        local -a cpus
        read -ra cpus <<< "${core_cpus[$core]}"
        if (( i < host_cores )); then
            host_cpus+="${cpus[*]} "
            continue
        fi
        for cpu in "${cpus[@]}"; do
            printf "  <vcpupin vcpu='%d' cpuset='%s'/>\n" "$vcpu" "$cpu"
            vcpu=$(( vcpu + 1 ))
        done
    done
    # Reduce trailing space and swap internal spaces for commas
    host_cpus="${host_cpus% }"
    local host_cpuset="${host_cpus// /,}"
    echo "  <emulatorpin cpuset='$host_cpuset'/>"
    echo "  <iothreadpin iothread='1' cpuset='$host_cpuset'/>"
    echo "</cputune>"
    echo "<iothreads>1</iothreads>"
}

if [[ $only_vcpupin -eq 1 ]]; then
    print_vcpupin_block
    exit 0
fi

# --- Report ---------------------------------------------------------------

printf '=== oma-eng host detection ===\n\n'
printf 'CPU vendor         : %s (%s)\n' "$cpu_vendor" "$vendor_short"
printf 'CPU model          : %s\n' "$cpu_model"

sockets="$(lscpu | awk -F: '/Socket\(s\)/ {gsub(/ /,"",$2); print $2}')"
cores_per_socket="$(lscpu | awk -F: '/Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}')"
threads_per_core="$(lscpu | awk -F: '/Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}')"
printf 'CPU topology       : %s socket(s) x %s core(s) x %s thread(s) = %s logical CPUs\n' \
    "$sockets" "$cores_per_socket" "$threads_per_core" \
    "$(nproc)"

if grep -q "$virt_flag" /proc/cpuinfo 2>/dev/null; then
    printf 'CPU virt flag (%s) : present\n' "$virt_flag"
else
    printf 'CPU virt flag (%s) : MISSING — enable %s in BIOS\n' "$virt_flag" "$bios_virt_name"
fi

# --- Memory ---------------------------------------------------------------

mem_gib="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
printf 'Total RAM          : %s GiB\n' "$mem_gib"

hp_total="$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)"
hp_size_kb="$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)"
if [[ "${hp_size_kb:-0}" -gt 0 && "${hp_total:-0}" -gt 0 ]]; then
    hp_size_gib=$(( hp_size_kb / 1024 / 1024 ))
    hp_total_gib=$(( hp_total * hp_size_gib ))
    printf 'HugePages reserved : %s x %s GiB = %s GiB\n' "$hp_total" "$hp_size_gib" "$hp_total_gib"
else
    printf 'HugePages reserved : none\n'
fi

# --- IOMMU ---------------------------------------------------------------
#
# On modern Arch/Omarchy `kernel.dmesg_restrict=1` is the default, so
# unprivileged `dmesg` returns nothing. Try the sysfs signal first (it
# doesn't need root and is authoritative on 5.x+); fall back to dmesg
# (with sudo -n if available); fall back to "not enabled".

if [[ -d /sys/kernel/iommu_groups ]] && \
     [[ "$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)" -gt 0 ]]; then
    printf 'IOMMU              : enabled (%s groups in /sys)\n' \
        "$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
elif dmesg 2>/dev/null | grep -qE "$iommu_msg_pattern"; then
    printf 'IOMMU              : enabled (%s messages present)\n' "$iommu_msg_pattern"
elif sudo -n dmesg 2>/dev/null | grep -qE "$iommu_msg_pattern"; then
    printf 'IOMMU              : enabled (dmesg via sudo)\n'
else
    printf 'IOMMU              : NOT enabled (or dmesg_restrict=1 and /sys empty)\n'
    printf '                     If you have not rebooted since editing the\n'
    printf '                     kernel cmdline, do so; else add %s to\n' "$iommu_param"
    printf '                     the "cmdline:" line in /boot/limine.conf.\n'
fi

# --- GPUs ----------------------------------------------------------------

printf '\nGPUs found:\n'
lspci -Dnn | awk '/VGA compatible controller|3D controller/ {
    sub(/^[^ ]+ /, "  ", $0); print
}'

igpu_line="$(lspci -Dnn | awk '/VGA compatible controller/ && (/Intel/ || /AMD/ || /ATI/) {print; exit}')"
if [[ -n "$igpu_line" ]]; then
    if grep -qi 'intel' <<<"$igpu_line"; then
        printf '  iGPU driver     : i915 (Intel)\n'
    elif grep -qiE 'amd|ati' <<<"$igpu_line"; then
        printf '  iGPU driver     : amdgpu (AMD)\n'
        printf '  Note: amdgpu is also used by AMD dGPUs, but your dGPU is Nvidia so no conflict.\n'
    fi
fi

nvidia_lines="$(lspci -Dnn | grep -i nvidia || true)"
if [[ -n "$nvidia_lines" ]]; then
    printf '  Nvidia dGPU     : present\n'
    printf '%s\n' "$nvidia_lines" | sed 's/^/     /'
else
    printf '  Nvidia dGPU     : NOT DETECTED — this repo assumes an Nvidia dGPU for passthrough\n'
fi

# --- Suggested config ----------------------------------------------------

printf '\n=== Suggested configuration for this host ===\n\n'
printf 'Microcode package  : sudo pacman -S --needed %s\n' "$ucode_pkg"
printf 'BIOS settings needed:\n'
printf '  * %s   -> Enabled\n' "$bios_virt_name"
printf '  * %s   -> Enabled\n' "$bios_iommu_name"
printf '  * Above 4G Decoding   -> Enabled\n'
printf '  * Primary Display     -> iGPU\n\n'
printf 'Append to the main "cmdline:" line in /boot/limine.conf:\n'
printf '    %s\n\n' "$suggested_cmdline"
printf 'Then reboot and verify with:  scripts/check-iommu.sh nvidia\n'
printf '\nFor a suggested libvirt <vcpupin> block based on this host,\n'
printf 'run:  scripts/detect-host.sh --vcpupin\n'