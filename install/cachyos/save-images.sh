#!/bin/bash
# Archive every NOMAD image on this host to the datastore so another host (or the backup OS)
# can `docker load` them with no internet. Re-run after every NOMAD or app update.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"
need_root "$@"

mountpoint -q "$NOMAD_MNT" || die "$NOMAD_MNT is not mounted"
[[ -f $NOMAD_COMPOSE ]] || die "$NOMAD_COMPOSE missing"
install -d "$NOMAD_IMAGES_DIR" "$NOMAD_HOST_STATE"

mapfile -t images < <(
  { docker compose -p "$NOMAD_PROJECT" -f "$NOMAD_COMPOSE" config --images
    docker ps -a --filter 'name=^nomad_' --format '{{.Image}}'; } | sort -u)
((${#images[@]})) || die "No NOMAD images found"

missing=()
for i in "${images[@]}"; do docker image inspect "$i" >/dev/null 2>&1 || missing+=("$i"); done
((${#missing[@]} == 0)) || die "Images not present locally: ${missing[*]}"

info "Saving ${#images[@]} images:"
printf '  %s\n' "${images[@]}"
docker save "${images[@]}" | zstd -T0 -3 -q -o "$NOMAD_IMAGES_ARCHIVE.partial" -f
mv -f "$NOMAD_IMAGES_ARCHIVE.partial" "$NOMAD_IMAGES_ARCHIVE"
printf '%s\n' "${images[@]}" > "$NOMAD_IMAGES_DIR/IMAGES.txt"

# A generation stamp rather than image IDs: IDs differ between Docker's classic and
# containerd image stores. This host made the archive, so it is already current.
gen=$(date -u +%Y%m%dT%H%M%SZ)
echo "$gen" > "$NOMAD_IMAGES_DIR/GENERATION"
echo "$gen" > "$NOMAD_HOST_STATE/images.generation"

list_app_containers | sort > "$NOMAD_MANIFEST.tmp" && mv -f "$NOMAD_MANIFEST.tmp" "$NOMAD_MANIFEST"

info "Archive: $NOMAD_IMAGES_ARCHIVE ($(du -h "$NOMAD_IMAGES_ARCHIVE" | cut -f1)), generation $gen"
