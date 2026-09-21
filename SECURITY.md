# Security policy

## Threat model

`oma-eng` is a repo of docs, scripts, and libvirt/QEMU config for
running a **Windows 11 guest with Nvidia dGPU passthrough on top of
Omarchy (Arch Linux + Hyprland)**. The security posture is that of
a personal engineering workstation, not a server or a
multi-tenant host.

The guest is treated as **potentially compromised**: Windows,
third-party engineering software, and any code loaded into that
guest are outside the trust boundary. The host protects against
guest-initiated attacks with:

- **VFIO + IOMMU isolation** — the Nvidia dGPU and its audio
  function are bound to `vfio-pci` at boot, in their own IOMMU
  group. DMA is constrained by the hardware IOMMU (VT-d / AMD-Vi).
- **QEMU/KVM sandboxing** — libvirt runs QEMU under a dedicated
  user with restricted capabilities; the guest cannot directly
  reach host filesystems except through the explicit `virtiofs`
  share.
- **Explicit passthrough** — every USB dongle, GPU, or other
  device the guest sees is declared in the libvirt XML. Devices
  not listed are not visible to the guest.

## What *is* documented in this repo that weakens isolation

Two recipes in the docs weaken the default isolation and are called
out where they appear:

- **ACS override kernel patch** (`docs/09-troubleshooting.md`
  § *IOMMU group mixing*). Enabling ACS override forces the kernel
  to treat sibling PCIe devices as if they were behind isolated
  root ports even when the firmware doesn't guarantee it. Theoretical
  attack surface: a compromised guest could DMA into unrelated host
  devices sharing the same root port. Documented as a **last
  resort** — the recommended fix is a different PCIe slot.
- **USB HASP / CmStick dongle passthrough** (`docs/07-strand7-setup.md`,
  `docs/11-etabs-and-spacegass.md`, `configs/libvirt/hasp-dongle.xml`).
  A compromised guest gets bidirectional USB access to any dongle
  passed through. Impact is bounded by what the dongle can do — none
  of the licence dongles this repo lists expose a filesystem or
  storage — but weigh it before passing through anything more
  privileged.

Neither is enabled by default; both require an explicit edit to
`/etc/modprobe.d/vfio.conf`, the kernel cmdline, or
`configs/libvirt/windows-eng.xml`.

## What the repo does *not* try to defend against

- **Compromised host packages.** This repo installs `qemu-full`,
  `libvirt`, `virt-manager`, `edk2-ovmf`, and Looking Glass from
  Arch/Omarchy repos or the AUR. A malicious mirror or AUR package
  is out of scope; use Arch's package signing / AUR review practices.
- **Windows-side supply chain.** Third-party engineering software
  installed inside the guest (Rhino, Strand7, ETABS, SAP2000,
  SpaceGass, Revit, Bluebeam, pyRevit extensions, Grasshopper
  plugins) can do anything a normal Windows program can. Cloud
  workshared Revit models and pyRevit third-party extensions
  especially — treat them with the same suspicion as any downloaded
  code.
- **VPN client vulnerabilities.** VPN topology is documented in
  `docs/13-collaboration-and-backup.md`; the repo doesn't ship or
  configure a VPN client.

## Reporting a vulnerability

If you find a security issue that meaningfully weakens the
threat-model above — for example, a template that leaks host paths
into the guest, a script that runs unsanitised user input as root,
or a doc that recommends a workflow you can demonstrate leads to
host compromise — open a **GitHub Security Advisory** on the repo
(`Security ▸ Advisories ▸ Report a vulnerability` on GitHub) rather
than a public issue.

For anything less severe (a doc typo, a broken command, a config
that fails to define), open a normal GitHub issue.

## Supported versions

There are no "supported" versions in the traditional sense — this
is a rolling repo tracking Omarchy Quattro (v4.x) and Arch's rolling
package set. The current `main` branch is the only supported line.
Old commits work at the point they were current but aren't
maintained.
