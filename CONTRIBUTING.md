# Contributing to oma-eng

Thanks for wanting to contribute. This is a personal engineering-tools
repo, so the workflow is deliberately simple.

## Scope

In-scope contributions:

- Fixes to the docs / scripts / configs that make an existing recipe
  work more reliably on your hardware.
- New docs following the pattern of docs 06–14 (per-app setup, RAM
  sizing, licence considerations, verification steps, exit criteria)
  for additional structural-engineering software.
- Sample plug-ins under `src/` for APIs the repo already lists,
  provided they follow the "prove the pipeline works" style — small,
  self-explanatory, one working example per API.
- Native Omarchy tooling recipes (see doc 14) for open-source
  alternatives that fit the structural-engineering workflow.

Out of scope:

- Wine / Proton / WSL / cloud-GPU alternatives to the VFIO
  architecture. See `README.md` § *Non-goals*.
- Vendor code, installers, license keys, or dongle images.

## Before you open a PR

Run the built-in validator on your working tree:

```bash
scripts/validate-config.sh
```

It runs the same checks CI runs:

- XML syntax on all libvirt / hostdev templates.
- `virt-xml-validate` on `configs/libvirt/windows-cad.xml`.
- `shellcheck` on every script (warning level).
- `bash -n` syntax check.
- `python -m py_compile` on every sample.
- Relative doc link resolution.
- `.csproj` well-formedness.

If any target validator isn't installed, the check reports "skipped"
rather than failing.

For code changes to samples under `src/`, build the affected project
and confirm it still compiles:

```bash
cd src/<affected-project>/
dotnet build -c Debug    # C# projects
# or
python -m py_compile <file.py>
```

## Commit style

- One logical change per commit. Short imperative subject line
  (`docs: fix broken windows-vm link`, `configs: bump default guest RAM
  ladder`).
- If you're doing something non-obvious in a config or script, add a
  comment explaining *why* rather than *what* — the surrounding files
  do this consistently.
- Sign off with `Signed-off-by:` if your firm requires it. Not
  otherwise required.

## Reporting issues

Open a GitHub issue with:

1. Hardware — CPU vendor, iGPU, dGPU, motherboard chipset.
   `scripts/detect-host.sh` output is ideal.
2. Which doc or script you were following.
3. The failure — command run, expected output, actual output. Include
   the tail of `journalctl -b` or `dmesg` if it's a VFIO / IOMMU
   issue.
4. Whether you've reproduced against a fresh Omarchy install (rules
   out drift from other packages you have installed).

## Security-relevant contributions

If you're proposing a change to the VFIO isolation model — enabling
the ACS override kernel patch by default, adding a `<hostdev>` that
touches a non-dedicated device, weakening the QEMU sandbox, etc. —
see [SECURITY.md](SECURITY.md) first and call the trade-off out
explicitly in the PR description.

## Licence

By contributing you agree that your contribution is released under
the same MIT licence as the rest of the repo (see [LICENSE](LICENSE)).
