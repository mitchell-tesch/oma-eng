# 01 — Hardware & BIOS preparation

Before you touch the OS, make sure the firmware is cooperative. Getting this
step right saves hours of `dmesg` reading later.

This repo supports either **Intel** or **AMD** CPUs (with matching iGPU).
The **discrete GPU is always Nvidia** — AMD dGPU passthrough works
similarly but has its own reset-bug rabbit hole that this repo
deliberately doesn't cover.

## Desktop or laptop? Pick your path

The steps are mostly shared, but a **muxless laptop dGPU** (most laptops
with an Nvidia GPU and Optimus: no display outputs wired to the dGPU)
needs extra pieces. Tell which you have after Omarchy boots:

```bash
scripts/list-pci-for-passthrough.sh 10de
```

If it lists only a **3D controller (class 0302)** and prints the
single-function advisory, follow the laptop column. A VGA controller
(0300) plus an audio function (0403) means desktop.

| | Desktop dGPU | Muxless laptop dGPU |
|---|---|---|
| Host display | Monitor on the **iGPU** outputs | Built-in panel (already iGPU) |
| `vfio.conf` IDs / `<hostdev>` blocks | Every function (VGA + audio, sometimes USB-C) → one `<hostdev>` each ([02 §3](02-host-setup.md), [03 §3](03-vm-provisioning.md)) | The single 3D controller → one `<hostdev>` |
| Looking Glass shared memory | Uncomment `<shmem>` ([04 §2a](04-looking-glass.md)) | `kvmfr` module + `<qemu:commandline>` + 64-bit MMIO cap ([04 §2b](04-looking-glass.md)) |
| What Windows draws on | A monitor or an HDMI/DP **dummy plug** on the dGPU, or the Virtual Display Driver | **Virtual Display Driver required** ([04 §2b](04-looking-glass.md) Fix 3, [05 §4](05-windows-guest.md)) |
| LG client `shmFile` | `/dev/shm/looking-glass` | `/dev/kvmfr0` |
| Input | Looking Glass / SPICE; evdev optional | Same; evdev needs an **external USB** keyboard/mouse |
| Host sleep while VM runs | Blocked by the libvirt hook ([02 §9](02-host-setup.md)) | Same, and matters more (lid close) |
| Expected guest warning | — | *NVIDIA Platform Controllers and Framework* in Device Manager (harmless) |

Either way the dGPU is bound to `vfio-pci` at boot and is **unavailable
to the host**, even while the VM is off; host apps render on the iGPU
([14](14-native-omarchy-tooling.md)).

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
- **Desktop:** Windows must be drawing to a display on the dGPU for
  Looking Glass to capture it. Connect a second monitor, fit a cheap
  HDMI/DP dummy plug, or use the Virtual Display Driver from doc 04 §2b.
  A real monitor on the dGPU also lets you bypass Looking Glass for
  full-screen work.
- Keyboard + mouse stay on the host; Looking Glass forwards them to the
  guest over SPICE. Evdev pass-through (doc 04 §8) is optional and needs
  USB devices, so laptops need an external pair for it.

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
