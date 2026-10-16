#!/usr/bin/env bash
# Apply the Gabbaya patch series to an unpacked InvoicePlane tree.
# Usage: apply-patches.sh <patches-dir> <app-root>
set -euo pipefail

patches_dir="$1"
app_root="$2"
series="${patches_dir}/series"
applied="${app_root}/.gabbaya-patches"

: > "${applied}"

if [ ! -f "${series}" ]; then
    echo "apply-patches: no series file, nothing to do"
    exit 0
fi

while read -r file status _; do
    case "${file}" in ''|'#'*) continue ;; esac

    if [ -z "${status:-}" ]; then
        echo "apply-patches: ERROR: ${file} has no status in series" >&2
        exit 1
    fi
    if [ ! -f "${patches_dir}/${file}" ]; then
        echo "apply-patches: ERROR: ${file} listed in series but missing" >&2
        exit 1
    fi

    echo "apply-patches: applying ${file} (${status})"
    # --forward: refuse already-applied hunks instead of reversing them,
    # so a patch that upstream has merged fails loudly.
    if ! patch -p1 --forward --batch -d "${app_root}" < "${patches_dir}/${file}"; then
        echo "apply-patches: ERROR: ${file} does not apply to $(cat "${app_root}/.invoiceplane-version" 2>/dev/null || echo '?')." >&2
        echo "apply-patches: rebase it, or drop it if upstream now contains the change." >&2
        exit 1
    fi
    echo "${file} ${status}" >> "${applied}"
done < "${series}"

find "${app_root}" -name '*.orig' -delete
echo "apply-patches: done, $(wc -l < "${applied}") patch(es) applied"
