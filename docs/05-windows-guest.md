# 05 — Windows guest tuning

The guest already runs after doc 03. This page removes the rough edges
that show up under real CAD/FEA workloads: driver hygiene, power plan,
scheduler, Windows Update misbehaving with the Nvidia driver, and the
last-mile SSH setup for API dev.

## 1. Power plan

Windows defaults to *Balanced*, which parks cores and hurts Rhino's
viewport perf. In the guest, an admin PowerShell:

```powershell
# Some Windows 11 SKUs ship with only Balanced visible — duplicate the
# High Performance scheme first (harmless if it already exists).
powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c    # High performance
powercfg -change -disk-timeout-ac 0
powercfg -change -standby-timeout-ac 0
powercfg -change -monitor-timeout-ac 0
```

If you use Strand7's Ultimate solver on very long jobs, also add:

```powershell
powercfg -change -hibernate-timeout-ac 0
```

## 2. Stop Windows Update overwriting the Nvidia driver

Windows loves to reinstall an ancient WHQL Nvidia driver. Block it:

- *Settings* → *Windows Update* → *Advanced options* → *Delivery
  optimisation* → turn everything off.
- In an admin PowerShell:

```powershell
# Prevent driver updates via Windows Update
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f
```

## 3. Nvidia Control Panel settings for CAD

Open *Nvidia Control Panel* → *Manage 3D settings* → *Program Settings*
and add `Rhino.exe` and `Strand7.exe`:

| Setting | Value | Why |
|---|---|---|
| Power management mode | Prefer maximum performance | Rhino stalls on clock ramp-up otherwise |
| Threaded optimisation | On | Both apps are multi-threaded |
| Vertical sync | Off (or Fast) | Lower latency in viewport |
| Anisotropic filtering | 16x | Cheap, prettier viewport |
| CUDA — GPUs | Select the dGPU explicitly | For Cycles / OptiX |

Under *Manage 3D settings ▸ Global*, set **OpenGL rendering GPU** to the
dGPU (there won't be another choice in the guest, but confirm).

> **Muxless-laptop caveat.** On mobile Optimus cards with no dGPU
> display output (this repo's HP ZBook Firefly G11 falls in this class
> — see [doc 04 §2b](04-looking-glass.md)), Nvidia Control Panel
> refuses to open with *"You are using a display not attached to an
> NVIDIA GPU"*. The driver itself works fine — Rhino, Strand7 and
> Excel all land on the dGPU (verify with `nvidia-smi` in an admin
> PowerShell). The per-EXE Program Settings tweaks above are also less
> important here because the guest sits on the *High-Performance*
> Windows power plan (§1), which keeps the driver at working clocks by
> default. For belt-and-braces per-EXE profiles, use
> [NVIDIA Profile Inspector](https://github.com/Orbmu2k/nvidiaProfileInspector)
> — it writes the same driver profile store as the Control Panel
> without the display-attached check. See also
> [doc 09 § Nvidia Control Panel won't open](09-troubleshooting.md).

## 4. Disable the QXL/basic display adapter

Once Looking Glass and the Nvidia driver are working, the fallback QXL
device just wastes an interrupt line. In Device Manager, disable
*Microsoft Basic Display Adapter* — do **not** uninstall, as the guest
still boots on it before the Nvidia driver loads.

**Skip on modern virtio-win** — with `virtio-win-guest-tools` installed
(doc 03 §6), the QXL driver `qxldod` claims the SPICE display, so
Device Manager lists *Red Hat QXL controller* rather than
*Microsoft Basic Display Adapter*. Disabling `qxldod` there also
blacks out SPICE, which you want to keep as a recovery view if
Looking Glass or the virtiofs share ever break. On this repo's
setup (three display adapters: QXL + NVIDIA + VDD), the interrupt
cost of the idle QXL device is negligible on any 10+ vCPU guest;
leave it enabled.

### Recommended: make VDD the only *active* display

With three adapters (QXL, NVIDIA, VDD) Windows treats the guest as a
multi-monitor system, and apps regularly open on the QXL / "invisible"
monitor because they saved a window position there. The clean fix is
to keep QXL's driver loaded (so SPICE stays available as recovery) but
turn QXL *off at the OS level* via display arrangement:

- Settings → System → Display → scroll to *Multiple displays*.
- Click *Identify* to see which display number is VDD.
- Change the dropdown from *Extend these displays* to **Show only on
  <VDD number>**.

Windows immediately drops the QXL display target. LG keeps working
(it captures VDD), apps can only open on VDD. Reversible in the same
dropdown if you ever need SPICE recovery.

If you're confident you'll never need SPICE (LG + SSH cover you),
remove the `<graphics type='spice'>` and `<video model='qxl'>` blocks
from the domain XML entirely. Requires a shutdown/redefine; cleanest
but irreversible without another XML edit.

### Rescuing a stuck off-screen window

Before you flip to *Show only on VDD*, or in a pinch after undocking
a monitor, an app may open on an invisible display. Rescue without
the Windows key:

1. **Alt + Tab** to focus the stuck window.
2. **Alt + Space** → opens the window's system menu.
3. **M** → selects *Move*.
4. Press **any arrow key** — the title bar reattaches to the mouse
   cursor.
5. Move the mouse into the visible display area.
6. **Click** to drop it there.

Works on every Windows version since 3.1.

## 5. Timer / scheduling for consistent frame times

- Ensure the QEMU XML uses `hpet present='no'` and
  `hypervclock present='yes'` (already in the template).
- Inside Windows, disable the dynamic tick so the scheduler doesn't
  coalesce timer interrupts under CAD load:

```powershell
bcdedit /set disabledynamictick yes
```

Reboot for the change to take effect.

**Don't set `useplatformclock true`** on this guest. With HPET off and
TSC set to `mode='native'` plus `hypervclock present='yes'` in the XML,
Windows picks the KVM paravirtualised clock, which is the fastest and
most stable option. Forcing `useplatformclock` sends Windows to the
ACPI PM timer instead and causes visible per-CPU clock skew and
occasional Explorer stalls under pinned-CPU workloads.

If you're troubleshooting time-drift symptoms and reach for
`useplatformclock` anyway, back it out with
`bcdedit /deletevalue useplatformclock` before reporting the issue.

Keep **Windows Time** running. It ships as Manual/Stopped on a
non-domain install, so the clock drifts after host suspends and snapshot
reverts, and cloud licences (Rhino Cloud Zoo, CSiCloud, Strand7 CLM)
and TLS reject skewed clocks:

```powershell
Set-Service W32Time -StartupType Automatic; Start-Service W32Time
w32tm /resync /force
```

Confirm the Hyper-V enlightenments are active (they are ignored if the
XML masks the `hypervisor` CPU feature, see doc 09):

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent   # True
```

### Background load: Defender and Search on shared/synced folders

- **Defender:** exclude the virtiofs share. Every file read over `Z:`
  is otherwise scanned in the guest, which slows `dotnet build` and `uv`
  a lot. The files are your own host-side repos:
  `Add-MpPreference -ExclusionPath 'Z:\'`.
- **Windows Search:** `Z:` isn't indexed by default, but OneDrive /
  SharePoint sync folders under `C:\Users\<you>\` are, cloud-only
  placeholders included. With a large tenant sync that keeps
  `SearchIndexer` busy (about 1.3 vCPU measured with ~320k placeholders).
  In *Indexing Options → Modify*, untick the sync folders. Outlook and
  Start-menu search keep working.
- **Defender scan pacing:** throttle scheduled scans so they don't
  compete with solvers. Real-time and cloud protection are unchanged;
  keep them on, since this guest holds work data.
  `Set-MpPreference -EnableLowCpuPriority $true -ScanAvgCPULoadFactor 30`
  (undo: `$false` / `50`).
- **SysMain (Superfetch):** little value on an SSD-backed guest with
  plenty of free RAM. It also drives memory compression.
  `Stop-Service SysMain; Set-Service SysMain -StartupType Disabled`
  (undo: `-StartupType Automatic; Start-Service SysMain`).
- **Delivery Optimization:** no peer-to-peer update sharing. This is the same
  setting as *Windows Update → Advanced → Delivery Optimization → Allow
  downloads from other devices: Off*; keep `DoSvc` itself running.
  `Set-ItemProperty 'Registry::HKEY_USERS\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings' DownloadMode 0 -Type DWord; Restart-Service DoSvc`
  (verify: `(Get-DOConfig).DownloadMode` → `CdnOnly`).
- **Edge:** *Settings → System and performance → Startup boost: Off*
  and *Continue running background extensions and apps when Microsoft
  Edge is closed: Off*. Otherwise Edge stays resident from logon.
- Leave `Spooler` (Bluebeam's PDF printer), `WSearch` (Outlook),
  `ClickToRunSvc`/`UsoSvc` (updates) and the Defender services running.

## 6. SSH server for VS Code Remote

You already installed OpenSSH in doc 03 §8. Add your Omarchy public key:

```powershell
# Guest: admin PowerShell
$key = "ssh-ed25519 AAAA... user@omarchy"   # paste your ~/.ssh/id_ed25519.pub
$path = "C:\ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $path -Value $key -Encoding ascii
icacls.exe $path /inheritance:r
icacls.exe $path /grant "Administrators:F" "SYSTEM:F"
Restart-Service sshd
```

On the Omarchy host, pin the guest's current lease so the address can't
change underneath the SSH config (libvirt's DHCP pool otherwise hands
out whatever is free):

```bash
V="virsh -c qemu:///system"
$V net-dhcp-leases default                      # note MAC + IP
$V net-update default add ip-dhcp-host \
  "<host mac='52:54:00:xx:xx:xx' name='windows-eng' ip='192.168.122.XX'/>" \
  --live --config
```

Then add to `~/.ssh/config`:

```
Host windows-eng
    HostName 192.168.122.XX      # the reserved address
    User mitchell                # your guest local account
    IdentityFile ~/.ssh/id_ed25519
    ForwardAgent no
```

Test:

```bash
ssh windows-eng "systeminfo | Select-String 'OS Name','Total Physical Memory'"
```

## 7. VS Code Server bootstrap

From the Omarchy host:

```bash
code --install-extension ms-vscode-remote.remote-ssh
code --remote ssh-remote+windows-eng ~/dev/oma-eng/src
```

On the first connect, VS Code installs the remote server into the guest
under `%USERPROFILE%\.vscode-server\`. Install these extensions in the
remote profile:

- `ms-dotnettools.csharp` — C# for RhinoCommon / Strand7 COM
- `ms-python.python` + `ms-python.vscode-pylance` — for Strand7 Python
  and Grasshopper CPython 3 components

McNeel does not currently ship an official VS Code extension for Rhino
(their supported editor is Visual Studio 2022 / Rider). If you write
IronPython 2 for older Grasshopper scripts, the language services in
`ms-python.python` cover the syntax; the interpreter still runs inside
Rhino.

## 8. Guest-side dev tooling

In an admin PowerShell with `winget`:

```powershell
winget install --silent Microsoft.DotNet.SDK.8
winget install --silent Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools --add Microsoft.VisualStudio.Component.Windows10SDK"
winget install --silent Python.Python.3.12
winget install --silent astral-sh.uv
winget install --silent Git.Git
```

The .NET 8 SDK covers Rhino 8 plugin development (Rhino 8 targets
`net7.0-windows` for RhinoCommon; net8 SDK builds it fine).

**Python packaging** — `uv` is the fast Rust-based replacement for
`pip` + `virtualenv` + `pip-tools`. Every Python sub-project in
`src/` ships a `pyproject.toml` + `uv.lock`; `uv sync` inside the
project directory creates a `.venv/` and installs the exact locked
versions. Cross-platform lockfiles let you `uv sync` on either
Omarchy or the guest and get the same versions.

**Running these over SSH** — install packages one at a time, not
chained. Some installers (notably `Microsoft.DotNet.SDK.8`) briefly
cycle the network stack while registering services and can reset an
active SSH session, aborting the rest of your loop. Either run each
`winget install` in its own SSH call, or on the guest console
directly.

**VS Build Tools is optional up-front** — the .NET 8 SDK alone builds
all the sample plugins in `src/`. Add BuildTools only when you need
MSVC / unmanaged C++ / vcpkg support, which none of Rhino, Strand7,
ETABS, or SpaceGass's C# / Python APIs require. The `.override`
argument brings in the Windows 10 SDK and Managed Desktop workload;
expect a ~4 GB download and 15–20 minutes of install time.

## 9. Snapshot

```bash
virsh --connect qemu:///system snapshot-create-as windows-eng tuned \
    "Nvidia driver, SSH, dev tooling — before Rhino/Strand7"
```

## Exit criteria

- `nvidia-smi` reports the dGPU and correct driver.
- Device Manager is warning-free.
- `ssh windows-eng hostname` returns the guest name from Omarchy.
- VS Code Remote-SSH successfully opens `Z:\oma-eng\src\` in the guest.
- `dotnet --version` prints an 8.x version in the guest.

Continue to [06 — Rhino 8 setup](06-rhino-setup.md).
