#!/bin/bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_dir}/config/rk3588-stable.sh"
source "${repo_dir}/scripts/pinned-source.sh"

build_dir="${repo_dir}/build"
cache_dir="${build_dir}/sources"
mkdir -p "${cache_dir}"
kernel_archive="${cache_dir}/linux-${STABLE_KERNEL_VERSION}.tar.xz"
encoder_archive="${cache_dir}/rkvenc-${RKVENC_REV}.tar.gz"
fetch_pinned_source \
    "https://cdn.kernel.org/pub/linux/kernel/v${STABLE_KERNEL_VERSION%%.*}.x/linux-${STABLE_KERNEL_VERSION}.tar.xz" \
    "${kernel_archive}" "${STABLE_KERNEL_SHA256}"
fetch_pinned_source \
    "https://codeload.github.com/simonswine/rockchip-rk3588-rkvenc/tar.gz/${RKVENC_REV}" \
    "${encoder_archive}" "${RKVENC_SHA256}"

work_dir=$(mktemp -d "${build_dir}/linux-${STABLE_KERNEL_VERSION}.XXXXXX")
kernel_dir="${work_dir}/linux"
encoder_dir="${work_dir}/rkvenc"
mkdir "${kernel_dir}" "${encoder_dir}"
tar -xf "${kernel_archive}" --strip-components=1 -C "${kernel_dir}"
tar -xf "${encoder_archive}" --strip-components=1 -C "${encoder_dir}"

cd "${kernel_dir}"
git init -q
git apply "${repo_dir}/patches/kernel/resolute/0001-arm64-dts-rockchip-orangepi-5-plus-aggressive-fan-curve.patch"
git apply "${repo_dir}/patches/kernel/resolute-stable/0001-extlinux-device-trees.patch"

rockchip_media=drivers/media/platform/rockchip
encoder_driver="${rockchip_media}/rkvenc"
mkdir "${encoder_driver}"
cp "${encoder_dir}"/rkvenc*.c "${encoder_dir}"/rkvenc*.h "${encoder_dir}/Kconfig" "${encoder_driver}/"
sed 's/^obj-m /obj-$(CONFIG_VIDEO_ROCKCHIP_RKVENC) /' "${encoder_dir}/Kbuild" > "${encoder_driver}/Makefile"
printf '%s\n' 'source "drivers/media/platform/rockchip/rkvenc/Kconfig"' >> "${rockchip_media}/Kconfig"
printf '%s\n' 'obj-y += rkvenc/' >> "${rockchip_media}/Makefile"

# Use the driver's single-core device tree on the Orange Pi 5 Plus.
rockchip_dts=arch/arm64/boot/dts/rockchip
sed -e '/^\/dts-v1\/;/d' -e '/^\/plugin\/;/d' -e '/^\/ { compatible = /d' \
    "${encoder_dir}/rk3588-rkvenc.dtso" > "${rockchip_dts}/rk3588-orangepi-5-plus-rkvenc.dtsi"
printf '\n#include "rk3588-orangepi-5-plus-rkvenc.dtsi"\n' >> "${rockchip_dts}/rk3588-orangepi-5-plus.dts"

config_base="https://raw.githubusercontent.com/Lemon1151/linux-rockchip-ubuntu/${ROCKCHIP_CONFIG_REV}/debian.rockchip/config"
config_files=()
for config_file in config.common.ubuntu arm64/config.common.arm64 arm64/config.flavour.rockchip; do
    fragment="${work_dir}/${config_file##*/}"
    curl --fail --silent --show-error --location --retry 3 --max-time 60 \
        -o "${fragment}" "${config_base}/${config_file}"
    config_files+=("${fragment}")
done
bash scripts/kconfig/merge_config.sh -m "${config_files[@]}"
scripts/config --enable PSI --enable MEDIA_PLATFORM_DRIVERS --enable V4L_MEM2MEM_DRIVERS \
    --module VIDEO_ROCKCHIP_RKVENC --module VIDEO_ROCKCHIP_VDEC --module VIDEO_HANTRO \
    --enable VIDEO_HANTRO_ROCKCHIP --enable DMA_CMA --enable DMABUF_HEAPS_CMA

make_args=(ARCH=arm64 LOCALVERSION=-rockchip)
if [[ $(uname -m) != aarch64 ]]; then
    make_args+=(CROSS_COMPILE=aarch64-linux-gnu-)
fi
make "${make_args[@]}" olddefconfig
for option in CONFIG_PSI=y CONFIG_VIDEO_ROCKCHIP_RKVENC=m CONFIG_VIDEO_ROCKCHIP_VDEC=m \
    CONFIG_VIDEO_HANTRO=m CONFIG_DMABUF_HEAPS_CMA=y; do
    grep -Fx "${option}" .config
done
test "$(make -s "${make_args[@]}" kernelrelease)" = "${STABLE_KERNEL_RELEASE}"

echo "Building Linux ${STABLE_KERNEL_RELEASE} packages in ${work_dir}"
make -j"${JOBS:-$(nproc)}" "${make_args[@]}" KBUILD_DEBARCH=arm64 \
    KDEB_PKGVERSION="${STABLE_KERNEL_PACKAGE_VERSION}" KDEB_CHANGELOG_DIST=resolute bindeb-pkg

test -f "${work_dir}/${STABLE_IMAGE_DEB}"
test -f "${work_dir}/${STABLE_HEADERS_DEB}"
package_dir="${build_dir}/${STABLE_KERNEL_PACKAGE_DIR}"
mkdir -p "${package_dir}"
install -m 0644 "${work_dir}/${STABLE_IMAGE_DEB}" "${work_dir}/${STABLE_HEADERS_DEB}" "${package_dir}/"
