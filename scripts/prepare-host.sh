#!/usr/bin/env bash
# prepare-host.sh — idempotently prepare an Omarchy (Arch) host for the
# oma-eng VFIO Windows guest.
#
# Does:
#   1. Installs the QEMU/libvirt/OVMF stack.
#   2. Installs the vfio + mkinitcpio drop-ins from this repo (with backup).
#   3. Installs cpu-governor helper, the libvirt qemu hook and the
#      libvirt-guests config (clean guest shutdown on host poweroff).
#   4. Adds the invoking user to libvirt and kvm groups.
#   5. Enables libvirtd + virtlogd sockets and libvirt-guests.service.
#   6. Regenerates the initramfs.
#   7. Warns loudly if an existing host-side Nvidia driver stack would
#      race with vfio-pci for the dGPU (Omarchy pre-installs one).
#   8. Prints follow-up steps (kernel cmdline edit, reboot).
#
# Rerunning is safe. Existing config files are compared and only rewritten
# if changed. Group additions are idempotent.
#
# Usage:
#     scripts/prepare-host.sh                     # run through everything
#     scripts/prepare-host.sh --dry-run           # show what would change
#     scripts/prepare-host.sh --skip-packages     # skip pacman step
#     scripts/prepare-host.sh --remove-nvidia     # also `pacman -Rns` the
#                                                 # host Nvidia driver stack
#                                                 # and delete its config
#                                                 # drop-ins (Path A). Only
#                                                 # do this if the dGPU is
#                                                 # dedicated to the guest.
#     scripts/prepare-host.sh --reset-audio-fn    # bounce the Nvidia HDMI
#         # audio function's PCI reset — useful when the guest fails to
#         # start with "device is not available for use" on the audio
#         # function between VM restarts. Requires root. No-op on muxless
#         # mobile Optimus cards (they have no audio function).

set -euo pipefail

DRY=0
SKIP_PACKAGES=0
RESET_AUDIO_FN=0
REMOVE_NVIDIA=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY=1 ;;
        --skip-packages)  SKIP_PACKAGES=1 ;;
        --reset-audio-fn) RESET_AUDIO_FN=1 ;;
        --remove-nvidia)  REMOVE_NVIDIA=1 ;;
        -h|--help)
            sed -n '2,34p' "$0"; exit 0 ;;
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
    # bridge-utils was dropped from Arch (functionality is in iproute2,
    # which is a base dependency and always present).
    run "$SUDO pacman -Syu --needed --noconfirm \
        qemu-full libvirt virt-manager virt-viewer \
        edk2-ovmf swtpm dnsmasq iptables-nft \
        linux-headers dmidecode ${ucode_pkg}"
else
    echo "  (skipped)"
fi

echo "==> Configs"
install_file "$REPO_ROOT/configs/modprobe.d/vfio.conf"       /etc/modprobe.d/vfio.conf
vfio_ids="$(sed -n 's/^options vfio-pci ids=\([^ ]*\).*/\1/p' "$REPO_ROOT/configs/modprobe.d/vfio.conf")"
for id in ${vfio_ids//,/ }; do
    if [[ -z "$(lspci -n -d "$id" 2>/dev/null)" ]]; then
        printf '  WARN vfio.conf ids=%s: no PCI device %s on this host.\n' "$vfio_ids" "$id"
        printf '       Put your IDs from scripts/list-pci-for-passthrough.sh 10de into\n'
        printf '       configs/modprobe.d/vfio.conf and re-run this script.\n'
    fi
done
install_file "$REPO_ROOT/configs/mkinitcpio.d/vfio.conf"     /etc/mkinitcpio.conf.d/vfio.conf
install_file "$REPO_ROOT/configs/sysctl.d/99-vm-hugepages.conf" /etc/sysctl.d/99-vm-hugepages.conf
install_file "$REPO_ROOT/configs/libvirt/libvirt-guests"     /etc/conf.d/libvirt-guests

# cpu-governor helper + libvirt qemu hook. The hook is invoked by
# libvirtd on every guest state change, so it must be executable and
# owned by root. Also install a Hyprland drop-in for Looking Glass
# window rules, if a Hyprland config directory exists.
if [[ -f "$REPO_ROOT/scripts/cpu-governor" ]]; then
    if [[ ! -x /usr/local/bin/cpu-governor ]] || \
       ! cmp -s "$REPO_ROOT/scripts/cpu-governor" /usr/local/bin/cpu-governor; then
        run "$SUDO install -D -m 755 '$REPO_ROOT/scripts/cpu-governor' /usr/local/bin/cpu-governor"
        printf '  new /usr/local/bin/cpu-governor\n'
    else
        printf '  ok  /usr/local/bin/cpu-governor (unchanged)\n'
    fi
fi
if [[ -f "$REPO_ROOT/configs/libvirt/hooks/qemu" ]]; then
    if [[ ! -x /etc/libvirt/hooks/qemu ]] || \
       ! cmp -s "$REPO_ROOT/configs/libvirt/hooks/qemu" /etc/libvirt/hooks/qemu; then
        run "$SUDO install -D -m 755 '$REPO_ROOT/configs/libvirt/hooks/qemu' /etc/libvirt/hooks/qemu"
        printf '  new /etc/libvirt/hooks/qemu\n'
    else
        printf '  ok  /etc/libvirt/hooks/qemu (unchanged)\n'
    fi
fi
if [[ -d "$REPO_ROOT/configs/hypr" && -d "${XDG_CONFIG_HOME:-$HOME/.config}/hypr" ]]; then
    hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
    # Omarchy quattro+ uses a Lua config; older Hyprland uses hyprland.conf.
    if [[ -f "$hypr_dir/hyprland.lua" ]]; then
        hypr_src="$REPO_ROOT/configs/hypr/looking-glass.lua"
        hypr_main="$hypr_dir/hyprland.lua"
        hypr_hook='require("hypr.looking-glass")'
    else
        hypr_src="$REPO_ROOT/configs/hypr/looking-glass.conf"
        hypr_main="$hypr_dir/hyprland.conf"
        hypr_hook='source = ~/.config/hypr/looking-glass.conf'
    fi
    hypr_target="$hypr_dir/$(basename "$hypr_src")"
    if [[ ! -f "$hypr_target" ]] || ! cmp -s "$hypr_src" "$hypr_target"; then
        run "install -D -m 644 '$hypr_src' '$hypr_target'"
        printf '  new %s\n' "$hypr_target"
    else
        printf '  ok  %s (unchanged)\n' "$hypr_target"
    fi
    if ! grep -qF "$hypr_hook" "$hypr_main" 2>/dev/null; then
        printf '        Add `%s` to %s\n' "$hypr_hook" "$hypr_main"
    fi
fi

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

# --- Nvidia driver-stack conflict guard -------------------------------------
# Omarchy's installer offers to enable the Nvidia driver during setup;
# on any machine where that was taken (or where nvidia-open-dkms was
# installed for host CUDA), the resulting drop-ins race with the vfio
# drop-in for the dGPU at boot. Detect and either warn or clean up.
echo "==> Nvidia driver conflict check"
nv_pkg=""
if command -v pacman >/dev/null 2>&1; then
    nv_pkg="$(pacman -Qq 2>/dev/null | grep -E '^(nvidia|nvidia-open|nvidia-open-dkms|nvidia-dkms|nvidia-lts)$' | paste -sd, - || true)"
fi
nv_conflicts=()
[[ -n "$nv_pkg" ]]                            && nv_conflicts+=("package: $nv_pkg")
[[ -f /etc/modprobe.d/nvidia.conf ]]          && nv_conflicts+=("/etc/modprobe.d/nvidia.conf")
[[ -f /etc/mkinitcpio.conf.d/nvidia.conf ]]   && nv_conflicts+=("/etc/mkinitcpio.conf.d/nvidia.conf")

if (( ${#nv_conflicts[@]} == 0 )); then
    printf '  ok  no host-side Nvidia driver stack detected\n'
elif [[ $REMOVE_NVIDIA -eq 1 ]]; then
    echo "  found and REMOVING (Path A) — pass without --remove-nvidia to skip:"
    for c in "${nv_conflicts[@]}"; do printf '    - %s\n' "$c"; done
    if [[ -n "$nv_pkg" ]]; then
        run "$SUDO pacman -Rns --noconfirm ${nv_pkg//,/ }"
    fi
    for f in /etc/modprobe.d/nvidia.conf /etc/mkinitcpio.conf.d/nvidia.conf; do
        [[ -f "$f" ]] && run "$SUDO rm -f '$f'" && printf '    removed %s\n' "$f"
    done
else
    echo "  WARNING: host-side Nvidia driver stack present. It will race with"
    echo "           vfio-pci for the dGPU at boot; nvidia_drm may claim the"
    echo "           card before vfio-pci binds. Found:"
    for c in "${nv_conflicts[@]}"; do printf '    - %s\n' "$c"; done
    echo "           Path A (recommended for dedicated-guest dGPUs): rerun as"
    echo "               sudo scripts/prepare-host.sh --remove-nvidia"
    echo "           Path B: keep the Nvidia stack and add a libvirt prepare/"
    echo "           release hook that unbinds nvidia and binds vfio-pci on"
    echo "           guest start (not shipped in this repo)."
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
# libvirt-guests gives the guest a clean ACPI shutdown on host poweroff.
for svc in libvirtd.socket virtlogd.socket libvirt-guests.service; do
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

# On Omarchy 4.x and other Arch setups that boot a UKI at /boot/EFI/Linux/
# omarchy_linux.efi, the UKI holds a baked copy of the initramfs AND the
# kernel command line. `mkinitcpio -P` on its own does NOT rebuild the
# UKI when invoked outside a pacman transaction — only the pacman hook
# from `limine-mkinitcpio-hook` does. Call limine-update directly so the
# UKI picks up the vfio drop-in we just installed. Harmless on systems
# without a UKI (limine-update is idempotent).
if command -v limine-update >/dev/null 2>&1 && [[ -d /boot/EFI/Linux ]]; then
    echo "==> UKI rebuild (limine-update)"
    if [[ $DRY -eq 0 ]]; then
        $SUDO limine-update
    else
        echo "  [dry-run] $SUDO limine-update"
    fi
fi

echo
echo "Follow-up (not automated, deliberately):"
echo

case "$vendor_short" in
    intel) iommu_param="intel_iommu=on" ;;
    amd)   iommu_param="amd_iommu=on"   ;;
    *)     iommu_param="# UNKNOWN CPU vendor; edit manually" ;;
esac

echo "  1. Add the VFIO tokens to the kernel cmdline. The helper handles"
echo "     Omarchy's /etc/kernel/cmdline + UKI rebuild + limine-update"
echo "     in one step:"
echo
echo "         sudo ./scripts/set-cmdline"
echo
echo "     Or manually edit /etc/kernel/cmdline (Omarchy quattro default)"
echo "     and append:"
echo
echo "     $iommu_param iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=$(( $(sed -n "s|.*<memory unit='KiB'>\([0-9]\+\)</memory>.*|\1|p" "$REPO_ROOT/configs/libvirt/windows-eng.xml" | head -n1) / 1048576 ))"
echo
echo "     Then rebuild the UKI + limine.conf: sudo limine-update"
echo "  2. Reboot."
echo "  3. Run: scripts/check-iommu.sh nvidia"
echo "     Confirm the Nvidia device(s) are alone in their IOMMU group"
echo "     (or grouped only with their PCIe root port)."
echo "  4. Run: lspci -nnk -d 10de:*"
echo "     Confirm 'Kernel driver in use: vfio-pci' on every Nvidia function"
echo "     listed by scripts/list-pci-for-passthrough.sh 10de — one function"
echo "     on muxless mobile Optimus cards, usually two (VGA + audio) on"
echo "     desktop cards."
