# 09 — Troubleshooting playbook

The failure modes here are almost all one-time — you hit one, fix it,
never see it again. Grouped by symptom.

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

Fix — add a drop-in that appends the VFIO tokens:

```bash
sudo tee /etc/limine-entry-tool.d/vfio.conf > /dev/null <<'EOF'
KERNEL_CMDLINE[default]+=" intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24"
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
2. If still stuck, add KVM hidden state to the XML (already in the
   template, but confirm it's there):

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

`echo 1 > /sys/bus/pci/devices/<audio-fn>/reset` before starting the VM.
Or add a libvirt hook that does it. Nvidia's HDMI audio function is
sometimes the culprit.

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
windows-cad configs/libvirt/hasp-dongle.xml` to hot-attach.

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

## Python

### Debugger fails with `[WinError 1005]` on `Z:\`

Symptom — F5 on a Python file under `Z:\` (VS Code Remote-SSH into the
guest) prints many copies of:

```
Error adding watch dir: Z:\...
OSError: [WinError 1005] The volume does not contain a recognized file
system. Please make sure that all required file system drivers are
loaded and that the volume is not corrupted: 'Z:\\...'
```

and no breakpoints bind, though the script itself runs to completion.

Cause — `debugpy` canonicalises every path it sees (script, watch
dirs, breakpoints) via `os.path.realpath()`, which on Windows Python
3.10+ calls `_getfinalpathname` → `GetFinalPathNameByHandle`. WinFsp
(the driver virtiofs uses to expose `Z:\` to Windows) doesn't
implement the volume-info FSCTLs that Win32 call needs, so it returns
error 1005. Nothing in the Python or `debugpy` config knobs bypasses
this.

Not a Strand7 issue — this affects any `.py` file under `Z:\` on this
setup. C# / `coreclr` debugger uses raw paths and is unaffected. And
plain `py Z:\...\script.py` from PowerShell (no debugger) also works
because the script code doesn't itself call `realpath` on its own
directory.

Fix — mirror the folder to a local NTFS path in the guest and debug
from there:

```powershell
robocopy Z:\<project> C:\dev\<project> /MIR
```

Open `C:\dev\<project>` in VS Code Remote-SSH and F5. Re-run the
`robocopy` any time the Omarchy-side source changes. For Python
projects driven by `uv` (`office-integration`, `spacegass-api`), also
run `uv sync` in the local copy — the `.venv` shouldn't be mirrored
from `Z:\`.

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

## Host performance regressions

### Guest CPU stutters on scene tumble

Almost always the CPU governor. Set `performance`:

```bash
sudo cpu-governor performance
```

Or wire it into a libvirt qemu hook (see `scripts/cpu-governor` header
for a copy-paste hook script).

### Guest disk feels slow

- Verify the disk is on `virtio-scsi` or `virtio-blk`, not IDE/SATA:
  the XML template uses virtio-scsi.
- Check `iothread` is enabled and the disk XML has `<driver
  iothread='1'/>`.
- If using qcow2, run `qemu-img convert` to `preallocation=metadata`
  once when the image gets big.

### HugePages allocation failure

`dmesg` shows the guest failing to start with hugepages. Either:

- You didn't reserve enough hugepages at boot. Increase the
  `hugepages=` kernel param.
- Kernel couldn't reserve contiguous 1 GiB pages after boot (fragmented
  memory). Reserve at boot instead of via sysctl.

### Nvidia audio function refuses to reset

Some cards need the whole PCIe root port bounced. Libvirt hook to do it
lives in `scripts/prepare-host.sh` under `--reset-audio-fn`.

---

## When all else fails

- `journalctl -b | tail -300`
- `dmesg | grep -Ei 'vfio|iommu|nvidia|qemu|kvm'`
- `virsh --connect qemu:///system domblkstat windows-cad`
- Enable QEMU trace: add `<log file='/var/log/libvirt/qemu/windows-cad.log'/>`
  to the domain and read it after a failed start.
- Ask the [Level1Techs VFIO forum](https://forum.level1techs.com/c/software/vfio/)
  — they have seen every hardware permutation.

Back to [README](../README.md).
