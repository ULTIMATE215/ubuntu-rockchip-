## Overview

[Latest GitHub Release Ubuntu](https://github.com/Lemon1151/ubuntu-rockchip/releases/latest)

## Notes

* Ubuntu 26.04 LTS comes with Ubuntu Linux 7.0.
* Default credentials:
  * `root`: `root`
  * `ubuntu`: `ubuntu`
* SSH is enabled by default, and root login is permitted.

**Important:** Upon first login, you must change the passwords for both the `root` and `ubuntu` accounts.
  
Ubuntu Rockchip is a community project porting Ubuntu to Rockchip hardware with the goal of providing a stable and fully functional environment.

## Highlights

* Available for both Ubuntu 22.04 LTS (with Rockchip Linux 5.10) and Ubuntu 24.04 LTS (with Rockchip Linux 6.1)
* Package management via apt using the official Ubuntu repositories
* Receive all updates and changes through apt
* Desktop first-run wizard for user setup and configuration
* 3D hardware acceleration support via panfork
* Fully working GNOME desktop using wayland
* Chromium browser with smooth 4k youtube video playback
* MPV video player capable of smooth 4k video playback

## RK3588 hardware video decoding on Ubuntu 26.04

Resolute desktop and server images for RK3588, RK3588S and RK3588S2 include
GStreamer's `v4l2codecs` plugin for H.264, H.265 and AV1 hardware decoding via
the kernel's V4L2 Request API. The default `ubuntu` account has access through
the `video` group.

On an existing Resolute installation with the project's 7.0 Rockchip kernel,
install the same packages.

```sh
sudo apt install --no-install-recommends gstreamer1.0-plugins-bad gstreamer1.0-tools v4l-utils
```

List the available hardware decoders and test an H.265 MP4 clip without a
display. The explicit `v4l2slh265dec` element requires hardware decoding.

```sh
gst-inspect-1.0 v4l2codecs
gst-launch-1.0 -v filesrc location=sample-hevc.mp4 ! qtdemux ! h265parse ! \
    v4l2slh265dec ! fakesink sync=false
```

For 4K H.264, GStreamer 1.28 may automatically select the Hantro decoder, which
is limited to 1920 × 1088. Use `v4l2-ctl --list-devices` to find the `rkvdec`
video node and inspect the H.264 elements with `gst-inspect-1.0` to find the
one whose `video-device` matches. If it is `v4l2slvideo3h264dec`, test it
explicitly.

```sh
gst-launch-1.0 -v filesrc location=sample-h264.mp4 ! qtdemux ! h264parse ! \
    v4l2slvideo3h264dec ! fakesink sync=false
```

## Installation

### RK3588 H.264 encoding on Orange Pi 5 Plus

On Ubuntu 26.04, the stable kernel profile builds Linux 7.3.6 with the
VEPU580 RKVENC driver and the Orange Pi 5 Plus device tree for one encoder
core. The FFmpeg package combines the `h264_rkmpp` encoder, V4L2 Request
decoders, PulseAudio capture and Opus. The UU package adds the explicit
`rkmpp` encoder selection to uu-remote-linux 0.2.46.

Build the packages on ARM64 Ubuntu 26.04 with the dependencies listed in
the [stable package workflow](.github/workflows/build-resolute-stable.yml).

```sh
sudo ./build.sh --suite=resolute --kernel=stable --kernel-only
sudo bash scripts/build-rk3588-media.sh
```

For an existing Ubuntu 26.04 installation, install the image and headers
from `build/stable-kernel/`, then install `rk3588-ffmpeg` and
`uu-remote-linux` from `build/`. The workflow builds these four packages
as downloadable artifacts. An Orange Pi 5 Plus image can also be built
with `sudo ./build.sh --suite=resolute --board=orangepi-5-plus --flavor=desktop --kernel=stable`.

On an extlinux installation, update the menu with `sudo u-boot-update`.
Boot the new kernel and check that `uname -r` reports `7.3.6-rockchip`.
Verify that both the MPP device and CMA heap are present, then encode and
decode a synthetic clip.

```sh
ls -l /dev/mpp_service /dev/dma_heap/default_cma_region
clip=$(mktemp --suffix=.h264)
/opt/rk3588-media/bin/ffmpeg -y -f lavfi -i 'testsrc2=s=1920x1080:r=30' \
    -frames:v 60 -pix_fmt nv12 -g 30 -c:v h264_rkmpp -f h264 "$clip" &&
    /opt/rk3588-media/bin/ffmpeg -v error -xerror -i "$clip" -f null -
```

Set `UU_FFMPEG_ROOT=/opt/rk3588-media` in the user service with
`systemctl --user edit uuremote-native.service`.

```ini
[Service]
Environment=UU_FFMPEG_ROOT=/opt/rk3588-media
```

```sh
systemctl --user restart uuremote-native.service
uuremote-server set-encoder rkmpp
uuremote-server set-codec h264
```

During a remote session, the live FFmpeg process should use `-c:v h264_rkmpp`
and the service log should show frames being sent. The encoder takes NV12
frames, so desktop capture and color conversion still use the CPU.

### Writing an image

Make sure you use a good, reliable, and fast SD card. For example, suppose you encounter boot or stability troubles. Most of the time, this is due to either an insufficient power supply or related to your SD card (bad card, bad card reader, something went wrong when burning the image, or the card is too slow).

Download the Ubuntu image for your specific board from the latest [release](https://github.com/Joshua-Riek/ubuntu-rockchip/releases) on GitHub or from the dedicated download [website](https://joshua-riek.github.io/ubuntu-rockchip-download/). Then write the xz compressed image (no previous unpacking necessary) to your SD card using [USBimager](https://bztsrc.gitlab.io/usbimager/) or [balenaEtcher](https://www.balena.io/etcher) since, unlike other tools, these can validate burning results, saving you from corrupted SD card contents.

## Boot the System

Insert your SD card into the slot on the board and power on the device. The first boot may take up to two minutes, so please be patient.

## Login Information

For Ubuntu Server you will be able to login through HDMI, a serial console connection, or SSH. The predefined user is `ubuntu` and the password is `ubuntu`.

For Ubuntu Desktop you must connect through HDMI and follow the setup-wizard.

## Support the Project

There are a few things you can do to support the project:

* Star the repository and follow me on GitHub
* Share and upvote on sites like Twitter, Reddit, and YouTube
* Report any bugs, glitches, or errors that you find (some bugs I may not be able to fix)
* Sponsor me on GitHub; any contribution will be greatly appreciated

These things motivate me to continue development and provide validation that my work is appreciated. Thanks in advance!

---
> Ubuntu is a trademark of Canonical Ltd. Rockchip is a trademark of Fuzhou Rockchip Electronics Co., Ltd. The Ubuntu Rockchip project is not affiliated with Canonical Ltd or Fuzhou Rockchip Electronics Co., Ltd. All other product names, logos, and brands are property of their respective owners. The Ubuntu name is owned by [Canonical Limited](https://ubuntu.com/).
