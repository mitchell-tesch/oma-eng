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
and add `Rhino.exe` and `St7.exe`:

| Setting | Value | Why |
|---|---|---|
| Power management mode | Prefer maximum performance | Rhino stalls on clock ramp-up otherwise |
| Threaded optimisation | On | Both apps are multi-threaded |
| Vertical sync | Off (or Fast) | Lower latency in viewport |
| Anisotropic filtering | 16x | Cheap, prettier viewport |
| CUDA — GPUs | Select the dGPU explicitly | For Cycles / OptiX |

Under *Manage 3D settings ▸ Global*, set **OpenGL rendering GPU** to the
dGPU (there won't be another choice in the guest, but confirm).

## 4. Disable the QXL/basic display adapter

Once Looking Glass and the Nvidia driver are working, the fallback QXL
device just wastes an interrupt line. In Device Manager, disable
*Microsoft Basic Display Adapter* — do **not** uninstall, as the guest
still boots on it before the Nvidia driver loads.

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

On the Omarchy host, add to `~/.ssh/config`:

```
Host windows-cad
    HostName 192.168.122.XX      # from `virsh net-dhcp-leases default`
    User mitchell                # your guest local account
    IdentityFile ~/.ssh/id_ed25519
    ForwardAgent no
```

Test:

```bash
ssh windows-cad "systeminfo | Select-String 'OS Name','Total Physical Memory'"
```

## 7. VS Code Server bootstrap

From the Omarchy host:

```bash
code --install-extension ms-vscode-remote.remote-ssh
code --remote ssh-remote+windows-cad ~/src/rhino-omarchy/src
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
winget install --silent Git.Git
```

The .NET 8 SDK covers Rhino 8 plugin development (Rhino 8 targets
`net7.0-windows` for RhinoCommon; net8 SDK builds it fine).

## 9. Snapshot

```bash
virsh --connect qemu:///system snapshot-create-as windows-cad tuned \
    "Nvidia driver, SSH, dev tooling — before Rhino/Strand7"
```

## Exit criteria

- `nvidia-smi` reports the dGPU and correct driver.
- Device Manager is warning-free.
- `ssh windows-cad hostname` returns the guest name from Omarchy.
- VS Code Remote-SSH successfully opens `Z:\src` in the guest.
- `dotnet --version` prints an 8.x version in the guest.

Continue to [06 — Rhino 8 setup](06-rhino-setup.md).
