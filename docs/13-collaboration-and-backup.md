# 13 — Bluebeam Revu + collaboration workflows

This doc covers the rest of the engineering-office toolchain that
surrounds the CAD / FEA stack: drawing markup, cloud storage, VPN,
corporate licence servers, and backup. None of it is CAD, all of it
matters if you work in a real firm.

Read after [12 — Revit + Rhino.Inside.Revit + pyRevit](12-revit-and-rhino-inside.md).

## Bluebeam Revu

Windows-only PDF markup tool. Industry-standard in AEC for drawing
review, RFI markup, and QA/QC across drawing sets. Revu's *Sets*
mode handles thousand-page packages faster than any browser-based
alternative and is the reason Bluebeam sticks around in every
engineering office.

### Where Revu lives

Same VFIO guest as the rest of the stack. Reasons:

- Revit's PDF export → Bluebeam markup → back to Revit is a common
  round-trip. Keeping both in one Windows session avoids file
  shuttling.
- Studio Sessions (§ below) work with the guest's virtio-net just
  fine — no passthrough required.
- Revu isn't a heavy user of RAM (2–4 GB with a large drawing set),
  so it doesn't push the RAM sizing further than doc 12.

### Install

1. Download the Revu installer from the Bluebeam licensed-users
   portal to the Omarchy host, drop into
   `~/src/oma-eng/src/vendor/`, and run from `Z:\vendor\` in the
   guest.
2. Install with defaults.
3. First launch prompts for a licence key or Bluebeam ID sign-in.

### Licence

| Licence | In the guest? | Notes |
|---|---|---|
| **Revu 21+ subscription** (Vector releases, 2024+) | ✅ | Sign in through the app with your Bluebeam ID; per-user seat, works across your VMs. |
| **Revu 20 and earlier perpetual** | ✅ | Machine-locked. Reactivation may be needed after guest XML edits (CPU pinning, memory bumps) — treat those as "final" once you've activated, or move to a subscription. |
| **Bluebeam Enterprise / Studio Prime** | ✅ | MSI + your firm's licence server. Standard Windows install; point Revu at your licence server on first launch. |

### Studio Projects and Studio Sessions

Bluebeam Studio hosts documents on Bluebeam's cloud
(`studio.bluebeam.com`) so multiple markup users see edits in real
time. Nothing special about running Studio from a VM — it's HTTPS to
Bluebeam's servers over the guest's virtio-net.

- **Studio Projects** — checked-out documents with per-user file
  locks, similar to Git.
- **Studio Sessions** — live collaborative markup on a single PDF
  with per-user layers.

If your firm runs the on-prem **Studio Prime** server instead of the
cloud offering, point Revu at `studio.your-firm.example.com` in
*Studio ▸ Manage Servers*. The guest reaches it via VPN or LAN —
same routing story as any other network service (§ VPN below).

### Scripting — JavaScript Actions

Revu exposes a JavaScript-based scripting model via
*Tools ▸ Batch* and *Tools ▸ Actions*. Actions accept JS that
manipulates markups, extracts data, applies stamps, or renames pages
in bulk. Documented in the shipped *Revu Scripting Reference* PDF
(*Help ▸ Scripting Reference*).

Because Actions run inside Revu (not from a shell), there's no
edit-on-Omarchy debugger story here — but you can keep your Action
`.rmv` scripts and Batch definition files in
`~/src/oma-eng/src/bluebeam-actions/` on Omarchy and import them
into Revu from `Z:\bluebeam-actions\`.

## Cloud storage

Every engineering office lives inside at least one cloud drive.
Where you run the sync client matters:

| Provider | Client in the guest | Client on Omarchy | Notes |
|---|---|---|---|
| **OneDrive / SharePoint** | ✅ Recommended default. Native Windows integration means Revit / Excel / Bluebeam see files as if local. Autodesk Cloud Model + Autodesk Docs pair with OneDrive. | Possible via `rclone`, `onedriver`, or [`abraunegg/onedrive`](https://github.com/abraunegg/onedrive), but no COM integration. | Sync in-guest for anything Revit/Bluebeam-authored. |
| **Aconex (Oracle)** | Browser-based, no client. | Browser-based, no client. | Chromium / Firefox on Omarchy or Edge in the guest. Transmittals import as PDFs — open with Bluebeam in the guest. |
| **Procore** | Browser-based, no client. | Browser-based, no client. | Same as Aconex. |
| **Dropbox** | Native Windows client works. | Native Linux client is officially supported. | Dropbox on Omarchy + virtiofs is a viable single-sync pattern. |
| **Google Drive** | Google Drive for Desktop supported. | `rclone` mount or `google-drive-ocamlfuse`. | Same trade-off as OneDrive. |
| **Autodesk Docs / BIM 360** | ✅ Required for Revit cloud-workshared models. | Not applicable. | Cloud-worksharing needs the Autodesk Docs client in the same session as Revit. |

### Recommended pattern

- **CAD / BIM working files** (`.rvt`, `.3dm`, `.st7`, `.edb`, `.SG`)
  — sync on OneDrive or Autodesk Docs **inside the guest**. This
  gives Revit's Cloud Model, Autodesk Docs, and Windows Explorer
  coherent state.
- **Source code and scripts** — keep on **Omarchy** under
  `~/src/oma-eng/src/`. virtiofs exposes them to the guest as `Z:\`
  (see [doc 08](08-api-development.md)). Do all `git` work on
  Omarchy.
- **Received drawings and RFIs** — download to `~/oma-eng-inbox/`
  on Omarchy, expose over virtiofs, open with Bluebeam in the guest.

Don't put the guest disk image (`.qcow2`) inside any cloud sync
folder — sync clients trip over the constant writes and can corrupt
the image.

## VPN and corporate networks

Two topology choices — pick one.

**A) VPN on Omarchy (recommended for most cases).**

- Install the VPN client on the host: WireGuard (`wireguard-tools` is
  usually preinstalled), OpenVPN (`sudo pacman -S openvpn`), or a
  vendor Cisco AnyConnect via `openconnect`
  (`sudo pacman -S openconnect`).
- The guest inherits routing through the host's default gateway, so
  any hostname the host reaches, the guest reaches too.
- Advantage: one VPN session for both machines, no Windows-specific
  quirks.

**B) VPN inside the guest.**

- Install the vendor Windows client inside Windows. Common when your
  firm mandates a specific vendor plugin (Palo Alto GlobalProtect
  with SAML SSO, Zscaler with client posture checks, etc.) that has
  no Linux port.
- Only the guest-side apps see the VPN; Omarchy-side tools (git,
  VS Code Remote-SSH to a corporate SSH bastion) don't.
- Advantage: mirrors a colleague's Windows-only setup exactly.

**Incoming connections.** The libvirt `default` network is NAT — the
guest can reach anything the host reaches, but LAN devices can't
reach the guest directly. If a colleague needs to hit your guest's
SPACE GASS REST endpoint or the OpenSSH server from another machine
on the LAN, switch the guest's `<interface>` to a `bridge` network.
See libvirt's *network bridging* docs.

## Corporate licence servers

Most firms run one of:

| Vendor | Server / protocol | Product family |
|---|---|---|
| Autodesk | NLM / LMTOOLS (`lmgrd` + `adskflex`) | Revit, AutoCAD, Civil 3D |
| Computers and Structures | Reprise (RLM) | ETABS, SAP2000 |
| Strand7 Pty Ltd | Sentinel HASP LM (`hasplm`) | Strand7 R3 network licences |
| SPACE GASS | CodeMeter (WIBU) network / SentinelHASP LM | SPACE GASS network licences |
| Bentley | FlexNet (`lmgrd` / `lmutil`) | RAM, STAAD |
| Trimble | Tekla licence server | Tekla Structures |
| Bluebeam | Studio Prime licence server (SLS) | Revu Enterprise |

All are network services on a fixed port. Once the guest can reach
the licence server (via one of the VPN choices above), point each
app at `port@licence-host` in its own licence dialog. No `<hostdev>`
USB passthrough is required — that's only for physical dongles
(doc 07 § HASP dongle, doc 11 § Physical dongles).

Verify reachability from an admin PowerShell in the guest before
you configure the app:

```powershell
Test-NetConnection -ComputerName licence-host.example.local -Port 5054
Test-NetConnection -ComputerName licence-host.example.local -Port 27000
```

## Backup strategy

Five things to back up, on different schedules:

| What | Where | Frequency | How |
|---|---|---|---|
| **Guest disk image** (`/var/lib/libvirt/images/windows-cad.qcow2`) | External drive or NAS | Weekly + before major Revit / ETABS updates | Shut down the guest cleanly, then `qemu-img convert -O qcow2 -c` to a copy on the backup target. Live backups risk a torn image. |
| **Virtiofs source tree** (`~/src/oma-eng/`) | Git remote (GitHub / GitLab / self-hosted) | Every commit | Standard `git push`. No extra tooling. |
| **Guest `%APPDATA%` state** for Autodesk / pyRevit / Rhino / Bluebeam | Inside the guest disk image (covered) or a virtiofs-mounted host folder | Weekly | If you want per-app backups separate from the qcow2, use `robocopy /MIR` in the guest to a virtiofs-mounted host folder. |
| **libvirt XML** (`configs/libvirt/windows-cad.xml`) | Git | Every edit | Already tracked in this repo. |
| **Licence dongles** (physical HASP / CmStick sticks) | Locked drawer + a text file with each dongle's `lsusb` vendor:product IDs and a photo of the label | On receipt | Losing a physical dongle is a real business cost. Take a photo of the ID label and record the `lsusb` output at first plug-in so a replacement can be ordered against the right IDs. |

**Snapshots aren't backup.** `virsh snapshot-create-as` writes into
the same qcow2 file — a corrupted image loses every snapshot with
it. Use snapshots for "before big change" checkpoints during a
session; use `qemu-img convert` for offsite backup.

**Windows activation.** Sign into Windows with a Microsoft account
on first boot, or record the retail key. If the guest disk is ever
lost, activation moves with the account. Store the Autodesk / CSi /
Strand7 / SPACE GASS / Bluebeam licence keys and serial numbers in
your password manager — not the guest disk.

## Exit criteria

- Bluebeam Revu opens in the guest, activated, no warnings.
- A drawing PDF from the virtiofs share opens with Revu, rotates,
  and marks up cleanly.
- Your firm's cloud storage is accessible from wherever you chose
  (host or guest), and drawing files open in Revit / Revu from that
  location.
- Corporate licence server(s) answer `Test-NetConnection` from an
  admin PowerShell in the guest.
- You have a documented backup for guest disk image + source tree +
  dongle IDs.

Back to [README](../README.md).
