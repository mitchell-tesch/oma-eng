#!/usr/bin/env bash
# prepare-host.sh — idempotently prepare an Omarchy (Arch) host for the
# rhino-omarchy VFIO Windows guest.
#
# Does:
#   1. Installs the QEMU/libvirt/OVMF stack.
#   2. Installs the vfio + mkinitcpio drop-ins from this repo (with backup).
#   3. Adds the invoking user to libvirt and kvm groups.
#   4. Enables libvirtd + virtlogd sockets.
#   5. Regenerates the initramfs.
#   6. Prints follow-up steps (kernel cmdline edit, reboot).
#
# Rerunning is safe. Existing config files are compared and only rewritten
# if changed. Group additions are idempotent.
#
# Usage:
#     scripts/prepare-host.sh                     # run through everything
#     scripts/prepare-host.sh --dry-run           # show what would change
#     scripts/prepare-host.sh --skip-packages     # skip pacman step
#     scripts/prepare-host.sh --reset-audio-fn    # bounce the Nvidia HDMI
#         # audio function's PCI reset — useful when the guest fails to
#         # start with "device is not available for use" on the audio
#         # function between VM restarts. Requires root.

set -euo pipefail

DRY=0
SKIP_PACKAGES=0
RESET_AUDIO_FN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY=1 ;;
        --skip-packages)  SKIP_PACKAGES=1 ;;
        --reset-audio-fn) RESET_AUDIO_FN=1 ;;
        -h|--help)
            sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# --- --reset-audio-fn short-circuit ---------------------------------------
# Bounces the reset line on every Nvidia audio-function device (class 0403,
# vendor 10de) currently bound to vfio-pci. Idempotent — if the device is
# already responsive the write is a no-op.
if [[ $RESET_AUDIO_FN -eq 1 ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "--reset-audio-fn requires root." >&2
        exit 1
    fi
    found=0
    while read -r addr _; do
        [[ -z "$addr" ]] && continue
        reset_path="/sys/bus/pci/devices/0000:${addr}/reset"
        if [[ ! -w "$reset_path" ]]; then
            printf '  skip 0000:%s — %s not writable\n' "$addr" "$reset_path"
            continue
        fi
        if [[ $DRY -eq 1 ]]; then
            printf '  [dry-run] echo 1 > %s\n' "$reset_path"
        else
            echo 1 > "$reset_path"
            printf '  reset 0000:%s\n' "$addr"
        fi
        found=$(( found + 1 ))
    done < <(lspci -Dn | awk '/^[0-9a-f:.]+ 0403: 10de:/ {sub(/^0000:/,"",$1); print $1}')
    if [[ $found -eq 0 ]]; then
        echo "No Nvidia audio function found (class 0403, vendor 10de)."
    fi
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
run() {
    if [[ $DRY -eq 1 ]]; then
        printf '  [dry-run] %s\n' "$*"
    else
        eval "$*"
    fi
}

need_sudo() {
    if [[ $EUID -ne 0 ]]; then
        SUDO=sudo
    else
        SUDO=""
    fi
}
need_sudo

install_file() {
    local src="$1" dest="$2"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        printf '  ok  %s (unchanged)\n' "$dest"
        return
    fi
    if [[ -f "$dest" ]]; then
        run "$SUDO cp -a '$dest' '$dest.bak.$(date +%s)'"
    fi
    run "$SUDO install -D -m 644 '$src' '$dest'"
    printf '  new %s\n' "$dest"
}

echo "==> Packages"

# Detect CPU vendor so we install the right microcode.
cpu_vendor="$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)"
case "$cpu_vendor" in
    GenuineIntel) ucode_pkg="intel-ucode"; vendor_short="intel" ;;
    AuthenticAMD) ucode_pkg="amd-ucode"  ; vendor_short="amd"   ;;
    *)            ucode_pkg=""           ; vendor_short="unknown" ;;
esac
printf '  CPU vendor: %s -> microcode: %s\n' "$vendor_short" "${ucode_pkg:-<unknown>}"

if [[ $SKIP_PACKAGES -eq 0 ]]; then
    run "$SUDO pacman -Syu --needed --noconfirm \
        qemu-full libvirt virt-manager virt-viewer \
        edk2-ovmf swtpm dnsmasq iptables-nft bridge-utils \
        linux-headers dmidecode ${ucode_pkg}"
else
    echo "  (skipped)"
fi

echo "==> Configs"
install_file "$REPO_ROOT/configs/modprobe.d/vfio.conf"       /etc/modprobe.d/vfio.conf
install_file "$REPO_ROOT/configs/mkinitcpio.d/vfio.conf"     /etc/mkinitcpio.conf.d/vfio.conf 2>/dev/null || true
install_file "$REPO_ROOT/configs/sysctl.d/99-vm-hugepages.conf" /etc/sysctl.d/99-vm-hugepages.conf

# The mkinitcpio drop-in above uses MODULES+= so it's additive. On
# mkinitcpio 39+ (current Arch/Omarchy) it's picked up automatically.
# On older mkinitcpio the drop-in is ignored and the main config must be
# edited by hand — check either place for vfio_pci.
if ! grep -q 'vfio_pci' /etc/mkinitcpio.conf 2>/dev/null && \
   ! grep -hq 'vfio_pci' /etc/mkinitcpio.conf.d/*.conf 2>/dev/null; then
    echo "  NOTE: vfio_pci not found in /etc/mkinitcpio.conf or"
    echo "        /etc/mkinitcpio.conf.d/. Ensure the drop-in installed"
    echo "        cleanly, or add MODULES+=(vfio_pci vfio vfio_iommu_type1)"
    echo "        to /etc/mkinitcpio.conf manually."
fi

echo "==> Groups"
target_user="${SUDO_USER:-$USER}"
for g in libvirt kvm; do
    if id -nG "$target_user" | grep -qw "$g"; then
        printf '  ok  %s already in %s\n' "$target_user" "$g"
    else
        run "$SUDO usermod -aG $g $target_user"
        printf '  add %s -> %s (log out to apply)\n' "$target_user" "$g"
    fi
done

echo "==> Services"
for svc in libvirtd.socket virtlogd.socket; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        printf '  ok  %s enabled\n' "$svc"
    else
        run "$SUDO systemctl enable --now $svc"
    fi
done

echo "==> Initramfs"
if [[ $DRY -eq 0 ]]; then
    $SUDO mkinitcpio -P
else
    echo "  [dry-run] $SUDO mkinitcpio -P"
fi

echo
echo "Follow-up (not automated, deliberately):"
echo

# Vendor-specific cmdline suggestion
case "$vendor_short" in
    intel) iommu_param="intel_iommu=on" ;;
    amd)   iommu_param="amd_iommu=on"   ;;
    *)     iommu_param="# UNKNOWN CPU vendor; edit manually" ;;
esac

echo "  1. Edit /boot/limine.conf (Omarchy quattro default) and append"
echo "     to the 'cmdline:' line of the main Omarchy Linux entry:"
echo
echo "     $iommu_param iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24"
echo
echo "     (Older Omarchy on systemd-boot: /boot/loader/entries/*_linux.conf)"
echo "     For a full report of what your machine needs, run: scripts/detect-host.sh"
echo "  2. Reboot."
echo "  3. Run: scripts/check-iommu.sh nvidia"
echo "     Confirm the Nvidia VGA + Audio functions are in a clean group."
echo "  4. Run: lspci -nnk -d 10de:*"
echo "     Confirm 'Kernel driver in use: vfio-pci' on both functions."
