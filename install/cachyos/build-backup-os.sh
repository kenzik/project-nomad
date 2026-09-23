#!/bin/bash
# Build the generic backup CachyOS on the NOMAD drive's NOMAD_ROOT / NOMAD_ESP partitions, or
# refresh one that already exists. Run from the primary OS. The result boots on any x86-64 PC
# (UEFI removable path and legacy BIOS) when the drive is moved to a USB enclosure, is itself a
# bootstrapped NOMAD host, is reachable over SSH from first boot, and looks like the primary: the
# same CachyOS Hyprland + Noctalia edition, greeter, login shell and the user's own desktop
# dotfiles, with a different Noctalia palette so the two systems are told apart at a glance.
#
# Build (DESTRUCTIVE to NOMAD_ROOT and NOMAD_ESP only; NOMAD_DATA is never touched):
#   sudo bash build-backup-os.sh --user NAME [--hostname NAME] [--theme NAME] [--no-desktop] [--no-nvidia] [--no-rocm]
# Refresh in place (nothing is formatted: upgrade packages, re-apply configs, re-sync dotfiles):
#   sudo bash build-backup-os.sh --user NAME --refresh [same flags]
#
# Targets are resolved by partition label, must sit on the same disk as NOMAD_DATA and must not be
# the running system's disk; a build asks for the disk serial before formatting. Firmware boot
# entries (NVRAM) are never touched.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"

user= host_name=nomad-rescue theme=Nord desktop=yes nvidia=yes rocm=yes refresh=no
while (($#)); do
  case $1 in
    --user) user=$2; shift 2 ;;
    --hostname) host_name=$2; shift 2 ;;
    --theme) theme=$2; shift 2 ;;
    --no-desktop) desktop=no; shift ;;
    --no-nvidia) nvidia=no; shift ;;
    --no-rocm) rocm=no; shift ;;
    --refresh) refresh=yes; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done
need_root "$@"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--user NAME is required (lowercase login name)"
for c in pacstrap arch-chroot genfstab blkid mkfs.ext4 mkfs.fat systemd-machine-id-setup rsync; do
  command -v "$c" >/dev/null || die "Missing command: $c (pacman -S arch-install-scripts dosfstools e2fsprogs rsync)"
done
# Noctalia's builtin palettes (its settings GUI has the authoritative list).
case $theme in
  Ayu|Catppuccin|Dracula|Gruvbox|Kanagawa|Nord|Oxocarbon|Tokyo-Night) ;;
  *) warn "--theme $theme is not a Noctalia builtin palette I know of; Noctalia may reject it" ;;
esac

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
echo
if [[ $refresh == no ]]; then
  serial=$(lsblk -dno SERIAL "/dev/$disk")
  echo "NOMAD_ESP and NOMAD_ROOT on this disk will be FORMATTED. NOMAD_DATA is not touched."
  read -r -p "Type the last 4 characters of the serial ($serial) to continue: " answer
  [[ -n $serial && $answer == "${serial: -4}" ]] || die "Serial mismatch; nothing was changed"
else
  echo "Refresh: nothing is formatted. The backup OS on NOMAD_ROOT is upgraded and re-configured."
fi

T=/run/nomad-backup-os
conf=$(mktemp)
cleanup() { umount -R "$T" 2>/dev/null || true; rm -f "$conf"; }
trap cleanup EXIT

if [[ $refresh == no ]]; then
  mkfs.ext4 -F -L NOMAD_ROOT "$ROOT"
  mkfs.fat -F 32 -n NOMAD_ESP "$ESP"
fi
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
# cachyos-settings/-hooks give the system-level CachyOS defaults (sysctl, zram, udev, branding);
# cachyos-settings also points NetworkManager at systemd-resolved, enabled below.
pkgs=(base linux-firmware amd-ucode intel-ucode mkinitcpio sudo nano networkmanager ufw openssh
  inetutils avahi zram-generator e2fsprogs dosfstools btrfs-progs gptfdisk arch-install-scripts
  rsync git curl zstd usbutils pciutils nvme-cli smartmontools archlinux-keyring cachyos-keyring
  cachyos-mirrorlist cachyos-settings cachyos-hooks lsb-release mesa vulkan-icd-loader vulkan-radeon
  vulkan-intel intel-media-driver docker docker-compose ollama ollama-vulkan)
if [[ $nvidia == yes ]]; then pkgs+=(nvidia-utils ollama-cuda); gpu+=,cuda; fi
if [[ $rocm == yes ]]; then pkgs+=(ollama-rocm); gpu+=,rocm; fi
if [[ $desktop == yes ]]; then
  # The CachyOS Hyprland + Noctalia edition as the installer lays it out. The meta package brings
  # hyprland, noctalia, kitty, dolphin, portals, uwsm and base fonts; the greeter is separate.
  pkgs+=(cachyos-hypr-noctalia noctalia-greeter cachyos-wallpapers cachyos-zsh-config
    cachyos-fish-config cachyos-micro-settings firefox pavucontrol btop fastfetch xdg-user-dirs
    bluez bluez-utils upower pipewire pipewire-alsa pipewire-pulse wireplumber gst-plugin-pipewire
    noto-fonts-cjk cantarell-fonts ttf-dejavu ttf-liberation ttf-bitstream-vera ttf-opensans
    ttf-firacode-nerd ttf-meslo-nerd ttf-nerd-fonts-symbols-mono)
fi
stage2=(linux-cachyos linux-cachyos-lts limine limine-mkinitcpio-hook)
[[ $nvidia == yes ]] && stage2+=(linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open)

if [[ $refresh == no ]]; then
  # Stage 1: everything except kernels and Limine. Their pacman hooks build the initramfs and
  # deploy the bootloader, so the configuration below has to exist first.
  info "Stage 1: pacstrap (${#pkgs[@]} packages)"
  pacstrap -C "$conf" -K "$T" "${pkgs[@]}"
  install -m644 "$conf" "$T/etc/pacman.conf"
fi
install -m644 /etc/pacman.d/mirrorlist "$T/etc/pacman.d/mirrorlist"
install -m644 /etc/pacman.d/cachyos-mirrorlist "$T/etc/pacman.d/cachyos-mirrorlist"
# arch-chroot only bind-mounts this host's resolv.conf over a regular file in the target, so a
# resolved stub symlink there (from an earlier run) would leave the chroot without DNS. Give it a
# plain copy for the duration; the symlink is restored at the end under "Network".
rm -f "$T/etc/resolv.conf"
install -m644 /etc/resolv.conf "$T/etc/resolv.conf"
arch-chroot "$T" pacman-key --populate archlinux cachyos || warn "Keyring populate failed; fix before updating this OS"

if [[ $refresh == no ]]; then
  # Kernels are stored under $ESP/<machine-id>/, so the ID must exist before they install.
  systemd-machine-id-setup --root="$T"
fi

# SKIP_UEFI: never call efibootmgr (it would write into THIS machine's firmware from the chroot).
# ENABLE_LIMINE_FALLBACK: install to EFI/BOOT/BOOTX64.EFI, the path firmware uses for removable media.
# LTS first: the 7.2.x amdgpu regression (Strix/DCN 3.5, 2026-09) leaves the display showing a
# stale buffer after a compositor handoff (logout → greeter); 6.18 LTS is fine. Also the safer
# default for a drive that must boot unknown hardware.
cat > "$T/etc/default/limine" <<EOF
ESP_PATH="/boot"
SKIP_UEFI=yes
ENABLE_LIMINE_FALLBACK=yes
FIND_BOOTLOADERS=no
KERNEL_CMDLINE[default]="root=UUID=$root_uuid rw quiet nowatchdog"
BOOT_ORDER="*lts, *, *fallback"
EOF

if [[ $refresh == no ]]; then
  # No autodetect: the initramfs carries every storage/USB/GPU driver and both vendors' microcode
  # instead of only what this machine uses. No chwd configs, no forced NVIDIA modules.
  install -d "$T/etc/mkinitcpio.conf.d"
  cat > "$T/etc/mkinitcpio.conf.d/10-nomad-portable.conf" <<'EOF'
MODULES=()
HOOKS=(base systemd microcode kms modconf block keyboard sd-vconsole filesystems)
EOF
  [[ -f /etc/vconsole.conf ]] && install -m644 /etc/vconsole.conf "$T/etc/vconsole.conf" || echo 'KEYMAP=us' > "$T/etc/vconsole.conf"

  genfstab -U "$T" | grep -vw swap > "$T/etc/fstab"
  ln -sf "$(readlink -f /etc/localtime)" "$T/etc/localtime"
  sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$T/etc/locale.gen"
  echo 'LANG=en_US.UTF-8' > "$T/etc/locale.conf"
  arch-chroot "$T" locale-gen
  printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' > "$T/etc/systemd/zram-generator.conf"

  info "Stage 2: kernels and bootloader"
  arch-chroot "$T" pacman -Sy --noconfirm --needed "${stage2[@]}"

  # Legacy BIOS: stage 1 into partition 1 (NOMAD_BIOS), stage 2 file on the ESP.
  arch-chroot "$T" limine bios-install "/dev/$disk" 1
  install -m644 "$T/usr/share/limine/limine-bios.sys" "$T/boot/limine-bios.sys"
else
  info "Upgrading the backup OS (${#pkgs[@]} + ${#stage2[@]} packages wanted)"
  arch-chroot "$T" pacman -Syu --noconfirm --needed "${pkgs[@]}" "${stage2[@]}"
  # Re-apply /etc/default/limine (BOOT_ORDER) to limine.conf even when no kernel changed.
  arch-chroot "$T" limine-update || warn "limine-update failed; check /boot/limine.conf"
fi
echo "$host_name" > "$T/etc/hostname"

info "Users and services"
# The login shell follows this host's user when the target has it (zsh with cachyos-zsh-config on
# a CachyOS primary), bash otherwise. $src_home is where the dotfiles come from.
src_home=$(getent passwd "$user" | cut -d: -f6 || true)
shell=$(getent passwd "$user" | cut -d: -f7 || true)
[[ -n $shell && -x $T$shell ]] || shell=/bin/bash
if [[ $refresh == no ]]; then
  arch-chroot "$T" useradd -m -G wheel -s "$shell" "$user"
  echo '%wheel ALL=(ALL:ALL) ALL' > "$T/etc/sudoers.d/10-wheel"
  chmod 440 "$T/etc/sudoers.d/10-wheel"
  echo "Set a password for '$user' on the backup OS:"
  arch-chroot "$T" passwd "$user"
  arch-chroot "$T" passwd -l root >/dev/null
else
  arch-chroot "$T" id "$user" >/dev/null 2>&1 || die "User '$user' does not exist on the backup OS; build it first"
  arch-chroot "$T" usermod -s "$shell" "$user"
fi
# Skel files from packages installed after the user was created (a refresh); never overwrites.
cp -rn "$T/etc/skel/." "$T/home/$user/"

# Same SSH keys as this host's user, so the backup OS is reachable without a console.
if [[ -n $src_home && -s $src_home/.ssh/authorized_keys ]]; then
  install -d -m700 "$T/home/$user/.ssh"
  install -m600 "$src_home/.ssh/authorized_keys" "$T/home/$user/.ssh/authorized_keys"
  info "Copied $src_home/.ssh/authorized_keys for '$user'"
fi

if [[ $refresh == no ]]; then
  # ufw programs live chains only when ufw.conf says ENABLED=yes. With the package default (no) the
  # rule is just written to user.rules, which is what we want: inside the chroot, "live" would mean
  # THIS host's firewall. So add rules first, then enable. (A refresh keeps the existing rules.)
  grep -q '^ENABLED=no' "$T/etc/ufw/ufw.conf" || die "$T/etc/ufw/ufw.conf is not ENABLED=no; refusing to run ufw in the chroot"
  arch-chroot "$T" ufw allow 22/tcp comment 'sshd' >/dev/null
  sed -i 's/^ENABLED=no/ENABLED=yes/' "$T/etc/ufw/ufw.conf"
fi
arch-chroot "$T" systemctl enable NetworkManager.service ufw.service sshd.service systemd-timesyncd.service fstrim.timer
# Network like the primary: cachyos-settings sets NetworkManager to dns=systemd-resolved (no DNS
# without it); avahi publishes <hostname>.local, so `ssh nomad-rescue.local` works.
arch-chroot "$T" systemctl enable systemd-resolved.service avahi-daemon.service

desktop_setup() {
  # greetd runs the Noctalia greeter, as the installer sets it up on the primary. The package's
  # install hook runs the same setup script (PAM patch, greeter paths, greeter.toml), but inside a
  # pacstrap/chroot it runs before sysusers has created 'greeter' and skips half of it; run it
  # again now that the user exists.
  printf '[terminal]\nvt = 1\n\n[default_session]\ncommand = "/usr/bin/noctalia-greeter-session"\nuser = "greeter"\n' > "$T/etc/greetd/config.toml"
  echo /usr/bin/Hyprland > "$T/etc/greetd/environments"
  arch-chroot "$T" env NOCTALIA_GREETER_SESSION_BIN=/usr/bin/noctalia-greeter-session \
    bash /usr/share/noctalia-greeter/setup_greeter_system.sh || warn "noctalia-greeter system setup failed; check /etc/pam.d/greetd and /var/lib/noctalia-greeter"
  # Create/unlock the GNOME keyring with the login password at the greeter. greetd's PAM stack
  # lacks this (SDDM's has it), so the first secret request would pop "Choose password for new
  # keyring". auth after the password is known, session before pam_systemd, as in pam.d/login.
  grep -q pam_gnome_keyring "$T/etc/pam.d/greetd" || sed -i \
    -e '/^auth[[:space:]]\+include[[:space:]]\+system-local-login/a auth       optional     pam_gnome_keyring.so' \
    -e '/^session[[:space:]]\+include[[:space:]]\+system-local-login/a session    optional     pam_gnome_keyring.so auto_start' \
    "$T/etc/pam.d/greetd"
  arch-chroot "$T" systemctl disable sddm.service 2>/dev/null || true   # builds before the Hyprland edition
  arch-chroot "$T" systemctl enable greetd.service bluetooth.service

  # The look lives in the user's dotfiles (seeded from skel by the installer, then edited). Copy
  # the desktop-related ones from this host; tools under ~/.local/bin, caches and *.backup-* stay.
  if [[ -n $src_home && -d $src_home/.config ]]; then
    local p n=0
    for p in .zshrc .p10k.zsh .icons .local/share/icons .local/share/wallpapers .local/state/noctalia \
      .config/hypr .config/noctalia .config/kitty .config/alacritty .config/fish .config/gtk-3.0 \
      .config/gtk-4.0 .config/qt5ct .config/qt6ct .config/kdeglobals .config/dolphinrc \
      .config/mimeapps.list .config/uwsm .config/swash .config/xsettingsd .config/menus \
      .config/btop .config/micro .config/glow .config/user-dirs.dirs .config/user-dirs.locale; do
      [[ -e $src_home/$p ]] || continue
      mkdir -p "$T/home/$user/$(dirname "$p")"
      rsync -a --exclude='*.backup-*' --exclude='*.bak-*' --exclude=clipboard \
        --exclude=notification_history.json --exclude=recently_used.json --exclude=usage_counts.json \
        "$src_home/$p" "$T/home/$user/$(dirname "$p")/"
      n=$((n + 1))
    done
    info "Copied $n desktop config paths from $src_home"
  else
    warn "No $src_home/.config on this host; the backup OS keeps the packaged desktop defaults"
  fi

  # Fonts from AUR/foreign packages on this host are not in the repos (kitty here wants JuliaMono
  # Nerd Font); carry the files under /usr/local, outside pacman's tree.
  local pkg files
  for pkg in $(pacman -Qmq 2>/dev/null); do
    files=$(pacman -Qlq "$pkg" | grep -E '\.(ttf|otf)$' || true)
    [[ -n $files ]] || continue
    install -d "$T/usr/local/share/fonts/$pkg"
    while IFS= read -r f; do install -m644 "$f" "$T/usr/local/share/fonts/$pkg/"; done <<<"$files"
    info "Copied fonts of foreign package $pkg"
  done
  arch-chroot "$T" fc-cache -f >/dev/null 2>&1 || true

  # Tell the two systems apart at a glance: a different Noctalia palette, which its templates
  # carry into kitty, alacritty, GTK, Qt and btop. Both files hold the scheme (the GUI writes the
  # state one, config.toml wins on reload), so patch both.
  local f
  for f in "$T/home/$user/.config/noctalia/config.toml" "$T/home/$user/.local/state/noctalia/settings.toml"; do
    [[ -f $f ]] || continue
    sed -i -E "s/^(\s*source\s*=\s*)\"[^\"]*\"/\1\"builtin\"/; s/^(\s*builtin\s*=\s*)\"[^\"]*\"/\1\"$theme\"/" "$f"
  done
}
# An `if`, not `[[ ]] &&`: bash ignores errexit inside a function called from an && list.
if [[ $desktop == yes ]]; then desktop_setup; fi
arch-chroot "$T" chown -R "$user:$user" "/home/$user"

# Console and SSH logins say which system this is.
printf '\n  NOMAD RESCUE OS (%s): the backup system on the NOMAD drive, not the primary install.\n  /mnt/nomad is the shared, live datastore.\n\n' "$host_name" > "$T/etc/motd"

info "NOMAD host bootstrap inside the backup OS"
rm -rf "$T/opt/nomad-toolkit"
cp -a "$here" "$T/opt/nomad-toolkit"
arch-chroot "$T" bash /opt/nomad-toolkit/bootstrap-host.sh --chroot --autostart --expose=lan --gpu="$gpu" --yes

# Last, after every arch-chroot that needs DNS: the resolved stub, like the primary.
ln -sf ../run/systemd/resolve/stub-resolv.conf "$T/etc/resolv.conf"

info "Verifying"
fail=0
[[ -f $T/boot/EFI/BOOT/BOOTX64.EFI ]] || { warn "EFI/BOOT/BOOTX64.EFI missing on the ESP"; fail=1; }
[[ -f $T/boot/limine-bios.sys ]] || { warn "limine-bios.sys missing on the ESP"; fail=1; }
grep -q "$root_uuid" "$T/boot/limine.conf" 2>/dev/null || { warn "limine.conf has no entry for root UUID $root_uuid"; fail=1; }
find "$T/boot" -name 'initramfs*' | grep -q . || { warn "No initramfs found on the ESP"; fail=1; }
grep -q -- '--dport 22 ' "$T/etc/ufw/user.rules" || { warn "ufw has no rule for port 22; sshd would be unreachable"; fail=1; }
if [[ $desktop == yes ]]; then
  [[ $(readlink "$T/etc/systemd/system/display-manager.service" 2>/dev/null) == *greetd.service ]] || { warn "greetd is not the display manager"; fail=1; }
  [[ -f $T/home/$user/.config/noctalia/config.toml ]] || { warn "No Noctalia config for '$user'"; fail=1; }
fi
nongeneric=$(arch-chroot "$T" pacman -Qi | awk '/^Name/{n=$3} /^Architecture/{if($3!="x86_64"&&$3!="any")print n,$3}')
[[ -z $nongeneric ]] || { warn "Non-generic packages installed:"; echo "$nongeneric"; fail=1; }

sync
((fail == 0)) || die "Backup OS built with problems; see warnings above"
if [[ $refresh == no ]]; then
  info "Backup OS ready on /dev/$disk. Test: reboot, open the firmware boot menu, pick the Lexar/'UEFI OS' entry."
else
  info "Backup OS refreshed on /dev/$disk."
fi
