#!/bin/bash
# Shared constants and helpers for the CachyOS NOMAD toolkit.
# Installed to /usr/local/lib/nomad/ so lifecycle scripts never depend on the data drive.

NOMAD_MNT=/mnt/nomad
NOMAD_DIR="$NOMAD_MNT/project-nomad"
NOMAD_COMPOSE="$NOMAD_DIR/compose.yml"
NOMAD_HB="$NOMAD_MNT/host-bootstrap"
NOMAD_MANIFEST="$NOMAD_HB/installed-services.txt"
NOMAD_IMAGES_DIR="$NOMAD_HB/docker-images"
NOMAD_IMAGES_ARCHIVE="$NOMAD_IMAGES_DIR/nomad-images.tar.zst"
NOMAD_PKGCACHE="$NOMAD_HB/pkgcache"
NOMAD_HOST_STATE=/var/lib/nomad-host
NOMAD_HOST_CONF=/etc/nomad-host.conf
NOMAD_RUN=/run/nomad-host
NOMAD_LIB=/usr/local/lib/nomad
NOMAD_BRIDGE=br-nomad
NOMAD_PROJECT=project-nomad
NOMAD_ADMIN_URL=http://localhost:8080
NOMAD_DATA_PARTLABEL=NOMAD_DATA
OLLAMA_ID=614

# Containers owned by compose.yml. Everything else named nomad_* is an app the admin created.
NOMAD_MGMT_CONTAINERS="nomad_admin nomad_dozzle nomad_mysql nomad_redis nomad_updater nomad_disk_collector"

info() { printf '\033[1;32m#\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m# WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m# ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"; }

is_mgmt_container() {
  local c
  for c in $NOMAD_MGMT_CONTAINERS; do [[ $c == "$1" ]] && return 0; done
  return 1
}

# Names of app containers (non-management) that exist on this host, any state.
list_app_containers() {
  local c
  docker ps -a --filter 'name=^nomad_' --format '{{.Names}}' | while read -r c; do
    is_mgmt_container "$c" || echo "$c"
  done
}

# Whole-disk kernel name (e.g. nvme1n1) backing a partition or by-* symlink.
disk_of() { lsblk -no PKNAME "$(readlink -f "$1")" | head -n1; }

# Whole-disk kernel names backing a mountpoint, following LUKS/LVM/btrfs layers.
disks_backing() {
  local src
  src=$(findmnt -no SOURCE "$1" 2>/dev/null) || return 0
  src=${src%%\[*}
  [[ -b $src ]] || return 0
  lsblk -nso NAME,TYPE "$src" | awk '$2=="disk"{gsub(/[^[:alnum:]]/,"",$1); print $1}'
}
