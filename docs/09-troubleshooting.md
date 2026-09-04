# 09 — Troubleshooting playbook

The failure modes here are almost all one-time — you hit one, fix it,
never see it again. Grouped by symptom.

---

## Host / VFIO problems

### `Kernel driver in use: nvidia` (or `nouveau`) after reboot

vfio-pci didn't win the race. Check in order:

1. `cat /proc/cmdline` — is `intel_iommu=on` (Intel) or `amd_iommu=on`
   (AMD) plus `iommu=pt` present? If not, the Limine entry didn't get
   saved. Re-edit `/boot/limine.conf` (or the systemd-boot / GRUB
   equivalent — see doc 02 fallbacks).
2. `lsinitcpio /boot/initramfs-linux.img | grep vfio` — the vfio modules
   should be listed. If not, redo `sudo mkinitcpio -P`.
3. `journalctl -b | grep -Ei 'vfio|nvidia|nouveau'` — look for who
   claimed the device first.
4. Make sure `/etc/modprobe.d/vfio.conf` has the IDs and blacklists
   nouveau + nvidia (see doc 02 §5).

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

### Solver runs on one thread

*Tools ▸ Preferences ▸ Solvers ▸ Threads* — set to allocated vCPUs.

### Graphics: OpenGL preferences reads *GDI Generic*

Same as Rhino: QXL vs Nvidia. See "Rhino uses Microsoft Basic Render
Driver" above.

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
