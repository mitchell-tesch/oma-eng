# 01 — Hardware & BIOS preparation

Before you touch the OS, make sure the firmware is cooperative. Getting this
step right saves hours of `dmesg` reading later.

This repo supports either **Intel** or **AMD** CPUs (with matching iGPU).
The **discrete GPU is always Nvidia** — AMD dGPU passthrough works
similarly but has its own reset-bug rabbit hole that this repo
deliberately doesn't cover.

## Confirm the CPU supports virtualisation + IOMMU

```bash
# From an already-installed Omarchy:
scripts/detect-host.sh
```

That prints a full report — CPU vendor, virt flag presence, IOMMU state,
GPUs found, and the exact kernel cmdline to append later.

Manual check:

```bash
grep -Eom1 '(vmx|svm)' /proc/cpuinfo   # vmx = Intel VT-x, svm = AMD-V
lscpu | grep -i virtualization
```

- **Intel**: expect `vmx`. VT-d (IOMMU) is a separate CPU/chipset
  feature — check the CPU on Intel ARK. Most desktop CPUs since Haswell
  support it; most server/HEDT parts always have.
- **AMD**: expect `svm`. IOMMU is a chipset feature — supported on all
  X570/B550/X670/B650/TRX40/TRX50 boards, most Ryzen-era boards even
  before that. Check the motherboard manual if in doubt.

## BIOS/UEFI settings

Enter firmware setup and set the following. Names vary — Intel calls
them one thing, AMD calls them another, and vendor menus vary further.

| What you're enabling | Intel name | AMD name | Value |
|---|---|---|---|
| Base virtualisation | Intel Virtualization Technology / **VT-x** | **SVM** / AMD-V / SVM Mode | Enabled |
| **IOMMU** | **VT-d** / Intel Directed I/O | **IOMMU** / AMD-Vi | **Enabled** (non-negotiable) |
| Large BAR support | Above 4G Decoding | Above 4G Decoding | Enabled |
| Resizable BAR | Re-Size BAR Support | Resizable BAR | Enabled (helps big-VRAM cards) |
| Primary display | Primary Display / iGPU Multi-Monitor | Integrated Graphics / IGD Multi-Monitor | **iGPU** as primary |
| Secure Boot | Secure Boot | Secure Boot | **Disabled** for first pass, re-enable later |
| CSM / Legacy Boot | CSM Support | CSM Support | Disabled — must be UEFI-only |
| SR-IOV | SR-IOV Support | SR-IOV Support | Enabled if present — harmless |
| CPU C-States | C-States | Global C-state Control | Leave default |
| Hyper-Threading / SMT | Hyper-Threading | SMT Mode | Enabled — we pin cores in the XML |

AMD-specific gotchas:

- On some Ryzen boards, IOMMU is set to *Auto* by default and does
  **not** actually enable — force it to **Enabled**.
- On older X470/B450 boards, you may need to update the BIOS to get
  usable IOMMU groups.
- If your BIOS has an *ACS* option, leave it default; the ACS override
  patch is a kernel-side workaround, not a BIOS toggle.

## Physical layout

- Connect at least one monitor to the **iGPU display outputs** on the
  motherboard. This is what Hyprland will drive.
- **Optionally** connect a second monitor to the Nvidia dGPU. It will be
  black while Windows isn't running; when the VM starts, this becomes the
  guest's native display and can be used for full-screen CAD work if you
  ever want to bypass Looking Glass.
- Keep a USB keyboard + mouse pair for the host. The guest will use them
  via evdev pass-through (a hot-key switches focus), so you don't need a
  second pair — but a spare set on a USB switch is a nice fallback.

## Verify IOMMU groups after Linux boot

You'll do this properly in [02 — Host setup](02-host-setup.md), but the
short version is: the Nvidia dGPU and its HDMI audio function need to be
alone (or with only their PCIe root port) in an IOMMU group, otherwise you
either bind the wrong things to vfio-pci or use the ACS override patch. The
[`scripts/check-iommu.sh`](../scripts/check-iommu.sh) helper prints the
groups for you.

If your board puts the dGPU in a group with unrelated devices (network,
NVMe, etc.), options are:

1. Try a different PCIe slot — often changes grouping.
2. Live with the ACS override patch (custom kernel). Documented in
   [09 — Troubleshooting](09-troubleshooting.md); avoid if you can.

## Exit criteria

- Firmware boots Omarchy from the iGPU.
- On **Intel** hosts: `dmesg | grep -i -e DMAR -e IOMMU` (run after
  [02](02-host-setup.md)) shows `DMAR: IOMMU enabled` and
  `DMAR: Intel(R) Virtualization Technology for Directed I/O`.
- On **AMD** hosts: `dmesg | grep -Ei 'AMD-Vi|IVRS'` shows
  `AMD-Vi: AMD IOMMUv2 loaded and initialized` or equivalent.
- `lspci -nn | grep -i nvidia` sees your dGPU.
- You can boot Omarchy with the Nvidia card physically installed but
  *not* being used as the primary display.

Continue to [02 — Host (Omarchy) setup](02-host-setup.md).
