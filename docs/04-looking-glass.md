# 04 — Looking Glass for seamless display

[Looking Glass](https://looking-glass.io/) captures the guest framebuffer,
copies it via IVSHMEM shared memory, and shows it in a native window on the
host. Result: the Windows 11 guest appears as a Hyprland window with
sub-millisecond copy latency and full GPU acceleration inside.

You need it to match versions between host client and guest host-app. This
repo pins **Looking Glass B7-rc1** as the reference; substitute the latest
stable at install time and update both sides together.

## 1. Shared-memory device on the host

Looking Glass needs a `/dev/shm/looking-glass` shared-memory region sized
for your guest resolution. 128 MB is enough for 4K@60; 32 MB is fine for
2560×1440.

Install a `tmpfiles.d` drop-in:

```bash
sudo tee /etc/tmpfiles.d/10-looking-glass.conf <<'EOF'
f /dev/shm/looking-glass 0660 mitchell kvm -
EOF
sudo systemd-tmpfiles --create
```

Change `mitchell` to your username. `kvm` is the group libvirt runs QEMU
under.

## 2. Add IVSHMEM to the guest XML

The template in
[`configs/libvirt/windows-cad.xml`](../configs/libvirt/windows-cad.xml)
already contains the block. If you're editing an existing domain:

```xml
<shmem name='looking-glass'>
  <model type='ivshmem-plain'/>
  <size unit='M'>128</size>
</shmem>
```

Apply via `virsh --connect qemu:///system edit windows-cad`.

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
scripts/install-looking-glass.sh B7-rc1
```

## 4. Install the Looking Glass host application in the guest

Download the matching Windows installer from
<https://looking-glass.io/downloads> (pick the same version, e.g.
`looking-glass-host-Setup-B7-rc1.exe`). Copy it to the guest via
`Z:\vendor\` on the virtiofs share.

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
- `[app] shmFile = /dev/shm/looking-glass`.
- `[input] rawMouse = yes` — 1:1 mouse in CAD is critical.
- `[input] captureOnFocus = yes`.
- `[egl] vsync = no` — CAD benefits from tearing-free but low-latency.

## 6. Autostart in Hyprland (optional)

Add to your Hyprland config (`~/.config/hypr/hyprland.conf`):

```
# Start Looking Glass when the CAD VM comes up
exec-once = looking-glass-client -c ~/.config/looking-glass/client.ini
```

Or leave it out and start it manually with:

```bash
looking-glass-client
```

## 7. Suggested Hyprland window rules

Give the LG window a dedicated workspace and no bar/decorations:

```
# ~/.config/hypr/hyprland.conf
windowrulev2 = workspace 4 silent, class:^(looking-glass-client)$
windowrulev2 = fullscreen,        class:^(looking-glass-client)$
bind = SUPER, F4, workspace, 4    # jump to CAD workspace
```

## 8. Input: evdev pass-through with hot-key switch

Looking Glass can grab keyboard/mouse via SPICE, but for CAD you want raw
evdev — Rhino's viewport tumbling depends on precise deltas. The XML
template adds evdev input devices with a `LEFTCTRL+RIGHTCTRL` toggle:

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

## 9. First run

```bash
virsh --connect qemu:///system start windows-cad
looking-glass-client
```

You should see the Windows desktop within ~10 seconds. If it stays black,
see [09 — Troubleshooting](09-troubleshooting.md) *Looking Glass shows
black*.

## Exit criteria

- Looking Glass window shows a live Windows desktop.
- Frame rate matches the guest's chosen refresh (60/120/144 Hz).
- Mouse tracking in Rhino's Perspective view feels 1:1.
- Both-Ctrl toggle swaps input between host and guest cleanly.

Continue to [05 — Windows guest tuning](05-windows-guest.md).
