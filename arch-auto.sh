#!/bin/bash
set -euo pipefail

# 错误处理
error_handler() {
    echo "错误发生在第 $1 行"
    exit 1
}
trap 'error_handler ${LINENO}' ERR

# 清理函数
cleanup() {
    echo "正在清理..."
    umount -R /mnt 2>/dev/null || true
}
trap cleanup EXIT

# 检查root权限
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要root权限运行" 
   exit 1
fi

# 检查UEFI模式
if [ ! -d "/sys/firmware/efi" ]; then
    echo "请在UEFI模式下运行此脚本"
    exit 1
fi

# 检查网络连接
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "无法连接到互联网,请检查网络设置"
    exit 1
fi

# 系统检测
CPU_TYPE=$(grep -m1 -E 'GenuineIntel|AuthenticAMD' /proc/cpuinfo | awk '{print $3}')
[ "$CPU_TYPE" = "GenuineIntel" ] && MICROCODE="intel-ucode" || MICROCODE="amd-ucode"
MEM_SIZE=$(($(grep MemTotal /proc/meminfo | awk '{print $2}')/1024))

# 用户输入
get_user_input() {
    # 用户名
    while true; do
        read -p "请输入用户名(只允许小写字母和数字): " USERNAME
        if [[ "$USERNAME" =~ ^[a-z0-9]+$ ]]; then
            break
        else
            echo "用户名格式不正确,请重试"
        fi
    done

    # 密码
    while true; do
        read -sp "请输入密码(至少4个字符): " PASSWORD
        echo
        if [ ${#PASSWORD} -ge 4 ]; then
            read -sp "请再次输入密码: " PASSWORD2
            echo
            if [ "$PASSWORD" = "$PASSWORD2" ]; then
                break
            else
                echo "两次密码不匹配,请重试"
            fi
        else
            echo "密码太短,请重试"
        fi
    done

    # 主机名
    while true; do
        read -p "请输入主机名: " HOSTNAME
        if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
            break
        else
            echo "主机名格式不正确,请重试"
        fi
    done
}

# 配置镜像源和下载参数
setup_mirrors() {

    # 禁用reflector服务和定时器
    systemctl stop reflector.service 2>/dev/null || true
    systemctl disable reflector.service 2>/dev/null || true
    systemctl stop reflector.timer 2>/dev/null || true
    systemctl disable reflector.timer 2>/dev/null || true
    
     # 设置镜像源
    echo 'Server = https://mirrors.bfsu.edu.cn/archlinux/$repo/os/$arch' > /etc/pacman.d/mirrorlist
 
    # 配置pacman参数
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf

    # 更新pacman数据库
    pacman -Syy
}

# 分区选择
select_partitions() {
    echo "列出可用磁盘和分区："
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
    echo

    # EFI分区选择
    local efi_partitions=($(lsblk -l -o NAME,SIZE,FSTYPE | grep "vfat" | awk '{print "/dev/"$1}'))
    if [ ${#efi_partitions[@]} -eq 0 ]; then
        echo "未找到EFI分区"
        exit 1
    fi

    echo "可用的EFI分区:"
    for i in "${!efi_partitions[@]}"; do
        echo "$((i+1))) ${efi_partitions[$i]}"
    done

    while true; do
        read -p "选择EFI分区 (1-${#efi_partitions[@]}): " efi_choice
        if [[ $efi_choice =~ ^[0-9]+$ ]] && [ $efi_choice -ge 1 ] && [ $efi_choice -le ${#efi_partitions[@]} ]; then
            EFI_PART=${efi_partitions[$((efi_choice-1))]}
            break
        else
            echo "无效选择,请重试"
        fi
    done

    # 根分区选择
    local root_partitions=($(lsblk -l -o NAME,SIZE,FSTYPE | grep -E "ext4|btrfs|xfs|f2fs" | awk '{print "/dev/"$1}'))
    if [ ${#root_partitions[@]} -eq 0 ]; then
        echo "未找到适合的根分区"
        exit 1
    fi

    echo "可用的根分区:"
    for i in "${!root_partitions[@]}"; do
        echo "$((i+1))) ${root_partitions[$i]}"
    done

    while true; do
        read -p "选择根分区 (1-${#root_partitions[@]}): " root_choice
        if [[ $root_choice =~ ^[0-9]+$ ]] && [ $root_choice -ge 1 ] && [ $root_choice -le ${#root_partitions[@]} ]; then
            ROOT_PART=${root_partitions[$((root_choice-1))]}
            break
        else
            echo "无效选择,请重试"
        fi
    done
}

# 卸载分区
unmount_all() {
    echo "正在卸载所有分区..."    
    # 按照挂载深度逆序卸载
    local mounted_parts=($(findmnt -n -R /mnt | tac | awk '{print $1}'))
    for part in "${mounted_parts[@]}"; do
        echo "卸载 $part"
        umount -f "$part" 2>/dev/null || true
    done

    # 确保关闭所有swap
    swapoff -a 2>/dev/null || true
}

# 格式化分区
format_partitions() {
    echo "格式化分区..."
    
    # 先卸载所有可能挂载的分区
    umount -f "$EFI_PART" 2>/dev/null || true
    umount -f "$ROOT_PART" 2>/dev/null || true
    
    # 如果ROOT_PART是btrfs，尝试卸载所有子卷
    if [ "$(lsblk -no FSTYPE "$ROOT_PART" 2>/dev/null)" = "btrfs" ]; then
        # 找到所有与此分区相关的挂载点
        local mount_points=$(findmnt -n -o TARGET -S "$ROOT_PART" | sort -r)
        for mp in $mount_points; do
            echo "卸载 $mp"
            umount -f "$mp" 2>/dev/null || true
        done
    fi
    
    # 等待几秒确保完全卸载
    sleep 2
    
    # 再次确认分区未挂载
    if mountpoint -q -- "/mnt" 2>/dev/null; then
        echo "卸载 /mnt"
        umount -R /mnt 2>/dev/null || true
        sleep 1
    fi
    
    # 使用swapoff确保交换分区关闭
    swapoff -a 2>/dev/null || true
    
    # 格式化EFI分区
    echo "格式化EFI分区 $EFI_PART"
    mkfs.fat -F32 "$EFI_PART"

    # 检查ROOT_PART是否仍然挂载
    if grep -q "$ROOT_PART" /proc/mounts; then
        echo "错误: $ROOT_PART 仍然挂载，请手动卸载后重试"
        exit 1
    fi

    # 格式化根分区
    echo "格式化根分区 $ROOT_PART"
    mkfs.btrfs -f "$ROOT_PART"
}

# 创建Btrfs子卷
create_btrfs_subvolumes() {
    echo "创建Btrfs子卷..."
    mount "$ROOT_PART" /mnt
    
    local subvolumes=("@" "@home" "@srv" "@var_log" "@var_cache" "@snapshots" "@swap")
    for subvol in "${subvolumes[@]}"; do
        btrfs subvolume create "/mnt/$subvol"
    done
    
    umount /mnt
}

# 挂载分区
mount_partitions() {
    echo "挂载分区..."
    
    # 挂载根分区和子卷
    mount -o subvol=@,compress=zstd:3,noatime "$ROOT_PART" /mnt
    
    mkdir -p /mnt/{home,srv,var/log,var/cache,.snapshots,swap,boot}
    
    mount -o subvol=@home,compress=zstd:3,noatime "$ROOT_PART" /mnt/home
    mount -o subvol=@srv,compress=zstd:3,noatime "$ROOT_PART" /mnt/srv
    mount -o subvol=@var_log,compress=zstd:3,noatime "$ROOT_PART" /mnt/var/log
    mount -o subvol=@var_cache,compress=zstd:3,noatime "$ROOT_PART" /mnt/var/cache
    mount -o subvol=@snapshots,compress=zstd:3,noatime "$ROOT_PART" /mnt/.snapshots
    mount -o subvol=@swap,compress=no "$ROOT_PART" /mnt/swap

    # 挂载EFI分区
    mount "$EFI_PART" /mnt/boot
    chmod 700 /mnt/boot
}

# 配置Swap
setup_swap() {
    echo "配置Swap..."
    # 获取内存大小（以KB为单位）
    local mem_size_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    
    # 将KB转换为GB（使用Bash内置计算）
    # 添加 0.5 后再向下取整实现四舍五入
    local mem_size_gb=$(( (mem_size_kb + (1024 * 1024 / 2)) / (1024 * 1024) ))    
    
    echo "系统内存大小: ${mem_size_gb}GB"
    echo "创建同等大小的swap文件..."
    
    truncate -s 0 /mnt/swap/swapfile
    chattr +C /mnt/swap/swapfile
    fallocate -l "${mem_size_gb}G" /mnt/swap/swapfile
    chmod 600 /mnt/swap/swapfile
    mkswap /mnt/swap/swapfile
    swapon /mnt/swap/swapfile
}

# 安装基本系统
install_base_system() {
    echo "安装基本系统..."
    
    local base_packages=(
        base base-devel linux linux-headers linux-firmware
        "$MICROCODE" btrfs-progs
        nano sudo networkmanager
        terminus-font man-db man-pages
        git wget curl
    )
    
    pacstrap /mnt "${base_packages[@]}"
}

# 生成fstab
generate_fstab() {
    echo "生成fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system() {
    echo "配置系统..."  

    # 转义 $ 符号，防止 $repo 和 $arch 在当前 shell 中被解析
    arch-chroot /mnt /bin/bash <<'EOL'
    
    # 禁用reflector服务
    systemctl mask reflector.service
    systemctl mask reflector.timer

    # 设置镜像源 - 使用单引号防止变量替换
    echo 'Server = https://mirrors.bfsu.edu.cn/archlinux/$repo/os/$arch' > /etc/pacman.d/mirrorlist
   
    # 配置pacman参数
    echo "配置pacman参数..."
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
EOL

    # 处理需要变量替换的命令 - 分开执行
    arch-chroot /mnt /bin/bash <<EOL
    # 时区
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    hwclock --systohc
    
    # 本地化设置
    echo "设置系统语言环境..."
    sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    sed -i 's/#zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=zh_CN.UTF-8" > /etc/locale.conf
    export LANG=zh_CN.UTF-8    

    # 设置系统默认键盘布局和终端字体
    cat > /etc/vconsole.conf << VCONSOLE
KEYMAP=us
FONT=ter-132n
FONT_MAP=8859-2
VCONSOLE

    # 网络配置
    echo "${HOSTNAME}" > /etc/hostname
    cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS
    
    # 创建用户并设置密码
    echo "创建用户 ${USERNAME}..."
    useradd -m -G wheel -s /bin/bash "${USERNAME}"
    echo "${USERNAME}:${PASSWORD}" | chpasswd

    # 允许 wheel 组的用户使用 sudo
    echo "配置 sudo 权限..."
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    
    # 安装桌面环境
    pacman -Syu --noconfirm plasma-meta sddm konsole kate dolphin \\
        firefox firefox-i18n-zh-cn \\
        fcitx5 fcitx5-configtool fcitx5-chinese-addons fcitx5-qt fcitx5-gtk \\
        noto-fonts-cjk noto-fonts-emoji ttf-dejavu
    
    # 引导配置
    bootctl install
    cat > /boot/loader/loader.conf << LOADER
default arch
timeout 2
console-mode keep
editor no
LOADER
    
    # 在chroot环境内获取UUID
    ROOT_UUID=\$(blkid -s UUID -o value ${ROOT_PART})
    
    cat > /boot/loader/entries/arch.conf << ENTRY
title Arch Linux
linux /vmlinuz-linux
initrd /${MICROCODE}.img
initrd /initramfs-linux.img
options root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw quiet splash
ENTRY
    
    # 启用服务
    systemctl enable NetworkManager
    systemctl enable sddm
    systemctl enable fstrim.timer

    # 配置KDE默认语言为中文
    sudo -u ${USERNAME} mkdir -p /home/${USERNAME}/.config
sudo -u ${USERNAME} bash -c 'cat > /home/${USERNAME}/.config/plasma-localerc << PLASMA
[Formats]
LANG=zh_CN.UTF-8
PLASMA'

    # 设置自动登录
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/kde_settings.conf << EOF
[Autologin]
User=${USERNAME}
Session=plasma.desktop
Relogin=false

[Theme]
Current=breeze

[General]
Numlock=on
EOF
EOL
}

# 安装后清理
post_install_cleanup() {
    echo "清理安装..."
    # 先关闭swap
    arch-chroot /mnt swapoff /swap/swapfile
    umount -R /mnt
}

# 主函数
main() {
    echo "开始Arch Linux安装..."
    
    get_user_input
    setup_mirrors 
    select_partitions
    unmount_all
    format_partitions
    create_btrfs_subvolumes
    mount_partitions
    setup_swap
    install_base_system
    generate_fstab
    configure_system
    post_install_cleanup
    
    echo "安装完成! 请重启系统。"
}

# 运行主函数
main
