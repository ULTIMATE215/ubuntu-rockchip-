#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
PATCH_DIR="$(pwd)/patches/kernel"
mkdir -p build && cd build

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

# Clone the kernel repo.
# On a rebuild the tree still carries the patches applied below, and git pull
# refuses to run with those local changes, so discard them first. If anything
# in that path fails, fall back to a fresh clone (which needs the stale
# directory gone, or the clone itself would fail).
if ! { [ -d linux-rockchip/.git ] \
    && git -C linux-rockchip checkout -- . \
    && git -C linux-rockchip pull; }; then
    rm -rf linux-rockchip
    git clone --progress -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" linux-rockchip --depth=2
fi

cd linux-rockchip
git checkout "${KERNEL_BRANCH}"

# Apply this project's kernel patches for the current suite, in name order.
# They are per-suite because each suite tracks a different kernel repo and
# branch, so a patch is only ever valid against the one it was written for.
# A failure here is fatal on purpose: silently building an unpatched kernel
# is worse than a red build.
if [ -d "${PATCH_DIR}/${SUITE}" ]; then
    for patch in "${PATCH_DIR}/${SUITE}"/*.patch; do
        [ -e "${patch}" ] || continue
        echo "Applying kernel patch: $(basename "${patch}")"
        git apply --verbose "${patch}"
    done

    echo "Kernel tree after patching:"
    git --no-pager diff --stat
fi

# shellcheck disable=SC2046
export $(dpkg-architecture -aarm64)
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=aarch64-linux-gnu-gcc
export LANG=C

# Compile the kernel into a deb package
fakeroot debian/rules clean binary-headers binary-rockchip do_mainline_build=true v=1
