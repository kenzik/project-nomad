#!/bin/bash
# Make this CachyOS/Arch host able to run Project NOMAD from the NOMAD_DATA datastore.
# Idempotent. Host software comes from pacman; no NOMAD state is written to the host.
#
#   sudo bash bootstrap-host.sh [options]
#     --autostart        start NOMAD at boot (or on plug-in with --hotplug)
#     --hotplug          datastore is removable: fstab noauto, optional udev autostart
#     --expose=lan|local who can reach NOMAD's published ports (default: lan)
#     --gpu=LIST         comma list of vulkan,rocm,cuda,none (default: vulkan)
#     --offline          install packages from the drive's pkgcache instead of the network
#     --docker-subvols   btrfs root only: put /var/lib/{docker,containerd} on their own
#                        subvolumes so image layers stay out of snapper snapshots
#     --chroot           running inside arch-chroot (build-backup-os.sh): enable, never start
#     --yes              pass --noconfirm to pacman
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"

autostart=no hotplug=no expose=lan gpu=vulkan offline=no subvols=no chroot=no yes=no
for arg in "$@"; do
  case $arg in
    --autostart) autostart=yes ;;
    --hotplug) hotplug=yes ;;
    --expose=lan|--expose=local) expose=${arg#*=} ;;
    --gpu=*) gpu=${arg#*=} ;;
    --offline) offline=yes ;;
    --docker-subvols) subvols=yes ;;
    --chroot) chroot=yes ;;
    --yes) yes=yes ;;
    *) die "Unknown option: $arg" ;;
  esac
done
need_root "$@"

# Runtime systemctl/udev operations make no sense inside a chroot; enabling units does.
live() { [[ $chroot == yes ]] || "$@"; }

part=/dev/disk/by-partlabel/$NOMAD_DATA_PARTLABEL
[[ -b $part ]] || die "No partition with PARTLABEL=$NOMAD_DATA_PARTLABEL. Partition the drive first."
uuid=$(blkid -s UUID -o value "$part")
[[ -n $uuid ]] || die "$part has no filesystem. Run the mkfs step first."

pin_ollama_ids() {
  local owner
  owner=$(getent passwd "$OLLAMA_ID" | cut -d: -f1 || true)
  [[ -z $owner || $owner == ollama ]] || die "UID $OLLAMA_ID already belongs to '$owner'"
  owner=$(getent group "$OLLAMA_ID" | cut -d: -f1 || true)
  [[ -z $owner || $owner == ollama ]] || die "GID $OLLAMA_ID already belongs to group '$owner'"

  install -Dm644 "$here/units/sysusers-ollama.conf" /etc/sysusers.d/ollama.conf
  if id ollama &>/dev/null; then
    if [[ $(id -u ollama) != "$OLLAMA_ID" || $(id -g ollama) != "$OLLAMA_ID" ]]; then
      # Renumber the host's user. The drive's ownership is the fixed point; never chown it.
      info "Renumbering existing ollama user to $OLLAMA_ID:$OLLAMA_ID"
      live systemctl stop nomad-ollama.service ollama.service 2>/dev/null || true
      groupmod -g "$OLLAMA_ID" ollama
      usermod -u "$OLLAMA_ID" -g "$OLLAMA_ID" ollama
      [[ -d /var/lib/ollama ]] && chown -R ollama:ollama /var/lib/ollama
    fi
  elif ! systemd-sysusers /etc/sysusers.d/ollama.conf 2>/dev/null; then
    # "u!" (locked account) needs systemd >= 257.
    sed -i 's/^u! /u /' /etc/sysusers.d/ollama.conf
    systemd-sysusers /etc/sysusers.d/ollama.conf
  fi
  [[ $(id -u ollama) == "$OLLAMA_ID" ]] || die "ollama user is not UID $OLLAMA_ID"
}

setup_mount() {
  # Immutable empty mountpoint: if the datastore is absent, Docker cannot create bind-mount
  # directories (and a fresh empty MySQL) on the OS disk.
  if mountpoint -q "$NOMAD_MNT"; then
    local view=/run/nomad-rootview
    mkdir -p "$view"
    mount --bind / "$view"
    mkdir -p "$view$NOMAD_MNT"
    chattr +i "$view$NOMAD_MNT" || warn "Could not set the immutable flag on $NOMAD_MNT"
    umount "$view"
  else
    mkdir -p "$NOMAD_MNT"
    chattr +i "$NOMAD_MNT" || warn "Could not set the immutable flag on $NOMAD_MNT"
  fi

  local opts=noatime,nofail,nodev,nosuid,x-systemd.device-timeout=10s
  [[ $hotplug == yes ]] && opts=noauto,$opts
  local line="UUID=$uuid $NOMAD_MNT ext4 $opts 0 2"
  if grep -qE "^[^#]*[[:space:]]$NOMAD_MNT[[:space:]]" /etc/fstab; then
    grep -qE "^UUID=$uuid[[:space:]]+$NOMAD_MNT[[:space:]]" /etc/fstab ||
      die "/etc/fstab already has a different entry for $NOMAD_MNT. Expected: $line"
  else
    printf '\n# Project NOMAD datastore\n%s\n' "$line" >> /etc/fstab
    info "Added to /etc/fstab: $line"
  fi
  live systemctl daemon-reload
  if [[ $chroot == no ]] && ! mountpoint -q "$NOMAD_MNT"; then
    systemctl start mnt-nomad.mount
  fi
}

setup_docker_subvols() {
  [[ $(findmnt -no FSTYPE /) == btrfs ]] || { warn "Root is not btrfs; skipping --docker-subvols"; return; }
  local d
  for d in /var/lib/docker /var/lib/containerd; do
    if [[ -d $d && -n $(ls -A "$d") ]]; then warn "$d is not empty; skipping --docker-subvols"; return; fi
  done
  local src ruuid top sv
  src=$(findmnt -no SOURCE /); src=${src%%\[*}
  ruuid=$(findmnt -no UUID /)
  top=$(mktemp -d)
  mount -o subvolid=5 "$src" "$top"
  for sv in @docker @containerd; do
    [[ -d $top/$sv ]] || btrfs subvolume create "$top/$sv"
  done
  umount "$top"; rmdir "$top"
  for sv in docker containerd; do
    mkdir -p "/var/lib/$sv"
    grep -qE "[[:space:]]/var/lib/$sv[[:space:]]" /etc/fstab ||
      echo "UUID=$ruuid /var/lib/$sv btrfs subvol=/@$sv,noatime,compress=zstd:1 0 0" >> /etc/fstab
  done
  live systemctl daemon-reload
  live mount /var/lib/docker
  live mount /var/lib/containerd
}

install_packages() {
  local pkgs=(docker docker-compose ollama zstd curl) g
  IFS=, read -ra gpus <<<"$gpu"
  for g in "${gpus[@]}"; do
    case $g in
      vulkan) pkgs+=(ollama-vulkan) ;;
      rocm)   pkgs+=(ollama-rocm) ;;
      cuda)   pkgs+=(ollama-cuda) ;;
      none)   ;;
      *) die "Unknown --gpu value: $g" ;;
    esac
  done
  local args=(--needed)
  [[ $yes == yes ]] && args+=(--noconfirm)

  if [[ $offline == yes ]]; then
    local conf=$NOMAD_PKGCACHE/offline.conf
    [[ -f $conf ]] || die "$conf not found. Build it with build-pkgcache.sh while online."
    # Installing packages built against a newer glibc than the host's is a partial upgrade.
    local cache_glibc host_glibc
    cache_glibc=$(cat "$NOMAD_PKGCACHE/GLIBC_VERSION")
    host_glibc=$(pacman -Q glibc | awk '{print $2}')
    (( $(vercmp "$host_glibc" "$cache_glibc") >= 0 )) ||
      die "Host glibc $host_glibc is older than the cache's $cache_glibc. Update this host first."
    pacman --config "$conf" -Sy "${args[@]}" "${pkgs[@]}"
  else
    pacman -S "${args[@]}" "${pkgs[@]}"
  fi
}

install_files() {
  install -d /usr/local/lib/nomad "$NOMAD_HOST_STATE"
  install -m644 "$here/lib/common.sh" /usr/local/lib/nomad/
  install -m755 "$here"/lib/nomad-* /usr/local/lib/nomad/
  install -m755 "$here/nomad-up" "$here/nomad-down" "$here/nomad-expose" /usr/local/bin/
  install -m644 "$here"/units/*.service /etc/systemd/system/

  local rules=/etc/udev/rules.d/99-nomad-autostart.rules
  if [[ $hotplug == yes && $autostart == yes ]]; then
    sed "s/@DATA_UUID@/$uuid/" "$here/units/99-nomad-autostart.rules" > "$rules"
  else
    rm -f "$rules"
  fi
  live udevadm control --reload

  # Convenience only; compose.yml binds real /mnt/nomad paths.
  if [[ -e /opt/project-nomad && ! -L /opt/project-nomad ]]; then
    warn "/opt/project-nomad exists and is not a symlink; leaving it alone"
  else
    ln -sfn "$NOMAD_DIR" /opt/project-nomad
  fi
}

setup_firewall() {
  # ufw governs native Ollama (a host process). It does NOT govern Docker-published ports;
  # nomad-expose-local.service handles those.
  local rule=(allow in on "$NOMAD_BRIDGE" to any port 11434 proto tcp comment 'NOMAD containers -> native Ollama')
  if ! command -v ufw >/dev/null; then
    warn "No ufw found. Ollama (port 11434, unauthenticated) will be reachable from the LAN."
  elif [[ $chroot == yes ]]; then
    touch "$NOMAD_HOST_STATE/pending-ufw"   # applied by nomad-preflight on first start
  elif ufw status | grep -q '^Status: active'; then
    ufw "${rule[@]}"
  else
    warn "ufw is installed but inactive. Ollama (port 11434, unauthenticated) is reachable from the LAN."
    warn "Enable it with: sudo ufw enable   then re-run this script."
  fi
}

enable_units() {
  systemctl disable ollama.service 2>/dev/null || true
  live systemctl stop ollama.service 2>/dev/null || true

  if [[ $autostart == yes ]]; then
    systemctl enable docker.service
  else
    systemctl enable docker.socket
  fi
  if [[ $autostart == yes && $hotplug == no ]]; then
    systemctl enable nomad-ollama.service project-nomad.service
  else
    systemctl disable nomad-ollama.service project-nomad.service 2>/dev/null || true
  fi
  if [[ $expose == local ]]; then
    systemctl enable nomad-expose-local.service
  else
    systemctl disable nomad-expose-local.service 2>/dev/null || true
  fi

  cat > "$NOMAD_HOST_CONF" <<EOF
# Written by bootstrap-host.sh
DATA_UUID=$uuid
AUTOSTART=$autostart
HOTPLUG=$hotplug
EXPOSE=$expose
GPU=$gpu
EOF

  live systemctl daemon-reload
  live systemctl start docker.service
  if [[ $expose == local ]]; then
    live systemctl start nomad-expose-local.service
  else
    live systemctl stop nomad-expose-local.service 2>/dev/null || true
  fi
}

info "Datastore: $part (UUID $uuid)"
pin_ollama_ids
setup_mount
[[ $subvols == yes ]] && setup_docker_subvols
install_packages
install_files
setup_firewall
enable_units

echo
info "Host bootstrap complete."
if [[ $chroot == yes ]]; then
  info "Units are enabled; NOMAD starts on first boot of this OS."
elif [[ -f $NOMAD_COMPOSE ]]; then
  info "Datastore already initialised. Start NOMAD with: sudo nomad-up"
else
  info "Next: sudo bash $here/init-nomad-data.sh"
fi
