#!/usr/bin/env bash
# Install the extra composer packages from patches/composer-requires into an unpacked
# InvoicePlane tree, leaving every other locked package untouched.
# Usage: composer-requires.sh <requires-file> <app-root>
set -euo pipefail

requires="$1"
app_root="$2"
manifest="${app_root}/.gabbaya-composer"

: > "${manifest}"

packages=()
while read -r spec status _; do
    case "${spec}" in ''|'#'*) continue ;; esac
    if [ -z "${status:-}" ]; then
        echo "composer-requires: ERROR: ${spec} has no status" >&2
        exit 1
    fi
    packages+=("${spec}")
done < "${requires}"

if [ "${#packages[@]}" -eq 0 ]; then
    echo "composer-requires: nothing to install"
    exit 0
fi

cd "${app_root}"
export COMPOSER_ALLOW_SUPERUSER=1

# Record the requirements without resolving everything, then update only these packages.
composer require --no-update --no-interaction --no-scripts "${packages[@]}"

names=()
for spec in "${packages[@]}"; do
    names+=("${spec%%:*}")
done
# The release lock also lists dev tools that require a newer PHP than the image runs;
# they are never installed (--no-dev), so only their PHP version constraint is ignored.
# Extension requirements are still enforced.
composer update --no-dev --no-interaction --no-scripts --no-progress --optimize-autoloader \
    --ignore-platform-req=php "${names[@]}"

for spec in "${packages[@]}"; do
    name="${spec%%:*}"
    wanted="${spec#*:}"
    installed=$(composer show --no-interaction --format=json "${name}" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo ltrim($d["versions"][0] ?? "", "v");')
    if [ "${installed}" != "${wanted#v}" ]; then
        echo "composer-requires: ERROR: ${name} installed ${installed}, expected ${wanted}" >&2
        exit 1
    fi
    echo "${name} ${installed}" >> "${manifest}"
done

echo "composer-requires: done, $(wc -l < "${manifest}") package(s) installed"
