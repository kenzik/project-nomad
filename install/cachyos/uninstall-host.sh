#!/bin/bash
# Remove the NOMAD host-side setup from this machine. Never touches the datastore.
# Packages, Docker images and containers are left alone unless --purge-containers is given.
#
#   sudo bash uninstall-host.sh [--purge-containers]
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"
need_root "$@"

purge=no
[[ ${1:-} == --purge-containers ]] && purge=yes

systemctl stop project-nomad.service nomad-ollama.service 2>/dev/null
systemctl disable --now nomad-expose-local.service 2>/dev/null
systemctl disable project-nomad.service nomad-ollama.service 2>/dev/null

if [[ $purge == yes ]]; then
  mapfile -t cs < <(docker ps -aq --filter 'name=^nomad_')
  ((${#cs[@]})) && docker rm -f "${cs[@]}"
  docker network rm "${NOMAD_PROJECT}_default" 2>/dev/null
  docker volume rm "${NOMAD_PROJECT}_nomad-update-shared" 2>/dev/null
fi

mountpoint -q "$NOMAD_MNT" && systemctl stop mnt-nomad.mount

rm -f /etc/systemd/system/{project-nomad,nomad-ollama,nomad-expose-local}.service \
      /etc/udev/rules.d/99-nomad-autostart.rules /etc/sysusers.d/ollama.conf \
      /usr/local/bin/{nomad-up,nomad-down,nomad-expose,nomad-downloads,nomad-kb} "$NOMAD_HOST_CONF" \
      /etc/NetworkManager/conf.d/50-nomad-unmanaged.conf
rm -rf /usr/local/lib/nomad "$NOMAD_HOST_STATE"
[[ -L /opt/project-nomad ]] && rm -f /opt/project-nomad

sed -i "\|[[:space:]]$NOMAD_MNT[[:space:]]|d; /^# Project NOMAD datastore$/d" /etc/fstab
if ! mountpoint -q "$NOMAD_MNT" && [[ -d $NOMAD_MNT ]]; then
  chattr -i "$NOMAD_MNT" 2>/dev/null
  rmdir "$NOMAD_MNT" 2>/dev/null
fi
command -v ufw >/dev/null && ufw delete allow in on "$NOMAD_BRIDGE" to any port 11434 proto tcp >/dev/null 2>&1

systemctl daemon-reload
udevadm control --reload
systemctl try-reload-or-restart NetworkManager.service 2>/dev/null
info "Host-side NOMAD setup removed. The datastore was not modified."
