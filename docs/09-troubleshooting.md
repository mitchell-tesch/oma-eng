# 09 — Troubleshooting playbook

The failure modes here are almost all one-time — you hit one, fix it,
never see it again. Grouped by symptom. For a failed VM start, read
`/var/log/libvirt/qemu/windows-eng.log` first
([When all else fails](#when-all-else-fails)).

**Sections:**
[Host / VFIO](#host--vfio-problems) ·
[Looking Glass](#looking-glass-problems) ·
[Rhino / Grasshopper](#rhino--grasshopper) ·
[Strand7](#strand7) ·
[Guest sessions + drive letters](#guest-sessions-and-virtiofs-drive-letters) ·
[Python](#python) ·
[Office / Excel](#office--excel) ·
[ETABS / SAP2000 OAPI](#csi-etabs--sap2000-oapi) ·
[Host performance](#host-performance-regressions) ·
[libvirt / VM management](#libvirt--vm-management) ·
[Native Omarchy tooling](#native-omarchy-tooling-freecad--bonsai--jupyter--handcalcs) ·
[When all else fails](#when-all-else-fails)

**Find by message or symptom:**

| You see | Entry |
|---|---|
| `Hugepagesize: 2048 kB` after a reboot | [Hugepagesize stays at 2048 kB](#hugepagesize-stays-at-2048-kb-after-set-cmdline--limine-update--reboot) |
| `Kernel driver in use: nvidia` / `nouveau` | [Host driver claims the card](#kernel-driver-in-use-nvidia-or-nouveau-after-reboot), [Omarchy Nvidia stack](#omarchy-nvidia-driver-stack-racing-vfio-pci) |
| `not IOMMU-safe`, dGPU shares an IOMMU group | [IOMMU group mixing](#iommu-group-mixing-nvidia-grouped-with-unrelated-devices) |
| Device Manager *Code 43* | [Error 43](#error-43-in-windows-device-manager-on-the-nvidia-card) |
| *device is not available for use* on start | [Audio function reset](#hdmi-audio-device-fails-to-reset-between-vm-restarts) |
| `Cannot allocate memory` / hugepages on start | [HugePages allocation failure](#hugepages-allocation-failure) |
| `vfio_container_dma_map … -22`, LG *Failed to locate a valid output device* | [Doc 04 §2b](04-looking-glass.md) (muxless laptop) |
| Black Looking Glass window | [Client shows a black window](#client-shows-a-black-window) |
| *Microsoft Basic Render Driver* / *GDI Generic* | [Rhino](#rhino-uses-microsoft-basic-render-driver), [Strand7](#graphics-opengl-preferences-reads-gdi-generic) |
| `Y:` and `Z:` swapped | [Drive letters swap](#drive-letters-swap-between-boots-y-and-z-trade-places) |
| COM / GUI automation fails over `ssh` | [Session 0 vs console](#ssh-windows-eng-cant-drive-excel--rhino--display-settings) |
| `[WinError 1005]` debugging on `Z:` | [Python debugger](#debugger-fails-with-winerror-1005-on-zoma-engsrc) |
| Office error `30094-…` | [Office install](#install-fails-with-error-30094-44-or-30094-1011-30094-4) |
| `CS1759`, `CS0122`, `CS1501`, `0x80080005`, `RuntimeBinderException` | [ETABS / SAP2000 OAPI](#csi-etabs--sap2000-oapi) |
| Guest stutters under load | [CPU stutters](#guest-cpu-stutters-on-scene-tumble) |
| `virsh shutdown` never finishes | [Guest never powers off](#virsh-shutdown-returns-but-the-guest-never-powers-off) |
| `qemu-img snapshot -d … Could not open` | [Snapshot after rename](#snapshot-revertdelete-fails-after-renaming-the-domain) |
| `externally-managed-environment`, `USE_BREP_DATA`, Bonsai *incompatible* | [Native tooling](#native-omarchy-tooling-freecad--bonsai--jupyter--handcalcs) |
| Host won't boot after setup / want to undo | [Doc 02 — Undo and rollback](02-host-setup.md#undo-and-rollback) |

---

## Host / VFIO problems

### Hugepagesize stays at 2048 kB after `set-cmdline` + `limine-update` + reboot

Symptom: `grep Hugepagesize /proc/meminfo` says `2048 kB` (2 MiB) even
after adding `default_hugepagesz=1G hugepagesz=1G hugepages=N` to what
you thought was the source of truth. Libvirt then refuses to start
the guest because there aren't enough 1 GiB hugepages.

Cause on Omarchy 4.x: `limine-mkinitcpio-hook` doesn't read
`/etc/kernel/cmdline`. It calls `limine-entry-tool --get-cmdline linux`,
which composes the UKI cmdline from `KERNEL_CMDLINE[default]` in
**`/etc/default/limine`** plus every drop-in under
`/etc/limine-entry-tool.d/*.conf`. Editing `/etc/kernel/cmdline` on
this stack is a silent no-op.

Fix — add a drop-in that appends the VFIO tokens (`hugepages=` = your
guest RAM in GiB):

```bash
sudo tee /etc/limine-entry-tool.d/vfio.conf > /dev/null <<'EOF'
KERNEL_CMDLINE[default]+=" intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=32"
EOF

# Confirm the composed cmdline before rebuilding:
sudo limine-entry-tool --get-cmdline linux --no-mutex --no-hooks | tail -1

# Rebuild the UKI + /boot/limine.conf:
sudo limine-update

sudo reboot
```

The oma-eng `scripts/set-cmdline` helper does all of this
automatically — it detects the Omarchy setup and writes to the
drop-in path instead of `/etc/kernel/cmdline`.

Diagnostic snippet if you want to verify each layer:

```bash
sudo bash -c '
stat -c "%y  %n" /boot/EFI/Linux/omarchy_linux.efi
tmp=$(mktemp)
objcopy --dump-section .cmdline="$tmp" /boot/EFI/Linux/omarchy_linux.efi
echo "UKI-baked cmdline:"; cat "$tmp"; rm -f "$tmp"
echo
echo "Running kernel cmdline:"; cat /proc/cmdline
'
```

If the UKI-baked line lacks the tokens but the running kernel line has
them, you booted an old EFI file — check `efibootmgr -v` for which
`.efi` firmware is loading. If both lack the tokens, the composed
cmdline from `limine-entry-tool` is still stale — the fix above hasn't
propagated yet.

### `Kernel driver in use: nvidia` (or `nouveau`) after reboot

vfio-pci didn't win the race. Check in order:

1. `cat /proc/cmdline` — is `intel_iommu=on` (Intel) or `amd_iommu=on`
   (AMD) plus `iommu=pt` present? If not, the Limine entry didn't get
   saved. Re-edit `/boot/limine.conf` (or use
   [`scripts/set-cmdline`](../scripts/set-cmdline) to do it idempotently
   with a `.bak`).
2. `lsinitcpio /boot/initramfs-linux.img | grep vfio` — the vfio modules
   should be listed. If not, redo `sudo mkinitcpio -P`.
3. `journalctl -b | grep -Ei 'vfio|nvidia|nouveau'` — look for who
   claimed the device first.
4. Make sure `/etc/modprobe.d/vfio.conf` has the IDs and blacklists
   nouveau + nvidia (see doc 02 §5).
5. Check for a leftover Nvidia driver stack \u2014 next entry.

### Omarchy Nvidia driver stack racing vfio-pci

Omarchy's installer offers to enable the Nvidia driver during setup.
When taken, it leaves these behind, all of which claim the dGPU before
vfio-pci does unless removed:

- Package `nvidia-open-dkms` (or `nvidia`, or `nvidia-dkms`)
- `/etc/modprobe.d/nvidia.conf` \u2014 `options nvidia_drm modeset=1`
- `/etc/mkinitcpio.conf.d/nvidia.conf` \u2014 `MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)`

[`scripts/prepare-host.sh`](../scripts/prepare-host.sh) detects this and
prints a WARNING when the stack is present. Fix by re-running with
`--remove-nvidia` (Path A: dedicate the dGPU to the guest, lose
host-side CUDA):

```bash
sudo ./scripts/prepare-host.sh --remove-nvidia
sudo mkinitcpio -P
sudo reboot
```

If you want to keep host-side CUDA (Path B), do NOT `--remove-nvidia`.
Instead write a libvirt `prepare`/`release` hook in
`/etc/libvirt/hooks/qemu` that unbinds `nvidia` and binds `vfio-pci`
on guest start and reverses on stop \u2014 not shipped in this repo; the
pattern is well documented upstream but fragile in practice.

### Only one Nvidia function shows up (muxless mobile Optimus)

Expected on gaming and mobile-workstation laptops. `lspci` lists a
single 3D controller (class 0302) with no VGA function and no HDMI
audio function \u2014 the card has no display outputs and no audio silicon
on the PCI bus; frames are copied to the iGPU via PCIe.

Only bind and pass through the one function. The template ships with
one active `<hostdev>` block and a second (audio) block commented out
for the desktop case; leave the second commented on a muxless card.
[`scripts/list-pci-for-passthrough.sh 10de`](../scripts/list-pci-for-passthrough.sh)
prints an advisory when it detects a single-function card. Looking
Glass is unaffected (the muxless design is invisible to LG): audio
routes through the emulated ich9/HDA in the XML, not through Nvidia
HDMI.

### IOMMU group mixing (Nvidia grouped with unrelated devices)

Run `scripts/check-iommu.sh`. If group 15 contains e.g. the Nvidia card
**and** an unrelated NIC or storage controller:

- **First try:** move the card to a different PCIe slot — usually a
  different slot means a different root port means a different group.
- **If that fails and only if you have to:** use the ACS override patch,
  available as `linux-vfio` in the AUR. This weakens IOMMU isolation
  (theoretical DMA attack surface, not usually relevant on a personal
  workstation) but unblocks the setup.
- **Alternative:** pass through the whole group. If it also contains a
  spare NIC, you can dedicate it to the guest.

Vendor-specific notes:

- **AMD hosts** historically had coarser IOMMU groups on older
  chipsets (X470/B450 and earlier). Modern chipsets (X570/B550/X670/B650
  and TRX40/TRX50) are fine. If you're on an older board and stuck with
  a mixed group, BIOS updates sometimes help; otherwise ACS override.
- **Intel hosts** rarely need ACS override on desktop / HEDT boards —
  each PCIe root port typically lives in its own group.

### `Error 43` in Windows Device Manager on the Nvidia card

Historical Nvidia consumer-card check that got fixed in driver 465+. If
you hit it on an old driver:

1. Update to a current Studio driver.
2. If still stuck, add KVM hidden state to the XML. The template no
   longer ships it because it isn't needed on driver 465+. Never mask
   the `hypervisor` CPU feature to hide the VM: Windows then ignores
   every Hyper-V enlightenment (check with
   `(Get-CimInstance Win32_ComputerSystem).HypervisorPresent`, which
   should be `True`):

   ```xml
   <features>
     <kvm>
       <hidden state='on'/>
     </kvm>
     <hyperv mode='custom'>
       <vendor_id state='on' value='whatever'/>
     </hyperv>
   </features>
   ```

### `vfio_pci … not IOMMU-safe` in dmesg

Almost always the ACS/group problem above. Same fix.

### AMD reset bug

Not applicable here — the reset bug affects AMD *GPUs* being passed
through, and this repo's discrete GPU is always Nvidia. AMD *CPUs* are
fine; they use the same VFIO path as Intel.

If you ever decide to pass through an AMD dGPU (e.g. adding a second
VM), look up the `vendor-reset` kernel module.

### HDMI audio device fails to reset between VM restarts

Symptom: the guest fails to start with *device is not available for
use* on the Nvidia audio function (desktop cards only; muxless laptops
have no audio function). Bounce its reset line before starting the VM:

```bash
sudo scripts/prepare-host.sh --reset-audio-fn
```

That writes `1` to `/sys/bus/pci/devices/<audio-fn>/reset` for every
Nvidia audio function bound to vfio-pci. Some cards need the whole PCIe
root port bounced instead.

### HugePages allocation failure

The guest fails to start with a hugepages / `Cannot allocate memory`
error in `/var/log/libvirt/qemu/windows-eng.log`. Compare
`grep HugePages_Total /proc/meminfo` with the XML's `<memory>`:

- Fewer pages than the guest needs: re-run `sudo scripts/set-cmdline`
  (it derives the count from the XML) and reboot. Or shrink the guest
  with `scripts/set-guest-memory`.
- The kernel cmdline count is right but `/proc/meminfo` shows fewer: the
  installed `/etc/sysctl.d/99-vm-hugepages.conf` disagrees and trims them
  at boot (doc 02 §6). `scripts/set-guest-memory` re-syncs it.
- Post-boot (sysctl-only) allocation failed on fragmented memory:
  reserve at boot via the cmdline instead.

---

## Looking Glass problems

### Client shows a black window

1. Confirm the guest Looking Glass service is running: in the guest
   admin PowerShell, `Get-Service looking-glass-host`. Restart it.
2. Confirm the shmem file exists on the host: `ls -l /dev/shm/looking-glass`.
   Owner should be your user, group `kvm`, mode `0660`.
3. Confirm the guest XML has an `<shmem>` block with matching name and
   size ≥ 32 MB.
4. `journalctl --user -f` while starting `looking-glass-client` — look
   for auth/perm errors on `/dev/shm/looking-glass`.
5. Version mismatch between host client and guest host app? They must be
   the same major/minor.

### Mouse works but keyboard is dead

Check the evdev pass-through paths in the XML — likely a typo in
`/dev/input/by-id/...-event-kbd`. Enumerate with:

```bash
ls -la /dev/input/by-id/
```

Use the `-event-kbd` symlinks, not the raw `event*` devices (those
renumber).

### Both-Ctrl toggle doesn't grab

Check `grab_all=on` on the keyboard evdev `-object` arg. Also confirm
the toggle key isn't remapped in the guest (some ergonomic keyboards
send different scancodes than the host layer expects).

### Frame rate capped at 30 fps in Rhino

Nvidia Control Panel → *Manage 3D settings* → *Vertical sync* → **Off**
(or Fast). Rhino honours vsync unless you turn it off in the driver.

---

## Rhino / Grasshopper

### Rhino uses *Microsoft Basic Render Driver*

The Nvidia driver isn't loaded or Rhino picked the QXL adapter. Fix:

1. In the guest Device Manager, disable *Microsoft Basic Display
   Adapter*.
2. Confirm Nvidia driver installed cleanly: `nvidia-smi`.
3. Rhino → *Tools ▸ Options ▸ View ▸ OpenGL* → tick *Use hardware
   modes* and pick the Nvidia GPU explicitly.
4. Restart Rhino.

### Grasshopper autosave error on virtiofs

See doc 06 §4. Update `virtiofsd`, or point Grasshopper autosave at
`C:\GH-Autosave`.

### `RhinoCommon` build says "cannot find version 8.x"

You either need to add McNeel's NuGet feed, or you're targeting the
wrong framework. Ensure `.csproj` has:

```xml
<PropertyGroup>
  <TargetFramework>net7.0-windows</TargetFramework>
  <UseWindowsForms>true</UseWindowsForms>
</PropertyGroup>
<ItemGroup>
  <PackageReference Include="RhinoCommon" Version="8.*-*" ExcludeAssets="runtime"/>
</ItemGroup>
```

### Cycles falls back to CPU

Studio driver older than the OptiX version Cycles needs. Update.

---

## Strand7

### `St7API.dll` not found

The samples raise `St7API.dll not found at ...` if the DLL isn't at
the default path. Set the `STRAND7_DIR` environment variable to the
`Bin64` folder of your Strand7 install (typically
`C:\Program Files\Strand7 R31\Bin64`) and re-open your terminal so
the env var takes effect.

### `BadImageFormatException` from the C# sample

The Strand7 R3 API is 64-bit only. Ensure your .NET SDK is 64-bit
(`dotnet --info` shows `RID: win-x64`) and the project's
`<PlatformTarget>` is `x64` (the sample sets this already).

Old advice suggesting `regsvr32 St7API.dll` or 32-bit vs 64-bit COM
mismatch does not apply — the DLL is a plain unmanaged native library
with no `DllRegisterServer` export; `regsvr32` fails on it.

### Strand7 says HASP dongle not found

Confirm the USB pass-through actually made it into the guest:

```powershell
Get-PnpDevice | Where-Object {$_.FriendlyName -match 'HASP|Sentinel'}
```

If absent, the `<hostdev>` USB IDs are wrong or the dongle was plugged
in after VM start. `virsh --connect qemu:///system attach-device
windows-eng configs/libvirt/hasp-dongle.xml` to hot-attach.

### Cloud licence — `St7Init` returns a licence error

Three usual causes, in likelihood order:

1. **Not signed in yet.** Launch `Strand7.exe` in the guest, sign in
   at the Cloud Licence dialog with your CLM email + password, tick
   *Remember me*, close Strand7. Re-run the API sample.
2. **No outbound Internet from the guest.** Check `ping www.strand7.com`
   from an admin PowerShell in the guest. If it fails, the host UFW
   rule for `virbr0` is likely missing — see [doc 02 §10](02-host-setup.md).
3. **Corporate proxy in the way.** Strand7's CLM talks HTTPS to
   Strand7 Pty Ltd's cloud endpoint. If your host is behind an HTTPS
   proxy that requires auth, the guest inherits neither the proxy
   settings nor the credentials. Set Windows-side proxy config in the
   guest via *Settings ▸ Network & Internet ▸ Proxy*, or route the
   host's proxy through the libvirt NAT.

If Strand7 R3 itself launches fine and holds a cloud licence, the API
will too — they share the same CLM sign-in.

### Solver runs on one thread

*Tools ▸ Preferences ▸ Solvers ▸ Threads* — set to allocated vCPUs.

### Graphics: OpenGL preferences reads *GDI Generic*

Same as Rhino: QXL vs Nvidia. See "Rhino uses Microsoft Basic Render
Driver" above.

---

## Guest sessions and virtiofs drive letters

### Drive letters swap between boots (`Y:` and `Z:` trade places)

Symptom — `Z:` sometimes points at `~/dev/oma-eng/src` and sometimes at
`~/dev`, with `Y:` taking the other one. Doc paths that hardcode `Z:\`
break at random.

Cause — `virtiofs.exe` serves exactly one tag per service instance, so
two virtiofs shares meant two Windows services. Both were installed
with `-m *`, which takes the first free letter counting down from `Z:`,
so whichever service won the startup race got `Z:`.

Fix — this repo now ships a **single** share (`~/dev` at `Z:`, tag
`dev`), and the service is pinned rather than left to `-m *`. From an
admin PowerShell in the guest:

```powershell
# remove any leftover companion service from the old two-share layout
net stop VirtioFsSvc-Dev; sc.exe delete VirtioFsSvc-Dev

sc.exe config VirtioFsSvc `
    binPath= "`"C:\Program Files\Virtio-Win\VioFS\virtiofs.exe`" -t dev -m Z:"
Restart-Service VirtioFsSvc
```

`sc.exe config` is fussy about quoting when driven through a
non-interactive `ssh`. If it just prints its usage text, set the value
directly instead:

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VirtioFsSvc' `
    -Name ImagePath `
    -Value '"C:\Program Files\Virtio-Win\VioFS\virtiofs.exe" -t dev -m Z:'
```

If you add a second share later, give it its own letter with
`scripts/set-guest-share --add PATH TAG --letter Y`.

### `ssh windows-eng` can't drive Excel / Rhino / display settings

Not a bug. Plain SSH lands in **Windows session 0** (the services
session, no desktop); Looking Glass and SPICE show **session 1** (the
`console` desktop logged on as `eng`). Confirm with `query session`, or
from the SSH shell:

```powershell
(Get-Process -Id $PID).SessionId      # 0 over ssh
[Environment]::UserInteractive        # False over ssh
```

Filesystem work — `dir Z:\`, `dotnet build`, `git` — is fine over plain
SSH, because `virtiofs.exe` runs as LocalSystem and publishes `Z:` into
the global DosDevices namespace. Anything that needs the desktop (GUI
apps, COM attaching to a running Excel/Rhino instance, display
settings) must be run from a PowerShell opened inside the Looking Glass
window. See doc 08 for the full table.

---

## Python

### Debugger fails with `[WinError 1005]` on `Z:\oma-eng\src\`

Symptom — F5 on a Python file under `Z:\oma-eng\src\` (VS Code Remote-SSH
into the guest) prints many copies of:

```
Error adding watch dir: Z:\oma-eng\src\...
OSError: [WinError 1005] The volume does not contain a recognized file
system. Please make sure that all required file system drivers are
loaded and that the volume is not corrupted: 'Z:\\oma-eng\\src\\...'
```

and no breakpoints bind, though the script itself runs to completion.

Cause — `debugpy` canonicalises every path it sees (script, watch
dirs, breakpoints) via `os.path.realpath()`, which on Windows Python
3.10+ calls `_getfinalpathname` → `GetFinalPathNameByHandle`. WinFsp
(the driver virtiofs uses to expose `Z:\` to Windows) doesn't
implement the volume-info FSCTLs that Win32 call needs, so it returns
error 1005. Nothing in the Python or `debugpy` config knobs bypasses
this.

Not a Strand7 issue — this affects any `.py` file on the `Z:` share on
this setup. C# / `coreclr` debugger uses raw paths and is unaffected.
And plain `py Z:\oma-eng\src\...\script.py` from PowerShell (no
debugger) also works because the script code doesn't itself call
`realpath` on its own directory.

Fix — mirror the folder to a local NTFS path in the guest and debug
from there:

```powershell
robocopy Z:\oma-eng\src\<project> C:\dev\<project> /MIR
```

Open `C:\dev\<project>` in VS Code Remote-SSH and F5. Re-run the
`robocopy` any time the Omarchy-side source changes. For Python
projects driven by `uv` (`office-integration`, `spacegass-api`), also
run `uv sync` in the local copy — the `.venv` shouldn't be mirrored
from `Z:\oma-eng\src\`.

---

## Office / Excel

### Install fails with error `30094-44` (or `30094-1011`, `30094-4`)

The `30094-XX` family is Click-to-Run failing to download product bits
from Microsoft's CDN. Almost always because **BITS is stopped** — the
service Click-to-Run uses to fetch the payload. Diagnose:

```powershell
Get-Service BITS, wuauserv, cryptsvc, ClickToRunSvc |
    Format-Table Name, Status, StartType
```

Fix:

```powershell
Set-Service BITS -StartupType Automatic
Start-Service BITS
```

Then retry the install. If a partial install is already there
(`ClickToRunSvc` shows up in `Get-Service`), open *Settings ▸ Apps ▸
Installed apps* → the Office entry → *⋯ ▸ Modify ▸ Online repair*.
If no entry exists, uninstall Office remnants with
[SaRA](https://aka.ms/SaRA-officeUninstallFromPC), reboot the guest,
and reinstall via the M365 web installer at <https://office.com>. The
web installer is more reliable than winget for this — winget's
`Microsoft.Office` alias frequently mismatches your M365 tenant
channel.

### Nvidia Control Panel won't open

*"You are using a display not attached to an NVIDIA GPU"* on a muxless
laptop. Correct diagnosis: on mobile Optimus with no dGPU display
output, the display is VDD or the iGPU. The Control Panel GUI checks
"is a display attached to me?" and refuses. The driver itself works
fine and Rhino/Strand7/Excel all land on the dGPU — verify with
`nvidia-smi` in an admin PowerShell (process listing is ground truth).

If you need per-EXE profile tweaks anyway, use
[NVIDIA Profile Inspector](https://github.com/Orbmu2k/nvidiaProfileInspector).
It talks to the driver's profile database directly, no GUI check. On
this repo's setup (guest on High-Performance power plan), the Program
Settings tweaks from doc 05 §3 are cosmetic anyway — the dGPU keeps
working clocks by default.

### `nvidia-smi` shows `N/A` for GPU memory

Expected on Windows guests. Windows manages VRAM through WDDM, which
doesn't expose per-process byte counts to NVML. The process being
**listed** in `nvidia-smi`'s *Processes* block is confirmation that it
holds a GPU context — that's the ground truth. For actual VRAM byte
counts on Windows, use Task Manager → *Performance* ▸ *GPU 1 (NVIDIA)*
or GPU-Z. NVML only reports real numbers on cards in TCC mode
(datacenter / select workstation only — A500 Laptop, GeForce, and most
mobile workstation cards are WDDM-only on Windows).

---

## CSi ETABS / SAP2000 OAPI

These four errors bit us end-to-end getting
[`src/etabs-api/csharp/HelloETABS`](../src/etabs-api/csharp/HelloETABS/)
to build and run against ETABS 23. All four are the same underlying
issue — CSi's `ETABSv1.dll` is a plain managed wrapper (not a PIA),
uses explicit interface implementations on the co-classes, and
registers the LocalServer32 in a way that's elevation-locked. Fix the
sample once, and any downstream OAPI code inherits the pattern.

### `CS1759: Cannot embed interop types from assembly 'ETABSv1'`

`ETABSv1.dll` is not a Primary Interop Assembly — it's missing
`ImportedFromTypeLibAttribute` / `PrimaryInteropAssemblyAttribute`.
Drop `<EmbedInteropTypes>true</EmbedInteropTypes>` from the
`<Reference>` and use `<Private>true</Private>` instead so the DLL
is copied next to `HelloETABS.exe` at build time.

### `CS0122: 'Helper.CreateObject(...)' is inaccessible`

`Helper.CreateObject` (and every OAPI method — `ApplicationStart`,
`SapModel`, `CreateObjectProgID`, `File`, `PointObj`, …) is an
explicit interface implementation on the CSi co-class, so it's
private on the concrete class and only reachable through the
interface. Declare the local as the interface type:

```csharp
cHelper helper = new Helper();          // NOT var, NOT Helper
cOAPI etabs = helper.CreateObjectProgID("CSI.ETABS.API.ETABSObject");
```

Same trick applies at every subsequent hop — use `cSapModel`, not
`var` or the concrete `SapModel` class.

### `COMException 0x80080005 (CO_E_SERVER_EXEC_FAILURE)`

Comes from the raw `Type.GetTypeFromProgID(...)` +
`Activator.CreateInstance` path. Modern ETABS registers its
LocalServer32 in a way that requires an elevated launcher; a
medium-integrity `dotnet run` can't start the server process.

Fix — use `cHelper.CreateObjectProgID(progID)` (introduced in ETABS
2016 v16.1) instead. It does `CreateProcess` on the resolved
LocalServer32 path directly, no DCOM class-factory dance:

```csharp
cOAPI etabs = helper.CreateObjectProgID("CSI.ETABS.API.ETABSObject");
etabs.ApplicationStart();               // parameterless in v16.1+
```

`Helper.CreateObject(exePath)` (the older API) works too but forces
you to hardcode the install path in code. `CreateObjectProgID` is
version-agnostic and picks the newest install automatically.

### `RuntimeBinderException: 'object' does not contain a definition for 'ApplicationStart'`

Same explicit-interface-impl root cause as CS0122, at runtime. C#'s
`dynamic` dispatch does public-member lookup on the runtime type;
CSi's co-class doesn't expose the OAPI methods publicly. Drop
`dynamic` and use the strong `cOAPI` / `cSapModel` / `cFile` /
`cPointObj` types from `ETABSv1.dll` throughout. Enum arguments can
be int-cast to keep the sample portable across the small
enum-member-name drift CSi introduces between versions:

```csharp
Check(sap.LoadPatterns.Add("HELLO_DEAD", (eLoadPatternType)1, 0.0, true), "...");
```

### `LoadPatterns.Add("DEAD", ...)` returns `rc=1`

Name conflict. `File.NewBlank()` on ETABS auto-creates `DEAD` and
`LIVE` load patterns; adding another with the same name is rejected.
Use a unique name (`HELLO_DEAD`, `MYLOAD`, …), or skip `Add` and use
the existing patterns via `GetNameList`.

### `CS1501: No overload for method 'ApplicationStart' takes 3 arguments`

ETABS 2016 v16.1 made `ApplicationStart()` parameterless — no more
`(eUnits, bool, string)`. Units are set separately via
`SapModel.InitializeNewModel(eUnits.kip_in_F)` (or equivalent) right
after. Same change applied across ETABS/SAP2000; check the CSi API
manual (search *cHelper.CreateObjectProgID*) for the current shape.

---

## Host performance regressions

### Guest CPU stutters on scene tumble

Almost always the CPU governor or power profile. Check that the libvirt
hook fired (`powerprofilesctl get` should say `performance` while the
guest runs), and that the installed `/etc/libvirt/hooks/qemu` matches
the domain name. A hook copied before a `virsh domrename` silently does
nothing. Manual override:

```bash
sudo cpu-governor performance
```

The hook is [`configs/libvirt/hooks/qemu`](../configs/libvirt/hooks/qemu)
(doc 02 §9).

### Guest disk feels slow

- Verify the disk is on `virtio-scsi` or `virtio-blk`, not IDE/SATA:
  the XML template uses virtio-scsi.
- Check `iothread` is enabled and the disk XML has `<driver
  iothread='1'/>`.
- If using qcow2, run `qemu-img convert` to `preallocation=metadata`
  once when the image gets big.

---

## libvirt / VM management

### `virsh shutdown` returns but the guest never powers off

Windows got the ACPI request but something is blocking it, usually an
"app is preventing shutdown" screen or an unsaved-document prompt
(Excel, Rhino, Strand7) on the Looking Glass display. `ssh` and the
guest agent often stop answering at this point, and the SPICE/QXL
console shows nothing because Windows draws on the dGPU / VDD.

Open Looking Glass and answer the prompt. `virsh destroy windows-eng` is
a hard power-off: unsaved work is lost, and it leaves the NTFS journal to
replay and possibly a leaked qcow2 cluster (fix it with the VM off:
`sudo qemu-img check -r leaks /var/lib/libvirt/images/windows-eng.qcow2`).
`libvirt-guests.service` (doc 02 §9) waits `SHUTDOWN_TIMEOUT` (180 s)
for this at host poweroff before giving up.

### Snapshot revert/delete fails after renaming the domain

`virsh domrename` does not update existing snapshots. Each one keeps
the old domain name and the old qcow2/NVRAM paths. Revert then fails,
and `snapshot-delete` removes libvirt's record but logs `qemu-img
snapshot -d … <old>.qcow2 … Could not open` in `journalctl -u libvirtd`,
leaving the snapshot data orphaned inside the image (check with
`qemu-img snapshot -U -l`).

Fix the metadata (disk untouched). `--redefine` refuses a changed
domain name, so save each record with the paths rewritten, drop the
records child→parent, and redefine them parent→child:

```bash
V="virsh -c qemu:///system"; D=windows-eng; OLD=windows-cad
order=$($V snapshot-list $D --name --topological)    # parents first
cur=$($V snapshot-current $D --name)
mkdir -p ~/snap-meta
for s in $order; do
  $V snapshot-dumpxml $D "$s" --security-info | sed "s/$OLD/$D/g" > ~/snap-meta/"$s".xml
done
for s in $(tac <<<"$order"); do $V snapshot-delete $D "$s" --metadata; done
for s in $order; do
  $V snapshot-create $D ~/snap-meta/"$s".xml --redefine $([[ $s == "$cur" ]] && echo --current)
done
```

Orphans left behind by a failed delete are removed with the VM off:
`sudo qemu-img snapshot -d <tag> /var/lib/libvirt/images/windows-eng.qcow2`.

---

## Native Omarchy tooling (FreeCAD / Bonsai / Jupyter / handcalcs)

Covers [doc 14](14-native-omarchy-tooling.md). No guest involvement —
these all run on Omarchy directly.

### FreeCAD BIM workbench: *IfcOpenShell is not installed*

FreeCAD on Arch embeds **system Python 3.14** and only looks in its
own vendor directory for extra packages. A `uv sync` in
`src/native-tooling/` does nothing for it — that venv is not on
FreeCAD's `sys.path`.

Use the workbench's own installer (*BIM ▸ Utils ▸ IfcOpenShell
Update*), or run the same thing by hand:

```bash
VENDOR="$HOME/.local/share/FreeCAD/v1-1/AdditionalPythonPackages/py314"
mkdir -p "$VENDOR"
python3 -m pip install --upgrade --disable-pip-version-check \
        --target "$VENDOR" ifcopenshell
```

Restart FreeCAD, then confirm:

```bash
FreeCADCmd -c "import ifcopenshell; print(ifcopenshell.version, ifcopenshell.__file__)"
# 0.8.5 /home/…/AdditionalPythonPackages/py314/ifcopenshell/__init__.py
```

`--target` bypasses PEP 668, so no `--break-system-packages` is
needed. If pip itself is missing: `sudo pacman -S --needed python-pip`.

Don't hardcode `v1-1`/`py314` in scripts — ask FreeCAD:

```bash
FreeCADCmd -c "import addonmanager_utilities as u; print(u.get_pip_target_directory())"
```

### `'Settings' object has no attribute 'USE_BREP_DATA'`

Raised by FreeCAD's **legacy** IFC importer
(`Mod/BIM/importers/importIFC.py`), which still uses the
IfcOpenShell 0.7 geometry-settings API. IfcOpenShell 0.8.x renamed
those constants.

FreeCAD 1.1 already comments the legacy importer out of
`Mod/BIM/Init.py` and registers **NativeIFC** as the `.ifc` handler,
so you only hit this if a macro calls `importers.importIFC`
directly. Port the call to NativeIFC:

```python
from nativeifc import ifc_import
ifc_import.insert("/path/to/model.ifc", doc.Name)
```

Downgrading `ifcopenshell` to 0.7.x is the wrong fix — it breaks
NativeIFC, which is the supported path.

### FreeCAD opens an IFC but the 3D view is empty

Two separate causes:

- **NativeIFC is lazy by design.** Only the `IfcProject` node appears
  at first; FreeCAD builds an element's shape when you expand its
  tree node. Expand down to the storey, or right-click the project ▸
  *Expand children*.
- **The file genuinely has no geometry.**
  `src/native-tooling/samples/smoke.ifc` is a schema-only fixture —
  no `IfcShapeRepresentation` entities at all. FreeCAD logs
  `get_geom_iterator: Invalid iterator` and draws nothing. Check
  before blaming the install:

  ```bash
  grep -c IFCSHAPEREPRESENTATION model.ifc   # 0 → nothing to draw
  ```

### `pip install --user ifcopenshell` → *externally-managed-environment*

Modern Python enforces PEP 668. Don't `pip install --user` on system
Python; use `uv` instead (or, for FreeCAD specifically, the `--target`
vendor-directory recipe above).

```bash
# Project-local (recommended):
cd ~/dev/oma-eng/src/native-tooling
uv sync

# Ad-hoc one-shot:
uv run --with ifcopenshell python -c "import ifcopenshell; print(ifcopenshell.version)"

# Global user tool (only for scripts with CLI entry points):
uv tool install ifcopenshell
```

### `pacman -S texlive-most` → *target not found*

Arch retired the `texlive-most` group. Install the specific packages
instead:

```bash
sudo pacman -S --needed texlive-basic texlive-latexextra \
    texlive-latexrecommended texlive-fontsextra \
    texlive-fontsrecommended texlive-xetex texlive-binextra \
    texlive-plaingeneric texlive-mathscience
```

`nbconvert --to pdf` also needs `pandoc-cli`:

```bash
sudo pacman -S --needed pandoc-cli
```

Remove any of the above and you get one of these mid-conversion:

| Missing | Error |
|---|---|
| `pandoc-cli` | `nbconvert.utils.pandoc.PandocMissing: Pandoc wasn't found` |
| `texlive-xetex` | `xelatex: command not found` |
| `texlive-plaingeneric` | `l.83  \usepackage {soul}` → *File `soul.sty' not found* |
| `texlive-mathscience` | *File `bm.sty' not found* |
| `texlive-latexextra` | *File `adjustbox.sty' not found* |

### `blender --command extension install bonsai` → *incompatible (Python 3.14 vs 3.13)*

As of this doc, the Bonsai release on extensions.blender.org is
`v0.8.5-post1`, `blender_version_max=5.1.0`, built for Python 3.13.
Blender 5.2 (Omarchy pacman) uses Python 3.14 and refuses to load
the extension. Two workarounds:

1. **Blender 4.5 LTS portable** (recommended — side-by-side with
   the pacman Blender 5.2, no root):

   ```bash
   mkdir -p ~/tools && cd ~/tools
   curl -fsSLO https://download.blender.org/release/Blender4.5/blender-4.5.4-linux-x64.tar.xz
   tar xf blender-4.5.4-linux-x64.tar.xz
   cat > ~/.local/bin/blender-bim <<'SH'
   #!/usr/bin/env bash
   exec "$HOME/tools/blender-4.5.4-linux-x64/blender" --online-mode "$@"
   SH
   chmod +x ~/.local/bin/blender-bim
   blender-bim --command extension install --enable bonsai
   ```

2. **AUR `ifcopenshell` (0.9.0-alpha)** builds against system Python
   3.14 and bundles a Bonsai `.zip` for the current Blender. Heavy
   source build (boost, cgal, opencascade).

Switch back to system Blender 5.2 once upstream Bonsai ships a
compatible release (typically 2–4 weeks after a new Blender LTS).

### `forallpeople` prints `SyntaxWarning: invalid escape sequence`

Cosmetic warning from `forallpeople/environment.py` on Python 3.12+
(unescaped `\*` in a plain string that should be raw). Doesn't break
anything, will disappear on the next upstream release. Silence with:

```bash
uv run python -W "ignore::SyntaxWarning" -c "import forallpeople"
```

Or suppress inside your notebook cell:

```python
import warnings
warnings.filterwarnings("ignore", category=SyntaxWarning, module="forallpeople.*")
import forallpeople as si
si.environment("structural", top_level=True)
```

### Blender / Cycles refuses to see the dGPU

Expected while the guest is running — the RTX A500 is bound to
`vfio-pci`, and neither `nvidia.ko` nor Cycles-OptiX can touch it.
Blender falls back to CPU or Intel Arc oneAPI, which is fine for
Bonsai viewport work. If you actually need the dGPU on Omarchy,
shut the guest down and unbind `vfio-pci` (see doc 03 §"Handing the
GPU back to Linux").

### `jupyter lab` opens but kernel is *starting…* forever

If uv installed JupyterLab into `.venv/` but VS Code or the browser
started a different kernel, you'll see this. Force the project
kernel:

```bash
cd ~/dev/oma-eng/src/native-tooling
uv run python -m ipykernel install --user --name oma-native \
    --display-name "oma-native (uv .venv)"
# Then pick "oma-native" in the JupyterLab kernel dropdown.
```

---

## When all else fails

- `journalctl -b | tail -300`
- `dmesg | grep -Ei 'vfio|iommu|nvidia|qemu|kvm'`
- `sudo tail -50 /var/log/libvirt/qemu/windows-eng.log` — QEMU's own
  log, written on every start; the real error for a failed start is here.
- `journalctl -u libvirtd --since -10min` — libvirt-side errors, and
  hook output.
- Ask the [Level1Techs VFIO forum](https://forum.level1techs.com/c/software/vfio/)
  — they have seen every hardware permutation.

Back to [README](../README.md).
