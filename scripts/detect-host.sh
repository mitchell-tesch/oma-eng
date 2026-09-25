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
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
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

# Suggested cmdline: hugepages = the template guest's <memory> in GiB.
template_kib="$(sed -n "s|.*<memory unit='KiB'>\([0-9]\+\)</memory>.*|\1|p" \
    "$(dirname "$0")/../configs/libvirt/windows-eng.xml" 2>/dev/null | head -n1)"
guest_gib=$(( ${template_kib:-25165824} / 1048576 ))
suggested_cmdline="$iommu_param iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=$guest_gib"

if [[ $only_cmdline -eq 1 ]]; then
    echo "$suggested_cmdline"
    exit 0
fi

# --- Suggested <vcpupin> block --------------------------------------------
#
# Groups logical CPUs by physical core, then classifies cores into tiers by
# MAXMHZ. On hybrid Intel (12th gen+ / Meteor / Arrow Lake) that separates
# P-cores from E-cores and LP-E-cores; on symmetric AMD/Intel it collapses
# to a single tier. The guest is pinned to top-tier (P-)cores only — mixing
# P and E cores in one guest wrecks QEMU scheduling under CAD/FEA load.
# The host keeps 1 top-tier core (for Hyprland + Looking Glass) plus every
# lower-tier core. Emulator + iothread land on lower-tier cores when
# available; on symmetric CPUs they share the reserved host top-tier core.

print_vcpupin_block() {
    if ! command -v lscpu >/dev/null 2>&1; then
        echo "  (lscpu not available — cannot suggest a vcpupin block.)" >&2
        return 1
    fi

    declare -A core_cpus=()
    declare -A core_maxmhz=()
    local order=()
    while read -r cpu core maxmhz; do
        [[ "$cpu" == "CPU" ]] && continue
        if [[ -z "${core_cpus[$core]+set}" ]]; then
            order+=("$core")
        fi
        core_cpus[$core]+="$cpu "
        local prev="${core_maxmhz[$core]:-0}"
        if awk -v a="$maxmhz" -v b="$prev" 'BEGIN{exit !(a+0 > b+0)}'; then
            core_maxmhz[$core]="$maxmhz"
        fi
    done < <(lscpu -e=CPU,CORE,MAXMHZ 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')

    local total_cores=${#order[@]}
    if (( total_cores < 4 )); then
        echo "  (Only $total_cores physical cores detected — too few to safely pin a CAD guest.)" >&2
        return 1
    fi

    local top_mhz=0
    for c in "${order[@]}"; do
        if awk -v a="${core_maxmhz[$c]}" -v b="$top_mhz" 'BEGIN{exit !(a+0 > b+0)}'; then
            top_mhz="${core_maxmhz[$c]}"
        fi
    done

    # Find the top-tier cutoff by clustering MAXMHZ values: sort them
    # descending and locate the first gap of >= 500 MHz. Everything at or
    # above that gap is top-tier. On symmetric CPUs all cores have the
    # same MAXMHZ and no gap exists; the cutoff falls to 0 and all cores
    # are "top-tier". On hybrid CPUs (Intel 12th gen+/Meteor/Arrow/Raptor
    # Lake) the P-to-E gap is 900-1500 MHz, comfortably above 500. This
    # correctly captures both P-core sub-tiers when Turbo Boost Max 3.0
    # rates two P-cores at 5000 MHz and the rest at 4700 MHz.
    local top_cutoff="$top_mhz"
    local -a sorted_mhz
    mapfile -t sorted_mhz < <(printf '%s\n' "${core_maxmhz[@]}" \
        | awk '{print $1+0}' | sort -rnu)
    local prev=""
    for m in "${sorted_mhz[@]}"; do
        if [[ -n "$prev" ]] && awk -v a="$prev" -v b="$m" 'BEGIN{exit !(a-b >= 500)}'; then
            top_cutoff="$prev"
            break
        fi
        prev="$m"
    done

    is_top_tier() { awk -v a="$1" -v b="$top_cutoff" 'BEGIN{exit !(a+0 >= b+0)}'; }

    local top_cores=() lower_cores=()
    for c in "${order[@]}"; do
        if is_top_tier "${core_maxmhz[$c]}"; then
            top_cores+=("$c")
        else
            lower_cores+=("$c")
        fi
    done

    local hybrid_note=""
    if (( ${#lower_cores[@]} > 0 )); then
        hybrid_note="Hybrid CPU: ${#top_cores[@]} top-tier @ ~${top_mhz%.*} MHz, ${#lower_cores[@]} lower-tier. Guest pinned to top tier only."
    fi

    local host_top=1
    if (( ${#top_cores[@]} - host_top < 3 )); then
        echo "  (Fewer than 3 usable top-tier cores after reserving host — refusing to suggest a bad pinning.)" >&2
        return 1
    fi
    local guest_top=$(( ${#top_cores[@]} - host_top ))

    echo "<!-- Suggested pinning generated by scripts/detect-host.sh --vcpupin"
    echo "     Host: $(hostname)   Date: $(date -Iseconds)"
    if [[ -n "$hybrid_note" ]]; then
        echo "     $hybrid_note"
    fi
    echo "     Guest: ${guest_top} top-tier physical cores x SMT = $(( guest_top * 2 )) vCPUs."
    echo "     Host keeps 1 top-tier core plus all lower-tier cores. -->"
    echo "<vcpu placement='static'>$(( guest_top * 2 ))</vcpu>"
    echo "<cputune>"

    local vcpu=0
    local host_top_cpus=""
    for i in "${!top_cores[@]}"; do
        local core="${top_cores[$i]}"
        local -a cpus
        read -ra cpus <<< "${core_cpus[$core]}"
        if (( i < host_top )); then
            host_top_cpus+="${cpus[*]} "
            continue
        fi
        for cpu in "${cpus[@]}"; do
            printf "  <vcpupin vcpu='%d' cpuset='%s'/>\n" "$vcpu" "$cpu"
            vcpu=$(( vcpu + 1 ))
        done
    done

    # Emulator + iothread: prefer 2 lower-tier cores; else share host top core.
    local emu_cpuset=""
    if (( ${#lower_cores[@]} >= 2 )); then
        local -a lower_expanded=()
        for c in "${lower_cores[@]:0:2}"; do
            read -ra cpus <<< "${core_cpus[$c]}"
            lower_expanded+=("${cpus[@]}")
        done
        emu_cpuset="$(IFS=,; echo "${lower_expanded[*]}")"
    else
        host_top_cpus="${host_top_cpus% }"
        emu_cpuset="${host_top_cpus// /,}"
    fi

    echo "  <emulatorpin cpuset='$emu_cpuset'/>"
    echo "  <iothreadpin iothread='1' cpuset='$emu_cpuset'/>"
    echo "</cputune>"
    echo "<iothreads>1</iothreads>"

    echo "<!-- Matching <cpu> topology (paste over the existing one):"
    echo "     <topology sockets='1' dies='1' cores='${guest_top}' threads='2'/> -->"
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