#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

ROOTFS="ubuntu-${RELASE_VERSION}-${SUITE}-${FLAVOR}-arm64.rootfs.tar.xz"

if [[ -f ${ROOTFS} ]]; then
    exit 0
fi

# =========================================================
# 下载 ubuntu-base（固定路径，自动取最新点发布）
# =========================================================
BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${RELASE_VERSION}/release"
CHECKSUM="SHA256SUMS"

if [[ ! -f ${CHECKSUM} ]]; then
    echo "Downloading ${CHECKSUM}..."
    wget -O "${CHECKSUM}" "${BASE_URL}/${CHECKSUM}"
fi

# 自动匹配 ubuntu-base-xx.xx.xx-base-arm64.tar.gz 并取最新版
BASE_TAR=$(grep -oP 'ubuntu-base-\d+\.\d+(\.\d+)?-base-arm64\.tar\.gz' "${CHECKSUM}" | sort -V | tail -n1)

if [[ -z ${BASE_TAR} ]]; then
    echo "Error: cannot find ubuntu-base arm64 tarball"
    exit 1
fi

echo "Selected ubuntu-base: ${BASE_TAR}"

if [[ ! -f ${BASE_TAR} ]]; then
    wget -O "${BASE_TAR}" "${BASE_URL}/${BASE_TAR}"
fi

sha256sum -c <<< "$(grep "${BASE_TAR}" "${CHECKSUM}")"

# =========================================================
# 解压 ubuntu-base
# =========================================================
CHROOT_DIR=chroot

# 卸载 chroot 下的所有挂载点，可重复调用
unmount_chroot() {
    local dir
    for dir in dev/pts dev sys proc; do
        umount "${CHROOT_DIR}/${dir}" 2>/dev/null \
            || umount -lf "${CHROOT_DIR}/${dir}" 2>/dev/null \
            || true
    done
}

unmount_chroot
rm -rf ${CHROOT_DIR}
mkdir -p ${CHROOT_DIR}

echo "Extracting ubuntu-base..."
tar -xpf "${BASE_TAR}" -C "${CHROOT_DIR}"

# =========================================================
# 准备 chroot 环境
# =========================================================
mount -t proc proc ${CHROOT_DIR}/proc
mount -t sysfs sys ${CHROOT_DIR}/sys
mount -o bind /dev ${CHROOT_DIR}/dev
mount -o bind /dev/pts ${CHROOT_DIR}/dev/pts
cp /etc/resolv.conf ${CHROOT_DIR}/etc/resolv.conf

# 无论成功失败都卸载，避免 mount 泄漏到宿主机
trap 'unmount_chroot' EXIT

# 防止 dpkg 弹交互对话框（PKGS 里含 tzdata 等会提问的包）
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# /proc 是从宿主机 bind 进来的，chroot 里的 invoke-rc.d 会看到 PID 1 是
# systemd 并尝试启动服务。policy-rc.d 返回 101 让它直接放弃，否则包安装
# 会报错——而报错在 fail fast 模式下会直接终止构建。
cat > ${CHROOT_DIR}/usr/sbin/policy-rc.d << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x ${CHROOT_DIR}/usr/sbin/policy-rc.d

cat > ${CHROOT_DIR}/etc/apt/sources.list << EOF
deb http://ports.ubuntu.com ${SUITE} main restricted universe multiverse
deb http://ports.ubuntu.com ${SUITE}-security main restricted universe multiverse
deb http://ports.ubuntu.com ${SUITE}-updates main restricted universe multiverse
EOF

# 注意：这里的两条命令都必须带 chroot，否则 upgrade 会打到宿主机上
chroot ${CHROOT_DIR} apt-get -o Acquire::Retries=3 -y update
chroot ${CHROOT_DIR} apt-get -o Acquire::Retries=3 -y upgrade

# =========================================================
# 安装核心包
# =========================================================
#
# 关于 ubuntu-minimal / ubuntu-standard：
# 官方镜像是按 germinate seed 分层安装的（minimal -> standard -> server），
# 而 ubuntu-server / ubuntu-desktop 这两个 metapackage 只声明了自己那一层，
# 并不依赖下面两层。ubuntu-base 是个只有 87 个包的裸底座（连 systemd、udev、
# sudo 都没有），所以只装 ubuntu-server 会得到一个"感觉像 minimal"的系统：
# 没有 cron、logrotate、man-db、rsync、bash-completion、ufw、netplan 等等。
# 这里显式补上这两层，与官方 26.04 server cloud image 的清单保持一致。
# =========================================================
if [ "${PROJECT}" = "ubuntu" ]; then
    PKGS="
      ubuntu-minimal
      ubuntu-standard
      ubuntu-desktop
      localechooser-data
      firefox
      sudo
      nano
      vim
      htop
      curl
      wget
      git
      openssh-server
      fastfetch
      zstd
      unzip
      zip
    "
else
    PKGS="
      ubuntu-minimal
      ubuntu-standard
      ubuntu-server
      cloud-init
      netplan.io
      localechooser-data
      sudo
      nano
      vim
      htop
      kmod
      kbd
      tzdata
      unzip
      zip
      curl
      wget
      git
      iproute2
      mesa-vulkan-drivers
      alsa-utils
      pipewire
      pipewire-pulse
      wireplumber
      bluez
      bluetooth
      openssh-server
      fastfetch
      zstd
    "
fi

# =========================================================
# 预检包名是否都能解析
#
# apt 遇到一个不存在的包名会拒绝整个事务、一个包都不装。以前这一步跑在
# set +e 下，于是 26.04 里已被移除的 mesa-va-drivers 让整份 PKGS 全部
# 落空，产出的 server 镜像退化成裸 ubuntu-base。这里先逐个解析，把出问题
# 的包名直接点出来，而不是让 apt 抛一句笼统的错误。
# =========================================================
echo "Resolving package names..."
MISSING_PKGS=""
for pkg in ${PKGS}; do
    if ! chroot ${CHROOT_DIR} apt-cache show "${pkg}" > /dev/null 2>&1; then
        MISSING_PKGS="${MISSING_PKGS} ${pkg}"
    fi
done

if [ -n "${MISSING_PKGS}" ]; then
    echo "Error: the following packages do not exist in ${SUITE}:${MISSING_PKGS}"
    echo "They were probably renamed or removed in this Ubuntu release."
    exit 1
fi

chroot ${CHROOT_DIR} apt-get -o Acquire::Retries=3 -y install ${PKGS}

# =========================================================
# 体检：确认这套系统真的成型了，而不只是"apt 没报错"
#
# 这几个包是后续步骤的前提：systemd 决定 systemctl enable 能不能用，
# udev 负责创建 netdev 组，openssh-server 提供 sshd_config，
# server 版还要靠 cloud-init 消费 CIDATA 分区里的 user-data。
# =========================================================
REQUIRED_PKGS="systemd systemd-sysv udev sudo openssh-server"
if [ "${PROJECT}" = "ubuntu" ]; then
    REQUIRED_PKGS="${REQUIRED_PKGS} ubuntu-desktop"
else
    REQUIRED_PKGS="${REQUIRED_PKGS} ubuntu-server ubuntu-standard cloud-init netplan.io"
fi

echo "Verifying the installed system..."
for pkg in ${REQUIRED_PKGS}; do
    if ! chroot ${CHROOT_DIR} dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
        | grep -q "install ok installed"; then
        echo "Error: ${pkg} is not installed — the package installation did not take effect"
        exit 1
    fi
done

PKG_COUNT="$(chroot ${CHROOT_DIR} dpkg-query -f '.\n' -W | wc -l)"
echo "Installed package count: ${PKG_COUNT}"

# 裸 ubuntu-base 是 87 个包；正常的 server/desktop 远多于此。
# 数量级不对说明整份 PKGS 又落空了。
if [ "${PKG_COUNT}" -lt 300 ]; then
    echo "Error: only ${PKG_COUNT} packages installed, the rootfs looks like a bare ubuntu-base"
    exit 1
fi

# =========================================================
# 本地化：界面英文，但完整保留中文显示与输入能力
#
# 系统语言用 en_US.UTF-8（编码仍是 UTF-8，中文字符照样能存、能显示、能输入），
# 同时装上中文语言包和 CJK 字体，需要时切到中文只是改一个环境变量的事。
#
# 关键：这里绝对不能设 LC_ALL。LC_ALL 的优先级高于一切，会盖掉 SSH 客户端
# 通过 SendEnv 转发过来的 LANG/LC_*，也盖掉用户自己 export 的值——那正是
# 之前 ssh 连上去中文输入异常的根源。只设 LANG，把选择权留给会话。
# =========================================================
chroot "${CHROOT_DIR}" apt-get -o Acquire::Retries=3 -y install \
    locales language-pack-en language-pack-zh-hans fonts-noto-cjk

# 两个 locale 都生成：英文做默认，中文随时可切
for loc in "en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8"; do
    if ! grep -qx "${loc}" "${CHROOT_DIR}/etc/locale.gen" 2>/dev/null; then
        echo "${loc}" >> "${CHROOT_DIR}/etc/locale.gen"
    fi
done
chroot "${CHROOT_DIR}" locale-gen

# 全局默认英文（update-locale 只是在写这个文件，直接写更可靠）
cat > "${CHROOT_DIR}/etc/default/locale" << EOF
LANG=en_US.UTF-8
EOF

# /etc/environment 同步为英文。这里只精确删掉已有的 locale 行再追加，
# 不整体覆盖：该文件由 base-files 提供，里面的 PATH 含 /snap/bin 等条目，
# 覆盖写会把它们弄丢（server 版装了 snapd，PATH 少了 /snap/bin 会出问题）。
touch "${CHROOT_DIR}/etc/environment"
sed -i -E '/^[[:space:]]*(LANG|LANGUAGE|LC_ALL|LC_[A-Z_]+)=/d' \
    "${CHROOT_DIR}/etc/environment"
echo "LANG=en_US.UTF-8" >> "${CHROOT_DIR}/etc/environment"

# 校验两个 locale 都真的生成了，也确认没有任何地方残留 LC_ALL
if ! chroot "${CHROOT_DIR}" locale -a 2>/dev/null | grep -qi "en_US.utf8"; then
    echo "Error: en_US.UTF-8 locale was not generated"
    exit 1
fi

if ! chroot "${CHROOT_DIR}" locale -a 2>/dev/null | grep -qi "zh_CN.utf8"; then
    echo "Error: zh_CN.UTF-8 locale was not generated"
    exit 1
fi

if grep -rq "^LC_ALL=" "${CHROOT_DIR}/etc/environment" \
    "${CHROOT_DIR}/etc/default/locale" 2>/dev/null; then
    echo "Error: LC_ALL is still set, it would override the locale forwarded over SSH"
    exit 1
fi

# =========================================================
# 启用必备服务（chroot 必须手动开启）
# =========================================================
chroot "${CHROOT_DIR}" systemctl enable ssh
chroot ${CHROOT_DIR} systemctl enable systemd-resolved || true

if [ "${PROJECT}" = "ubuntu" ]; then
    chroot "${CHROOT_DIR}" systemctl enable NetworkManager
else
    chroot "${CHROOT_DIR}" systemctl enable systemd-networkd
fi

# =========================================================
# 仅服务器版：netplan 自动网络配置
# =========================================================
if [ "${PROJECT}" != "ubuntu" ]; then
mkdir -p "${CHROOT_DIR}/etc/netplan"
cat > "${CHROOT_DIR}/etc/netplan/00-auto-eth.yaml" <<EOF
network:
  renderer: networkd
  ethernets:
    all-usb-eth:
      match:
        name: en*
      dhcp4: true
      dhcp6: true
      optional: true
  version: 2
EOF
chmod 600 "${CHROOT_DIR}/etc/netplan/00-auto-eth.yaml"
fi

# =========================================================
# 安装 linux-firmware（手动）
# =========================================================
FIRMWARE_TARGET="${CHROOT_DIR}/usr/lib/firmware"

echo "Cleaning default firmware..."
rm -rf "${FIRMWARE_TARGET}"
mkdir -p "${FIRMWARE_TARGET}"

# Armbian 固件
# 加重试：这些下载现在是构建致命项（以前失败会静默留下空的 firmware 目录）
echo "Installing Armbian firmware..."
wget --tries=3 --timeout=30 -O armbian-fw.tar.gz https://github.com/armbian/firmware/archive/refs/heads/master.tar.gz
tar -xf armbian-fw.tar.gz
cp -Rf firmware-master/* "${FIRMWARE_TARGET}/"
rm -rf firmware-master armbian-fw.tar.gz

# 官方 linux-firmware
echo "Installing official linux-firmware..."
wget --tries=3 --timeout=30 -O linux-fw.tar.gz https://gitlab.com/kernel-firmware/linux-firmware/-/archive/main/linux-firmware-main.tar.gz
tar -xf linux-fw.tar.gz
cd linux-firmware-main

# 删除 x86 独显 / 计算卡，缩小rootfs体积
rm -rf nvidia amdgpu radeon amdnpu amdtee i915
rm -rf intel/avs intel/catpt intel/dsp* intel/fw_sst* intel/ice intel/ipu intel/ish intel/qat intel/vpu intel/vsc
cd ..
cp -Rf linux-firmware-main/* "${FIRMWARE_TARGET}/"
rm -rf linux-firmware-main linux-fw.tar.gz

echo "Fix firmware permissions..."
chown -R root:root "${FIRMWARE_TARGET}"
chmod -R 755 "${FIRMWARE_TARGET}"

# =======锁住firmware，防止执行apt更新覆盖=======
echo "Locking linux-firmware..."
chroot ${CHROOT_DIR} apt-mark hold linux-firmware 2>/dev/null || true

# =========================================================
# 主机名 / hosts
# =========================================================

# 防呆：BOARD 未传入时给出提示
if [ -z "${BOARD}" ]; then
    echo "Warning: BOARD is not set, using default hostname: rockchip"
fi

# 重要：给一个默认值，确保永远不会为空
FINAL_HOSTNAME="${BOARD:-rockchip}"

# 写入主机名 & hosts
echo "${FINAL_HOSTNAME}" > "${CHROOT_DIR}/etc/hostname"
cat > ${CHROOT_DIR}/etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   ${FINAL_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# =========================================================
# 禁止 cloud-init 覆盖主机名（Ubuntu 26.04 必须）
# =========================================================
mkdir -p "${CHROOT_DIR}/etc/cloud/cloud.cfg.d"
cat > "${CHROOT_DIR}/etc/cloud/cloud.cfg.d/99-no-hostname-override.cfg" << EOF
manage_hostname: false
preserve_hostname: true
EOF

# =========================================================
# 增强：root 串口登录
# =========================================================
echo "Adding securetty for root login..."
cat > ${CHROOT_DIR}/etc/securetty << EOF
ttyS0
ttyS1
ttyS2
ttyS3
ttyAMA0
ttyAML0
tty1
tty2
tty3
EOF

# =========================================================
# 用户 / 时区 / SSH
# =========================================================

# useradd 的 -G 是原子的：只要有一个组不存在，它就整体失败、一个用户都不建。
# sudo/audio/video/plugdev/dialout 由 base-passwd 提供（ubuntu-base 自带），
# 但 netdev 是靠包的 postinst 动态创建的，不保证存在——先补齐再建用户。
USER_GROUPS="sudo audio video plugdev netdev dialout"
for grp in ${USER_GROUPS}; do
    if ! chroot ${CHROOT_DIR} getent group "${grp}" > /dev/null; then
        echo "Group ${grp} is missing, creating it..."
        chroot ${CHROOT_DIR} groupadd --system "${grp}"
    fi
done

if chroot ${CHROOT_DIR} id -u ubuntu > /dev/null 2>&1; then
    # 新版 ubuntu-base 可能已预置 ubuntu 用户，此时 useradd 会失败，改用 usermod
    echo "User ubuntu already exists, adding it to the required groups..."
    chroot ${CHROOT_DIR} usermod -s /bin/bash \
        -aG "$(echo ${USER_GROUPS} | tr ' ' ',')" ubuntu

    # 预置的用户不一定有家目录，补齐（否则下面的校验会拦下来）
    if [ ! -d "${CHROOT_DIR}/home/ubuntu" ]; then
        echo "Creating the missing home directory for ubuntu..."
        chroot ${CHROOT_DIR} mkdir -p /home/ubuntu
        chroot ${CHROOT_DIR} cp -a /etc/skel/. /home/ubuntu/
        chroot ${CHROOT_DIR} chown -R ubuntu: /home/ubuntu
        chroot ${CHROOT_DIR} chmod 750 /home/ubuntu
    fi
else
    chroot ${CHROOT_DIR} useradd -m -s /bin/bash \
        -G "$(echo ${USER_GROUPS} | tr ' ' ',')" ubuntu
fi

echo 'ubuntu:ubuntu' | chroot ${CHROOT_DIR} chpasswd
echo 'root:root' | chroot ${CHROOT_DIR} chpasswd

# =========================================================
# 校验用户真的建成了
#
# 这是本脚本历史上最容易静默失败的一步：以前整段跑在 set +e 下，
# useradd 失败也照样打包，结果产出只有 root 用户的镜像。
# =========================================================
echo "Verifying the ubuntu user..."

if ! chroot ${CHROOT_DIR} id ubuntu; then
    echo "Error: user ubuntu was not created"
    exit 1
fi

if [ ! -d "${CHROOT_DIR}/home/ubuntu" ]; then
    echo "Error: home directory /home/ubuntu is missing"
    exit 1
fi

if ! chroot ${CHROOT_DIR} id -nG ubuntu | tr ' ' '\n' | grep -qx sudo; then
    echo "Error: user ubuntu is not in the sudo group"
    exit 1
fi

# 密码字段必须是真实的 hash：既不能为空，也不能是 ! 或 * 开头的锁定状态
for account in ubuntu root; do
    pw_hash="$(chroot ${CHROOT_DIR} getent shadow "${account}" | cut -d: -f2)"
    case "${pw_hash}" in
        ''|'!'*|'*'*)
            echo "Error: password for ${account} was not set (shadow field: '${pw_hash}')"
            exit 1
            ;;
    esac
done

echo "User verification passed: ubuntu (sudo) and root both have passwords set"

chroot ${CHROOT_DIR} ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > ${CHROOT_DIR}/etc/timezone

chroot ${CHROOT_DIR} sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
chroot ${CHROOT_DIR} sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
chroot ${CHROOT_DIR} systemctl enable ssh

# =========================================================
# 清理
# =========================================================
chroot ${CHROOT_DIR} apt-get clean

# 必须删掉，否则它会留在最终镜像里，让目标系统上后续安装的包都不启动服务
rm -f ${CHROOT_DIR}/usr/sbin/policy-rc.d

rm -rf ${CHROOT_DIR}/var/lib/apt/lists/*
rm -rf ${CHROOT_DIR}/tmp/* ${CHROOT_DIR}/tmp/.[!.]*

# =========================================================
# 卸载
# =========================================================
unmount_chroot
trap - EXIT

# =========================================================
# 打包 rootfs
# =========================================================
echo "Listing chroot/ directory before tarring:"
ls -l ${CHROOT_DIR}/

# 用 . 而不是 ./*，后者是 shell glob、会漏掉顶层的隐藏文件
(cd ${CHROOT_DIR}/ && tar -p -c --sort=name --xattrs .) | \
    xz -3 -T0 > "${ROOTFS}"

echo "Listing current directory after tarring:"
ls -l

echo "Listing parent directory after moving the file:"
