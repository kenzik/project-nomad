#!/bin/bash
# Build the generic backup CachyOS on the NOMAD drive's NOMAD_ROOT / NOMAD_ESP partitions.
# Run from the primary OS. The result boots on any x86-64 PC (UEFI removable path and legacy
# BIOS) when the drive is moved to a USB enclosure, is itself a bootstrapped NOMAD host, and is
# reachable over SSH from first boot (the primary user's authorized_keys are carried over).
#
# DESTRUCTIVE to NOMAD_ROOT and NOMAD_ESP only. Targets are resolved by partition label, must sit
# on the same disk as NOMAD_DATA, must not be the running system's disk, and you confirm the
# disk serial before anything is formatted. Firmware boot entries (NVRAM) are never touched.
#
#   sudo bash build-backup-os.sh --user NAME [--hostname NAME] [--no-desktop] [--no-nvidia] [--no-rocm]
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"

user= host_name=nomad-rescue desktop=yes nvidia=yes rocm=yes
while (($#)); do
  case $1 in
    --user) user=$2; shift 2 ;;
    --hostname) host_name=$2; shift 2 ;;
    --no-desktop) desktop=no; shift ;;
    --no-nvidia) nvidia=no; shift ;;
    --no-rocm) rocm=no; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done
need_root "$@"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--user NAME is required (lowercase login name)"
for c in pacstrap arch-chroot genfstab blkid mkfs.ext4 mkfs.fat systemd-machine-id-setup; do
  command -v "$c" >/dev/null || die "Missing command: $c (pacman -S arch-install-scripts dosfstools e2fsprogs)"
done

ESP=/dev/disk/by-partlabel/NOMAD_ESP
ROOT=/dev/disk/by-partlabel/NOMAD_ROOT
DATA=/dev/disk/by-partlabel/NOMAD_DATA
for p in "$ESP" "$ROOT" "$DATA"; do [[ -b $p ]] || die "Missing partition: $p"; done

disk=$(disk_of "$ROOT")
[[ $(disk_of "$ESP") == "$disk" && $(disk_of "$DATA") == "$disk" ]] ||
  die "NOMAD_ESP, NOMAD_ROOT and NOMAD_DATA are not on the same disk"
for mp in / /home /boot /boot/efi; do
  for d in $(disks_backing "$mp"); do
    [[ $d == "$disk" ]] && die "$mp lives on /dev/$disk; run this from the primary OS"
  done
done
for p in "$ESP" "$ROOT"; do
  findmnt -S "$(readlink -f "$p")" >/dev/null && die "$p is mounted; unmount it first"
done

info "Target disk"
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,PARTLABEL,MOUNTPOINTS "/dev/$disk"
serial=$(lsblk -dno SERIAL "/dev/$disk")
echo
echo "NOMAD_ESP and NOMAD_ROOT on this disk will be FORMATTED. NOMAD_DATA is not touched."
read -r -p "Type the last 4 characters of the serial ($serial) to continue: " answer
[[ -n $serial && $answer == "${serial: -4}" ]] || die "Serial mismatch; nothing was changed"

T=/run/nomad-backup-os
conf=$(mktemp)
cleanup() { umount -R "$T" 2>/dev/null || true; rm -f "$conf"; }
trap cleanup EXIT

mkfs.ext4 -F -L NOMAD_ROOT "$ROOT"
mkfs.fat -F 32 -n NOMAD_ESP "$ESP"
mkdir -p "$T"
mount "$ROOT" "$T"
mkdir -p "$T/boot"
mount -o fmask=0077,dmask=0077 "$ESP" "$T/boot"
root_uuid=$(blkid -s UUID -o value "$ROOT")

# Generic repos only: no znver4/v3/v4 binaries may land on this OS.
cat > "$conf" <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = x86_64
Color
ParallelDownloads = 10
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
EOF

gpu=vulkan
pkgs=(base linux-firmware amd-ucode intel-ucode mkinitcpio sudo nano networkmanager ufw openssh
  zram-generator e2fsprogs dosfstools btrfs-progs gptfdisk arch-install-scripts rsync git curl
  zstd usbutils pciutils nvme-cli smartmontools archlinux-keyring cachyos-keyring
  cachyos-mirrorlist mesa vulkan-icd-loader vulkan-radeon vulkan-intel intel-media-driver
  docker docker-compose ollama ollama-vulkan)
if [[ $nvidia == yes ]]; then pkgs+=(nvidia-utils ollama-cuda); gpu+=,cuda; fi
if [[ $rocm == yes ]]; then pkgs+=(ollama-rocm); gpu+=,rocm; fi
if [[ $desktop == yes ]]; then
  pkgs+=(plasma-desktop plasma-nm plasma-pa kscreen powerdevil sddm konsole dolphin firefox
    pipewire pipewire-pulse wireplumber noto-fonts ttf-dejavu)
fi

# Stage 1: everything except kernels and Limine. Their pacman hooks build the initramfs and
# deploy the bootloader, so the configuration below has to exist first.
info "Stage 1: pacstrap (${#pkgs[@]} packages)"
pacstrap -C "$conf" -K "$T" "${pkgs[@]}"

install -m644 "$conf" "$T/etc/pacman.conf"
install -m644 /etc/pacman.d/mirrorlist "$T/etc/pacman.d/mirrorlist"
install -m644 /etc/pacman.d/cachyos-mirrorlist "$T/etc/pacman.d/cachyos-mirrorlist"
arch-chroot "$T" pacman-key --populate archlinux cachyos || warn "Keyring populate failed; fix before updating this OS"

# Kernels are stored under $ESP/<machine-id>/, so the ID must exist before they install.
systemd-machine-id-setup --root="$T"

# No autodetect: the initramfs carries every storage/USB/GPU driver and both vendors' microcode
# instead of only what this machine uses. No chwd configs, no forced NVIDIA modules.
install -d "$T/etc/mkinitcpio.conf.d"
cat > "$T/etc/mkinitcpio.conf.d/10-nomad-portable.conf" <<'EOF'
MODULES=()
HOOKS=(base systemd microcode kms modconf block keyboard sd-vconsole filesystems)
EOF
[[ -f /etc/vconsole.conf ]] && install -m644 /etc/vconsole.conf "$T/etc/vconsole.conf" || echo 'KEYMAP=us' > "$T/etc/vconsole.conf"

# SKIP_UEFI: never call efibootmgr (it would write into THIS machine's firmware from the chroot).
# ENABLE_LIMINE_FALLBACK: install to EFI/BOOT/BOOTX64.EFI, the path firmware uses for removable media.
cat > "$T/etc/default/limine" <<EOF
ESP_PATH="/boot"
SKIP_UEFI=yes
ENABLE_LIMINE_FALLBACK=yes
FIND_BOOTLOADERS=no
KERNEL_CMDLINE[default]="root=UUID=$root_uuid rw quiet nowatchdog"
BOOT_ORDER="*, *lts, *fallback"
EOF

genfstab -U "$T" | grep -vw swap > "$T/etc/fstab"

echo "$host_name" > "$T/etc/hostname"
ln -sf "$(readlink -f /etc/localtime)" "$T/etc/localtime"
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$T/etc/locale.gen"
echo 'LANG=en_US.UTF-8' > "$T/etc/locale.conf"
arch-chroot "$T" locale-gen
printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' > "$T/etc/systemd/zram-generator.conf"

info "Stage 2: kernels and bootloader"
stage2=(linux-cachyos linux-cachyos-lts limine limine-mkinitcpio-hook)
[[ $nvidia == yes ]] && stage2+=(linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open)
arch-chroot "$T" pacman -Sy --noconfirm --needed "${stage2[@]}"

# Legacy BIOS: stage 1 into partition 1 (NOMAD_BIOS), stage 2 file on the ESP.
arch-chroot "$T" limine bios-install "/dev/$disk" 1
install -m644 "$T/usr/share/limine/limine-bios.sys" "$T/boot/limine-bios.sys"

info "Users and services"
arch-chroot "$T" useradd -m -G wheel -s /bin/bash "$user"
echo '%wheel ALL=(ALL:ALL) ALL' > "$T/etc/sudoers.d/10-wheel"
chmod 440 "$T/etc/sudoers.d/10-wheel"
echo "Set a password for '$user' on the backup OS:"
arch-chroot "$T" passwd "$user"
arch-chroot "$T" passwd -l root >/dev/null

# Same SSH keys as this host's user, so the backup OS is reachable without a console.
src_home=$(getent passwd "$user" | cut -d: -f6 || true)
if [[ -n $src_home && -s $src_home/.ssh/authorized_keys ]]; then
  install -d -m700 "$T/home/$user/.ssh"
  install -m600 "$src_home/.ssh/authorized_keys" "$T/home/$user/.ssh/authorized_keys"
  arch-chroot "$T" chown -R "$user:$user" "/home/$user/.ssh"
  info "Copied $src_home/.ssh/authorized_keys for '$user'"
fi

# ufw programs live chains only when ufw.conf says ENABLED=yes. With the package default (no) the
# rule is just written to user.rules, which is what we want: inside the chroot, "live" would mean
# THIS host's firewall. So add rules first, then enable.
grep -q '^ENABLED=no' "$T/etc/ufw/ufw.conf" || die "$T/etc/ufw/ufw.conf is not ENABLED=no; refusing to run ufw in the chroot"
arch-chroot "$T" ufw allow 22/tcp comment 'sshd' >/dev/null
sed -i 's/^ENABLED=no/ENABLED=yes/' "$T/etc/ufw/ufw.conf"
arch-chroot "$T" systemctl enable NetworkManager.service ufw.service sshd.service systemd-timesyncd.service fstrim.timer
[[ $desktop == yes ]] && arch-chroot "$T" systemctl enable sddm.service

info "NOMAD host bootstrap inside the backup OS"
rm -rf "$T/opt/nomad-toolkit"
cp -a "$here" "$T/opt/nomad-toolkit"
arch-chroot "$T" bash /opt/nomad-toolkit/bootstrap-host.sh --chroot --autostart --expose=lan --gpu="$gpu" --yes

info "Verifying"
fail=0
[[ -f $T/boot/EFI/BOOT/BOOTX64.EFI ]] || { warn "EFI/BOOT/BOOTX64.EFI missing on the ESP"; fail=1; }
[[ -f $T/boot/limine-bios.sys ]] || { warn "limine-bios.sys missing on the ESP"; fail=1; }
grep -q "$root_uuid" "$T/boot/limine.conf" 2>/dev/null || { warn "limine.conf has no entry for root UUID $root_uuid"; fail=1; }
find "$T/boot" -name 'initramfs*' | grep -q . || { warn "No initramfs found on the ESP"; fail=1; }
grep -q -- '--dport 22 ' "$T/etc/ufw/user.rules" || { warn "ufw has no rule for port 22; sshd would be unreachable"; fail=1; }
nongeneric=$(arch-chroot "$T" pacman -Qi | awk '/^Name/{n=$3} /^Architecture/{if($3!="x86_64"&&$3!="any")print n,$3}')
[[ -z $nongeneric ]] || { warn "Non-generic packages installed:"; echo "$nongeneric"; fail=1; }

sync
((fail == 0)) || die "Backup OS built with problems; see warnings above"
info "Backup OS ready on /dev/$disk. Test: reboot, open the firmware boot menu, pick the Lexar/'UEFI OS' entry."
