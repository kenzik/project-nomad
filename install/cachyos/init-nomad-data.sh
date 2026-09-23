#!/bin/bash
# One-time initialisation of the NOMAD datastore. Generates compose.yml (with secrets) from the
# fork's install/management_compose.yaml and creates the directory layout on NOMAD_DATA.
# Refuses to run against an initialised datastore: regenerating secrets over an existing MySQL
# data dir locks the admin out, and upstream's fix for that is `rm -rf mysql`.
#
#   sudo bash init-nomad-data.sh [--tag vX.Y.Z]
#   bash init-nomad-data.sh --dry-run --root DIR    # generate into DIR, no docker/mount checks
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/lib/common.sh"

dry=no root= tag=
while (($#)); do
  case $1 in
    --dry-run) dry=yes; shift ;;
    --root) root=$2; shift 2 ;;
    --tag) tag=$2; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

template=$repo/install/management_compose.yaml
[[ -f $template ]] || die "Compose template not found: $template"

if [[ $dry == yes ]]; then
  [[ -n $root ]] || die "--dry-run requires --root DIR"
  out_mnt=$root
else
  need_root "$@"
  mountpoint -q "$NOMAD_MNT" || die "$NOMAD_MNT is not mounted. Run bootstrap-host.sh first."
  out_mnt=$NOMAD_MNT
fi
out_dir=$out_mnt/project-nomad
out_hb=$out_mnt/host-bootstrap
compose=$out_dir/compose.yml

[[ ! -e $compose ]] || die "$compose already exists; the datastore is initialised."
[[ -z $(ls -A "$out_dir/mysql" 2>/dev/null) ]] || die "$out_dir/mysql holds data; refusing to generate new DB credentials over it."

if [[ -z $tag ]]; then
  ver=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$repo/package.json" | head -n1)
  [[ -n $ver ]] && tag=v$ver
fi
image=ghcr.io/crosstalk-solutions/project-nomad
if [[ $dry == no && -n $tag ]] && ! docker manifest inspect "$image:$tag" >/dev/null 2>&1; then
  warn "$image:$tag not found on the registry; leaving the admin image on :latest"
  tag=
fi

rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }
app_key=$(rand) db_root=$(rand) db_user=$(rand)

install -d "$out_dir/storage/logs" "$out_dir/mysql" "$out_dir/redis" \
  "$out_mnt/ollama/models" "$out_hb/toolkit" "$out_hb/pkgcache" "$out_hb/docker-images"
touch "$out_dir/storage/logs/admin.log"

# The host paths written into compose.yml are always the real mount path, even in a dry run.
umask 077
sed \
  -e "s|URL=replaceme|URL=$NOMAD_ADMIN_URL|" \
  -e "s|APP_KEY=replaceme|APP_KEY=$app_key|" \
  -e "s|DB_PASSWORD=replaceme|DB_PASSWORD=$db_user|" \
  -e "s|MYSQL_ROOT_PASSWORD=replaceme|MYSQL_ROOT_PASSWORD=$db_root|" \
  -e "s|MYSQL_PASSWORD=replaceme|MYSQL_PASSWORD=$db_user|" \
  -e "s|^\([[:space:]]*- \)/opt/project-nomad/storage:|\1$NOMAD_DIR/storage:|" \
  -e "s|NOMAD_STORAGE_PATH=/opt/project-nomad/storage|NOMAD_STORAGE_PATH=$NOMAD_DIR/storage|" \
  -e "s|^\([[:space:]]*- \)/opt/project-nomad/mysql:|\1$NOMAD_DIR/mysql:|" \
  -e "s|^\([[:space:]]*- \)/opt/project-nomad/redis:|\1$NOMAD_DIR/redis:|" \
  -e "s|^\([[:space:]]*- \)/opt/project-nomad:/opt/project-nomad|\1$NOMAD_DIR:/opt/project-nomad|" \
  -e "s|pull_policy: always|pull_policy: missing|" \
  ${tag:+-e "s|\(image: $image\):latest|\1:$tag|"} \
  "$template" > "$compose.new"

cat >> "$compose.new" <<EOF

# Fixed bridge name so host firewall rules can reference the interface (install/cachyos).
networks:
  default:
    driver_opts:
      com.docker.network.bridge.name: $NOMAD_BRIDGE
EOF
chmod 600 "$compose.new"
umask 022

# compose.yml only appears once it is known good, so a failed run can simply be repeated.
reject() { rm -f "$compose.new"; die "$1"; }
grep -q '=replaceme' "$compose.new" && reject "An unsubstituted '=replaceme' value remains"
grep -qE '^[[:space:]]*- /opt/project-nomad' "$compose.new" && reject "A host bind under /opt/project-nomad remains"
[[ $(grep -c "$NOMAD_DIR/storage" "$compose.new") -eq 3 ]] || reject "Expected exactly 3 storage path rewrites"
grep -q 'pull_policy: always' "$compose.new" && reject "pull_policy: always remains"
if [[ $dry == no ]]; then
  docker compose -p "$NOMAD_PROJECT" -f "$compose.new" config -q || reject "docker compose rejected the generated file"
fi
mv "$compose.new" "$compose"

# The drive carries its own copy of the toolkit so any host can be bootstrapped from it.
cp -a "$here/." "$out_hb/toolkit/"
install -Dm644 "$template" "$out_hb/toolkit/management_compose.yaml.orig"
(cd "$out_hb/toolkit" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

if [[ $dry == no ]]; then
  chown "$OLLAMA_ID:$OLLAMA_ID" "$out_mnt/ollama" "$out_mnt/ollama/models"
  info "Datastore initialised. Admin image tag: ${tag:-latest}"
  info "Next: sudo nomad-up, then open $NOMAD_ADMIN_URL"
  info "First thing in the UI: Settings > Models > Remote Ollama URL = http://host.docker.internal:11434"
else
  info "Dry run written to $out_mnt (admin image tag: ${tag:-latest})"
fi
