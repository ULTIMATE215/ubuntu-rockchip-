#!/bin/bash

set -euo pipefail

if [[ $(uname -m) != aarch64 ]]; then
    echo "Build the RK3588 media packages on ARM64 Ubuntu 26.04" >&2
    exit 1
fi

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_dir}/config/rk3588-stable.sh"
source "${repo_dir}/scripts/pinned-source.sh"

build_dir="${repo_dir}/build"
cache_dir="${build_dir}/sources"
jobs="${JOBS:-$(nproc)}"
mkdir -p "${cache_dir}"
work_dir=$(mktemp -d "${build_dir}/rk3588-media.XXXXXX")
echo "Building RK3588 media packages in ${work_dir}"

unpack_source() {
    local name="$1"
    local repo="$2"
    local revision="$3"
    local sha256="$4"
    local archive="${cache_dir}/${name}-${revision}.tar.gz"
    local dest="${work_dir}/${name}"

    fetch_pinned_source "https://codeload.github.com/${repo}/tar.gz/${revision}" "${archive}" "${sha256}"
    mkdir "${dest}"
    tar -xf "${archive}" --strip-components=1 -C "${dest}"
    git -C "${dest}" init -q
}

build_ffmpeg() {
    unpack_source media-patches gregordinary/patches "${MEDIA_PATCHES_REV}" "${MEDIA_PATCHES_SHA256}"
    unpack_source mpp tsukumijima/mpp-rockchip "${MPP_REV}" "${MPP_SHA256}"
    unpack_source ffmpeg FFmpeg/FFmpeg "${FFMPEG_REV}" "${FFMPEG_SHA256}"

    local media_patches="${work_dir}/media-patches/media-accel"
    local install_prefix=/opt/rk3588-media
    local package_root="${work_dir}/ffmpeg-package"
    local ffmpeg_prefix="${package_root}${install_prefix}"
    local mpp_libs="${ffmpeg_prefix}/lib"
    local version="${FFMPEG_VERSION}-1"

    git -C "${work_dir}/mpp" apply "${media_patches}/userspace/001-mpp-allocator-dma-heap-mainline-cma.patch"
    cmake -S "${work_dir}/mpp" -B "${work_dir}/mpp-build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_TEST=OFF -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_PREFIX="${ffmpeg_prefix}"
    cmake --build "${work_dir}/mpp-build" --parallel "${jobs}"
    cmake --install "${work_dir}/mpp-build"

    cd "${work_dir}/ffmpeg"
    for patch in "${media_patches}/ffmpeg/v4l2-request/"*.patch; do
        git apply "${patch}"
    done
    git apply "${media_patches}/ffmpeg/0016-v4l2request-hevc-set-sps-rps-controls.patch"

    export PKG_CONFIG_PATH="${mpp_libs}/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    export LD_LIBRARY_PATH="${mpp_libs}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    ./configure --prefix="${ffmpeg_prefix}" --disable-debug --disable-doc --disable-ffplay \
        --enable-gpl --enable-version3 --enable-libdrm --enable-libudev --enable-v4l2-request --enable-rkmpp \
        --enable-libpulse --enable-libopus --enable-libx264 --enable-libx265 \
        --enable-libxcb --enable-libxcb-shm --enable-libxcb-xfixes \
        --extra-ldflags="-Wl,-rpath,${install_prefix}/lib"
    make -j"${jobs}" ffmpeg ffprobe
    ./ffmpeg -hide_banner -hwaccels | grep -x v4l2request
    local encoders
    encoders=$(./ffmpeg -hide_banner -encoders)
    for encoder in h264_rkmpp hevc_rkmpp libopus; do
        grep -w "${encoder}" <<< "${encoders}"
    done
    ./ffmpeg -hide_banner -h demuxer=pulse | grep -w fragment_size

    local package="${work_dir}/ffmpeg-deb"
    install -Dm755 ffmpeg "${package}${install_prefix}/bin/ffmpeg"
    install -Dm755 ffprobe "${package}${install_prefix}/bin/ffprobe"
    mkdir -p "${package}${install_prefix}/lib"
    cp -a "${mpp_libs}"/librockchip_mpp.so* "${package}${install_prefix}/lib/"
    install -Dm644 COPYING.GPLv3 "${package}/usr/share/doc/rk3588-ffmpeg/COPYING.GPLv3"
    install -Dm644 "${work_dir}/mpp/LICENSES/Apache-2.0" "${package}/usr/share/doc/rk3588-ffmpeg/MPP-Apache-2.0"
    install -Dm644 "${work_dir}/mpp/LICENSES/MIT" "${package}/usr/share/doc/rk3588-ffmpeg/MPP-MIT"
    install -Dm644 "${repo_dir}/overlay/usr/lib/udev/rules.d/60-rk3588-mpp.rules" \
        "${package}/usr/lib/udev/rules.d/60-rk3588-mpp.rules"

    mkdir debian "${package}/DEBIAN"
    printf 'Source: rk3588-ffmpeg\n\nPackage: rk3588-ffmpeg\nArchitecture: any\n' > debian/control
    local deps
    deps=$(dpkg-shlibdeps --ignore-missing-info -l"${mpp_libs}" -O \
        "${package}${install_prefix}/bin/ffmpeg" "${package}${install_prefix}/bin/ffprobe")
    deps="${deps#shlibs:Depends=}"
    test -n "${deps}"
    cat > "${package}/DEBIAN/control" <<EOF
Package: rk3588-ffmpeg
Version: ${version}
Architecture: arm64
Maintainer: Ubuntu Rockchip contributors
Depends: ${deps}
Section: video
Priority: optional
Description: FFmpeg with RK3588 MPP encode and V4L2 Request decode
 Includes the Rockchip MPP runtime, PulseAudio capture and Opus encoding.
EOF
    dpkg-deb --build --root-owner-group "${package}" "${build_dir}/rk3588-ffmpeg_${version}_arm64.deb"
}

build_uu() {
    unpack_source uu-remote-linux VallierDev/uu-remote-linux "${UU_REV}" "${UU_SHA256}"
    cd "${work_dir}/uu-remote-linux"
    git apply "${repo_dir}/patches/uu-remote-linux/0001-rkmpp-encoder.patch"
    cargo test -j "${jobs}" --locked --features wayland,portal,engine-plugins --bin uuremote-server
    cargo build -j "${jobs}" --release --locked --features wayland,portal,engine-plugins --bin uuremote-server
    cargo build -j "${jobs}" --release --locked --features native-viewer,viewer-sdl --bin uuremote-viewer
    sh packaging/deb/build-deb.sh "${UU_VERSION}+rk3588.1" target/release "${build_dir}"
}

case "${1:-all}" in
    all) build_ffmpeg; build_uu ;;
    ffmpeg) build_ffmpeg ;;
    uu) build_uu ;;
    *) echo "Usage: $0 [ffmpeg|uu]" >&2; exit 2 ;;
esac
