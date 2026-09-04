#!/usr/bin/env bash
# validate-config.sh — sanity-check the config templates and shell
# scripts in this repo. Runs whichever validators are available on
# the host; missing tools are reported as skipped, not failed.
#
# Exit code is non-zero if any validator reported a failure.
#
# Usage:
#     scripts/validate-config.sh
#     scripts/validate-config.sh --strict   # skips count as failures
#
# Intended to be safe to run in CI and locally.

set -u
strict=0
for arg in "$@"; do
    case "$arg" in
        --strict) strict=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fails=0
skips=0
pass_count=0

pass() { printf '  \033[32m✓\033[0m  %s\n' "$*"; pass_count=$(( pass_count + 1 )); }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$*"; fails=$(( fails + 1 )); }
skip() { printf '  \033[33m-\033[0m  %s (skipped)\n' "$*"; skips=$(( skips + 1 )); }

# --- 1. XML syntax on all libvirt / hasp templates ------------------------
echo "==> XML syntax (xmllint)"
if command -v xmllint >/dev/null 2>&1; then
    while IFS= read -r -d '' xml; do
        if xmllint --noout "$xml" 2>/tmp/validate-xml.err; then
            pass "$(realpath --relative-to="$REPO_ROOT" "$xml")"
        else
            fail "$(realpath --relative-to="$REPO_ROOT" "$xml"): $(cat /tmp/validate-xml.err)"
        fi
    done < <(find configs -name '*.xml' -type f -print0)
else
    skip "xmllint not installed (pacman -S libxml2)"
fi

# --- 2. libvirt-specific validation on the domain XML --------------------
echo "==> libvirt domain validation (virt-xml-validate)"
if command -v virt-xml-validate >/dev/null 2>&1; then
    for xml in configs/libvirt/windows-cad.xml; do
        [[ -f "$xml" ]] || continue
        # windows-cad.xml uses the qemu XML namespace; virt-xml-validate
        # in default schema mode rejects that. Use --schema domain
        # explicitly, which is what libvirt actually uses at define time.
        if virt-xml-validate "$xml" domain >/tmp/validate-libvirt.err 2>&1; then
            pass "$xml"
        else
            fail "$xml: $(cat /tmp/validate-libvirt.err)"
        fi
    done
else
    skip "virt-xml-validate not installed (pacman -S libvirt)"
fi

# --- 3. Shell script static analysis ------------------------------------
echo "==> Shell scripts (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r -d '' sh; do
        # Skip the libvirt hook — it's not intended to be sourced with
        # our shellcheck rules; shellcheck it anyway but at info level.
        if shellcheck -S warning "$sh" >/tmp/validate-sh.err 2>&1; then
            pass "$(realpath --relative-to="$REPO_ROOT" "$sh")"
        else
            fail "$(realpath --relative-to="$REPO_ROOT" "$sh"):"
            sed 's/^/      /' /tmp/validate-sh.err
        fi
    done < <(find scripts configs -type f \( -name '*.sh' -o -path 'scripts/cpu-governor' -o -path 'configs/libvirt/hooks/qemu' \) -print0)
else
    skip "shellcheck not installed (pacman -S shellcheck)"
fi

# --- 4. Bash syntax check (belt-and-braces if shellcheck missing) --------
echo "==> Bash syntax (bash -n)"
if command -v bash >/dev/null 2>&1; then
    while IFS= read -r -d '' sh; do
        if bash -n "$sh" 2>/tmp/validate-bash.err; then
            pass "$(realpath --relative-to="$REPO_ROOT" "$sh")"
        else
            fail "$(realpath --relative-to="$REPO_ROOT" "$sh"): $(cat /tmp/validate-bash.err)"
        fi
    done < <(find scripts configs -type f \( -name '*.sh' -o -path 'scripts/cpu-governor' -o -path 'configs/libvirt/hooks/qemu' \) -print0)
else
    skip "bash not available"
fi

# --- 5. Python syntax on samples ----------------------------------------
echo "==> Python syntax (python -m py_compile)"
if command -v python3 >/dev/null 2>&1; then
    py=python3
elif command -v python >/dev/null 2>&1; then
    py=python
else
    py=""
fi
if [[ -n "$py" ]]; then
    while IFS= read -r -d '' f; do
        if "$py" -m py_compile "$f" 2>/tmp/validate-py.err; then
            pass "$(realpath --relative-to="$REPO_ROOT" "$f")"
        else
            fail "$(realpath --relative-to="$REPO_ROOT" "$f"): $(cat /tmp/validate-py.err)"
        fi
    done < <(find src -name '*.py' -type f -print0)
else
    skip "python not available"
fi

# --- 6. .csproj well-formedness -----------------------------------------
echo "==> C# project files (xmllint)"
if command -v xmllint >/dev/null 2>&1; then
    while IFS= read -r -d '' csproj; do
        if xmllint --noout "$csproj" 2>/tmp/validate-csproj.err; then
            pass "$(realpath --relative-to="$REPO_ROOT" "$csproj")"
        else
            fail "$(realpath --relative-to="$REPO_ROOT" "$csproj"): $(cat /tmp/validate-csproj.err)"
        fi
    done < <(find src -name '*.csproj' -type f -print0)
else
    skip "xmllint not installed for .csproj check"
fi

# --- 7. Doc internal links ---------------------------------------------
echo "==> Docs internal links"
missing=0
while IFS= read -r -d '' md; do
    src_dir="$(dirname "$md")"
    # Extract every ](target) pair using a Perl regex; drop http(s)/mailto/anchor-only.
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        # Strip fragment
        clean="${link%%#*}"
        [[ -z "$clean" ]] && continue
        # Skip absolute URLs and non-file schemes
        case "$clean" in
            http://*|https://*|mailto:*|ftp://*|ssh://*|git@*) continue ;;
        esac
        target="$src_dir/$clean"
        if [[ ! -e "$target" ]]; then
            fail "$(realpath --relative-to="$REPO_ROOT" "$md") -> $link"
            missing=$(( missing + 1 ))
        fi
    done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null \
             | sed -E 's/^\]\(([^)]+)\)$/\1/' \
             | grep -vE '^(https?://|mailto:|ftp://|ssh://|git@)' \
             | grep -vE '^#')
done < <(find . -maxdepth 3 -name '*.md' -type f -not -path './.git/*' -print0)
if [[ $missing -eq 0 ]]; then
    pass "no dead relative links found"
fi

# --- Summary ------------------------------------------------------------
echo
printf 'Summary: %d passed, %d failed, %d skipped.\n' "$pass_count" "$fails" "$skips"
if (( strict )) && (( skips > 0 )); then
    fails=$(( fails + skips ))
    printf 'Strict mode: skips count as failures.\n'
fi
exit $(( fails > 0 ? 1 : 0 ))
