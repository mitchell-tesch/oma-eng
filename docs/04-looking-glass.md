# 04 — Looking Glass for seamless display

[Looking Glass](https://looking-glass.io/) captures the guest framebuffer,
copies it via IVSHMEM shared memory, and shows it in a native window on the
host. Result: the Windows 11 guest appears as a Hyprland window with
sub-millisecond copy latency and full GPU acceleration inside.

You need it to match versions between host client and guest host-app.
Pick the latest stable release from <https://looking-glass.io/downloads>
at install time and use the same version on both sides — the client on
Omarchy and the host-app inside the guest. Versions bump every few
months; the shared-memory protocol between them isn't
forward-compatible, so keep them in lockstep.

The examples below use the placeholder `<version>`; substitute
whatever the current stable is (e.g. `B7`, `B7-rc1`, `B8-rc1`, or a
tagged release name from the downloads page).

## 1. Shared-memory device on the host

Libvirt creates `/dev/shm/looking-glass` itself whenever the domain
is started with an `<shmem model='ivshmem-plain'>` block, so this
repo's template (which already has one, sized 128 MB — enough for
4K@60) needs no host-side tmpfiles.d rule. The file is owned by
`qemu:qemu` with mode `0660`; add yourself to the `kvm` group
([`scripts/prepare-host.sh`](../scripts/prepare-host.sh) already did
that) so the Looking Glass client can read it.

If you're running QEMU directly (no libvirt), or if you're on a
libvirt too old to create the shmem file, drop a tmpfiles.d rule:

```bash
sudo tee /etc/tmpfiles.d/10-looking-glass.conf <<EOF
f /dev/shm/looking-glass 0660 $USER kvm -
EOF
sudo systemd-tmpfiles --create
```

## 2. Add IVSHMEM to the guest XML

The template in
[`configs/libvirt/windows-eng.xml`](../configs/libvirt/windows-eng.xml)
ships the IVSHMEM block **commented out** — doc 03 uses SPICE only, so
Looking Glass isn't wired up during Windows install. Two ways to add it,
depending on your dGPU:

### 2a. Desktop dGPU (full 47-bit DMA)

Uncomment the shipped block:

```xml
<shmem name='looking-glass'>
  <model type='ivshmem-plain'/>
  <size unit='M'>128</size>
</shmem>
```

Apply via `virsh --connect qemu:///system edit windows-eng`. Libvirt
auto-creates `/dev/shm/looking-glass` sized to match, owned by
`qemu:qemu`. Skip to §3.

### 2b. Laptop / muxless mobile Optimus (limited DMA + no display output)

Two problems on this class of hardware, both discovered rebuilding this
repo on an HP ZBook Firefly G11 (Intel Core Ultra 7 165H + RTX A500
Laptop):

**Problem 1 — IVSHMEM BAR above the IOMMU aperture.** With plain
`ivshmem-plain`, OVMF places the BAR at a guest physical address
around 2^42 that many mobile GPU DMA engines cannot reach. The domain
fails on start with:

```
vfio_container_dma_map ... = -22 (Invalid argument)
qemu: hardware error: vfio: DMA mapping failed, unable to continue
```

Check your host's IOMMU width first: `dmesg | grep -i "DMAR: Host
address width"`. Meteor Lake reports 42.

**Problem 2 — no capturable adapter.** Even if IVSHMEM works, the LG
host application refuses to start. Its log at
`%ProgramData%\Looking Glass (host)\looking-glass-host.txt` reads:

```
d12_enumerateDevices | Not using unsupported adapter: Microsoft Basic Render Driver
d12_enumerateDevices | Failed to locate a valid output device
Host application exited
```

Muxless laptops have no monitor wired to the dGPU, so Windows doesn't
extend the desktop onto the NVIDIA adapter, so DXGI/D12 finds no
capturable output, so LG dies.

Three fixes, all needed, in this order:

**Fix 1 — kvmfr kernel module** (backs IVSHMEM with a kernel-managed
region instead of `/dev/shm/*`).

Shortcut: install the module as your normal user, then let
`prepare-host.sh` do the rest idempotently. It handles autoload, size,
the udev rule and the `qemu.conf` ACL, and restarts libvirt only if
`qemu.conf` changed:

```bash
yay -S looking-glass-module-dkms
sudo scripts/prepare-host.sh --skip-packages --kvmfr
ls -la /dev/kvmfr0                        # crw-rw---- root kvm
```

The equivalent manual steps, for reference:

```bash
yay -S looking-glass-module-dkms
echo kvmfr | sudo tee /etc/modules-load.d/kvmfr.conf
echo 'options kvmfr static_size_mb=128' | sudo tee /etc/modprobe.d/kvmfr.conf
sudo modprobe kvmfr
ls -la /dev/kvmfr0                        # created but root:root 0600

# udev: make /dev/kvmfr0 group-kvm 0660 so QEMU + your host user can
# both open it (the AUR package doesn't ship this rule).
sudo tee /etc/udev/rules.d/99-kvmfr.rules <<'EOF'
SUBSYSTEM=="kvmfr", OWNER="root", GROUP="kvm", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=kvmfr
```

Allow `/dev/kvmfr0` through libvirt's cgroup device filter. Uncomment
`cgroup_device_acl` in `/etc/libvirt/qemu.conf` and add `/dev/kvmfr0`
to the list. Remember to include the shipped defaults — the list is a
**full replacement**, not additive:

```
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm",
    "/dev/rtc", "/dev/hpet",
    "/dev/userfaultfd",
    "/dev/kvmfr0"
]
```

Then `sudo systemctl restart libvirtd libvirtd.socket`.

**Fix 2 — cap OVMF's 64-bit PCI MMIO window** so all BARs (Nvidia +
IVSHMEM) sit under the IOMMU aperture. Replace the commented `<shmem>`
block with a `<qemu:commandline>` block. `X-PciMmio64Mb=32768`
(32 GiB) is well under 2^42 and plenty for a laptop-class Nvidia +
128 MiB IVSHMEM. `addr=0x10` avoids the QXL slot at `pcie.0:0x1`:

```xml
<qemu:commandline>
  <qemu:arg value='-fw_cfg'/>
  <qemu:arg value='name=opt/ovmf/X-PciMmio64Mb,string=32768'/>
  <qemu:arg value='-device'/>
  <qemu:arg value='ivshmem-plain,memdev=looking-glass,bus=pcie.0,addr=0x10'/>
  <qemu:arg value='-object'/>
  <qemu:arg value='memory-backend-file,id=looking-glass,mem-path=/dev/kvmfr0,size=128M,share=yes'/>
</qemu:commandline>
```

Make sure the `<domain>` element declares the qemu namespace or
libvirt drops the `<qemu:*>` children on `dumpxml`:

```xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
```

**Fix 3 — install a Virtual Display Driver in Windows.** Nothing
tells the passed-through GPU to draw a desktop unless a monitor is
attached; a VDD presents a phantom one so DXGI enumerates the Nvidia
adapter. Via SSH from Omarchy:

```bash
ssh windows-eng
# in the guest cmd:
start https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/latest
```

Download the latest installer (currently `Virtual.Display.Driver-Installer-x64.exe`
or the MSI), install with defaults, then restart the LG service:

```powershell
Restart-Service 'Looking Glass (host)'
Get-Content 'C:\ProgramData\Looking Glass (host)\looking-glass-host.txt' -Tail 20
```

The log should now show `Device Description: NVIDIA <your card>` and
`==== [ Capture Start ] ====`.

**Bump the VDD resolution** — the shipped `C:\VirtualDisplayDriver\vdd_settings.xml`
lists 800×600, 1366×768, 1920×1080, 2560×1440, and 3840×2160, and
Windows will default to 800×600 on first boot after install. Plain
`ssh` lands in Windows session 0, which has no desktop, so it cannot
reach display settings at all (see doc 08 for the full session-0 vs
console-session split). The quickest fix is to open the SPICE console
with `virt-viewer --connect qemu:///system windows-eng` (kill
`looking-glass-client` first — the two can't share the SPICE port),
then inside Windows go *Settings → System → Display*, click *Identify*,
select the small 800×600 monitor (VDD), and bump *Display resolution*
to 2560×1440 (or your preferred size). Close virt-viewer, relaunch
`looking-glass-client` — the LG log will now show
`Format: FRAME_TYPE_BGRA 2560x1440`.

Finally, point the client at `/dev/kvmfr0` instead of `/dev/shm/looking-glass`:

```ini
; ~/.config/looking-glass/client.ini
[app]
shmFile = /dev/kvmfr0
```

Continue to §3.

## 3. Install the Looking Glass client on Omarchy

Two options — choose one.

**A) From the AUR (fast, uses `yay` bundled with Omarchy)**

```bash
yay -S looking-glass
```

**B) From source (guaranteed version match)**

```bash
sudo pacman -S --needed base-devel cmake fontconfig spice-protocol \
    nettle libxkbcommon wayland-protocols libdecor \
    libxpresent libxi libxinerama libxcursor libxrandr sdl2
scripts/install-looking-glass.sh <version>       # e.g. B7 or B7-rc1
```

## 4. Install the Looking Glass host application in the guest

Download the matching Windows installer from
<https://looking-glass.io/downloads> — pick the **same version** you
installed on Omarchy in step 3. The asset name looks like
`looking-glass-host-Setup-<version>.exe`. Copy it to the guest via
`Z:\oma-eng\src\vendor\` on the virtiofs share.

Install it. It registers a Windows service called *Looking Glass (host)*
that starts at boot.

## 5. Configure the client for Hyprland

Copy the template:

```bash
mkdir -p ~/.config/looking-glass
cp configs/looking-glass/looking-glass-client.ini ~/.config/looking-glass/client.ini
```

Key values already set in the template:

- `[wayland]` — uses `wl-shell` protocol; needed on Hyprland.
- `[app] shmFile = /dev/shm/looking-glass` (or `/dev/kvmfr0` on the
  muxless-laptop path in §2b).
- `[input] rawMouse = yes` — 1:1 mouse in CAD is critical.
- `[input] captureOnFocus = no` and `grabKeyboardOnFocus = no` — LG
  only captures input after you press the escape key. Keeps
  Hyprland super-shortcuts (workspace switches, etc.) working while
  the LG window has focus.
- `[input] escapeKey = KEY_SCROLLLOCK` (default; press to enter/exit
  capture). Uncomment and set `escapeKey = KEY_RIGHTALT` (or any
  convenient key) in the template if your keyboard has no Scroll Lock.
- `[egl] vsync = no` — CAD benefits from tearing-free but low-latency.
- `[spice] audio = yes` — guest sound (the emulated HDA device) plays
  on the host through the SPICE channel. When a guest app opens the
  microphone (Teams, etc.), LG prompts first (`audio:micDefault`).

## 6. Launching — Apps-menu entry (recommended over autostart)

[`scripts/launch-windows-eng`](../scripts/launch-windows-eng) starts the
`windows-eng` domain if it isn't already running, then launches
`looking-glass-client` — or, if a client window is already open, just
focuses it instead of spawning a second instance.

Wire it into Omarchy's Apps menu (`SUPER + ALT + SPACE`) with a
`.desktop` entry. The heredoc is unquoted so `$HOME` expands; adjust
the path if you didn't clone to `~/dev/oma-eng`:

```bash
cat > ~/.local/share/applications/windows-eng-vm.desktop <<EOF
[Desktop Entry]
Version=1.0
Name=Windows Eng VM
Comment=Start the windows-eng CAD VM and open Looking Glass
Exec=$HOME/dev/oma-eng/scripts/launch-windows-eng
Icon=virt-manager
Terminal=false
Type=Application
Categories=System;Virtualization;
StartupNotify=true
EOF
```

Search "Windows Eng VM" in the Apps menu any time you want to bring the
VM + LG up — after a host restart, after closing the client, or to
refocus it. No boot-time `exec-once` needed, and no risk of LG racing
the guest before it's ready (the script blocks on `virsh start` first).

You can still run the pieces manually if you prefer:

```bash
virsh --connect qemu:///system start windows-eng
looking-glass-client -c ~/.config/looking-glass/client.ini
```

## 7. Hyprland window rules

The repo ships two equivalent drop-ins under `configs/hypr/`, one for
each generation of Omarchy's Hyprland config:

- **Pre-quattro** (traditional `hyprland.conf`): use
  [`configs/hypr/looking-glass.conf`](../configs/hypr/looking-glass.conf).
  [`scripts/prepare-host.sh`](../scripts/prepare-host.sh) copies it to
  `~/.config/hypr/looking-glass.conf` automatically. Wire it in with:

  ```
  # ~/.config/hypr/hyprland.conf
  source = ~/.config/hypr/looking-glass.conf
  ```

- **Omarchy quattro (4.x)** \u2014 the Lua config: use
  [`configs/hypr/looking-glass.lua`](../configs/hypr/looking-glass.lua)
  and wire it into `hyprland.lua`:

  ```bash
  cp configs/hypr/looking-glass.lua ~/.config/hypr/looking-glass.lua
  ```

  Then add one line in `~/.config/hypr/hyprland.lua`, next to the other
  `require("hypr.…")` lines:

  ```lua
  require("hypr.looking-glass")
  ```

Reload with `hyprctl reload` (either flavour \u2014 no need to
`omarchy restart hypr`). Both drop-ins give you:

- Dedicated workspace 9 for the guest (silent switch).
- Fullscreen, no shadow / blur / rounding on the LG window.
- `immediate` mode + `no_anim` — tearing preferable to added latency
  inside the LG window.
- `idle_inhibit = "fullscreen"` so Hyprland's idle logic doesn't
  blank the guest during long renders.

**No launch keybinding is shipped by default** — Omarchy's built-in
`SUPER + 9` already jumps to workspace 9 where the window rule sends
the LG client. If you want a launch-or-focus shortcut, add it in
`~/.config/hypr/bindings.lua`; avoid `SUPER + G` (Omarchy's
*Toggle window grouping*) and `SUPER + SHIFT + G` (Omarchy's Signal
launcher):

```lua
o.bind("SUPER + CTRL + G", "Launch Looking Glass",
       { launch = "looking-glass-client", focus = "^looking-glass-client$" })
```

Verify the rules stuck after reload:

```bash
hyprctl clients | grep -A20 "class: looking-glass-client"
```

Look for `workspace: 9 (9)`, `fullscreen: 2`, `inhibitingIdle: 1`.

Edit either drop-in to change workspace or keybinding.

### Working with an external monitor

The LG window is pinned to workspace 9 by the drop-in above, so
docking is a two-step routine:

- **`SUPER + 9`** — jump to workspace 9 (Omarchy default).
- **`SUPER + SHIFT + ALT + →`** — move workspace 9 to the monitor on
  the right (usually the external). `←` brings it back to the laptop
  panel when you undock.

Inside the guest, change VDD's resolution to match the external's
native mode from *Settings → System → Display → Display resolution*.
VDD ships a static mode list in `C:\VirtualDisplayDriver\vdd_settings.xml`
(1080p, 1440p, 4K, 16:9 only) — add custom modes for exotic sizes
(16:10 laptops, ultrawides) with a PowerShell snippet like this and
re-run whenever you get a new display:

```powershell
$path = 'C:\VirtualDisplayDriver\vdd_settings.xml'
$xml = [xml](Get-Content $path)
$res = $xml.vdd_settings.resolutions

function AddRes($w, $h, $r) {
    foreach ($e in $res.resolution) {
        if ($e.width -eq "$w" -and $e.height -eq "$h" -and $e.refresh_rate -eq "$r") { return }
    }
    $node = $xml.CreateElement('resolution')
    $node.InnerXml = "<width>$w</width><height>$h</height><refresh_rate>$r</refresh_rate>"
    $res.AppendChild($node) | Out-Null
}

AddRes 1920 1200 60          # 16:10 laptop panels (ZBook, XPS etc.)
AddRes 2560 1600 60          # 16:10 hi-DPI panels
AddRes 3440 1440 60          # 21:9 ultrawide
AddRes 3440 1440 100         # 21:9 ultrawide, 100 Hz

$xml.Save($path)
$vdd = Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000'
Disable-PnpDevice -InstanceId $vdd.InstanceId -Confirm:$false
Start-Sleep -Milliseconds 500
Enable-PnpDevice -InstanceId $vdd.InstanceId -Confirm:$false
```

After the driver cycles, pick the new mode in Settings. IVSHMEM at
128 MiB covers up to 4K@60 (`3840×2160×4 bytes ≈ 33 MiB` per frame);
bump `kvmfr static_size_mb` to `256` and the matching `size=128M` →
`size=256M` in the `<qemu:arg>` block for 5K/8K or high-refresh 4K.

## 8. Input: evdev pass-through with hot-key switch (optional)

Looking Glass forwards keyboard/mouse over SPICE (`rawMouse = yes` in
the client config), which is enough for most CAD work. If you want raw
evdev instead — e.g. a dedicated USB keyboard/mouse pair handed wholly
to the guest — the XML template ships the block **commented out** at
the bottom of `<qemu:commandline>`. Uncomment it and fill in the paths
(`scripts/list-evdev-for-passthrough.sh --xml` prints them):

```xml
<input type='evdev'>
  <source dev='/dev/input/by-id/usb-YOUR_KB-event-kbd' grab='all' repeat='on'/>
</input>
<input type='evdev'>
  <source dev='/dev/input/by-id/usb-YOUR_MOUSE-event-mouse'/>
</input>
<qemu:commandline xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <qemu:arg value='-object'/>
  <qemu:arg value='input-linux,id=kbd1,evdev=/dev/input/by-id/...-event-kbd,grab_all=on,repeat=on'/>
  <qemu:arg value='-object'/>
  <qemu:arg value='input-linux,id=mouse1,evdev=/dev/input/by-id/...-event-mouse'/>
</qemu:commandline>
```

Fill in the actual `/dev/input/by-id/` paths — they're stable across
reboots.

Press both **Ctrl** keys simultaneously to swap focus between host and
guest.

### Windows-key limitation on Hyprland

Even with LG's escape-key capture on, Hyprland tends to swallow bare
`SUPER` (Windows key) presses — the guest never sees a Start-menu
keystroke. Use Windows-native alternatives that don't route through
SUPER; all work through the LG capture just fine:

| Instead of | Use |
|---|---|
| **Windows key** (open Start) | **Ctrl + Esc** |
| Win + D (show desktop) | Click the *Show Desktop* strip at the right end of the taskbar |
| Win + E (File Explorer) | **Ctrl + Esc** → type `explorer` → Enter |
| Win + L (Lock) | **Ctrl + Alt + Del** → *Lock* |
| Win + R (Run) | **Ctrl + Esc** → type command directly (Start search runs it) |
| Win + Tab (Task View) | **Alt + Tab** |

Evdev pass-through (above) is the only way to get a real Windows key
from a physical keyboard — QEMU grabs the device at kernel level and
Hyprland never sees it. Needs an external USB keyboard; laptop
internal keyboards (i8042/i2c) don't have stable `/dev/input/by-id/`
paths.

## 9. First run

```bash
scripts/launch-windows-eng
```

(or use the "Windows Eng VM" Apps-menu entry from §6, or the manual
two-command form it wraps.)

You should see the Windows desktop within ~10 seconds. If it stays black,
see [09 — Troubleshooting](09-troubleshooting.md) *Looking Glass shows
black*.

## Exit criteria

- Looking Glass window shows a live Windows desktop.
- LG host log shows `Using: D12` (or `DXGI`) with the Nvidia adapter
  enumerated, followed by `==== [ Capture Start ] ====`.
- Frame rate matches the guest's chosen refresh (60/120/144 Hz).
- Mouse tracking in Rhino's Perspective view feels 1:1.
- Both-Ctrl toggle (or Scroll Lock on the client) swaps input between
  host and guest cleanly.
- **Muxless laptops only**: `/dev/kvmfr0` exists (mode `0660 root:kvm`)
  and Windows Device Manager shows both the Nvidia card and the
  Virtual Display Driver adapter with no yellow triangles.

Continue to [05 — Windows guest tuning](05-windows-guest.md).
