#!/bin/bash
# Build an offline pacman repository on the datastore holding everything bootstrap-host.sh
# installs, with full dependency closure, as generic x86_64 packages (installable on every
# CachyOS flavour and on Arch). Run while online; re-run occasionally to keep it fresh.
#
#   sudo bash build-pkgcache.sh [--gpu=vulkan,rocm,cuda]
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"
need_root "$@"

gpu=vulkan
for arg in "$@"; do
  case $arg in
    --gpu=*) gpu=${arg#*=} ;;
    *) die "Unknown option: $arg" ;;
  esac
done

mountpoint -q "$NOMAD_MNT" || die "$NOMAD_MNT is not mounted"
cache=$NOMAD_PKGCACHE/generic
# pacman downloads as the unprivileged 'alpm' user on hosts with DownloadUser set.
install -d -m755 "$NOMAD_PKGCACHE" "$cache"

pkgs=(docker docker-compose ollama zstd curl archlinux-keyring cachyos-keyring)
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/pacman.conf" <<EOF
[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
ParallelDownloads = 10
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
EOF

# A blank local database makes pacman treat nothing as installed, so every dependency is
# downloaded, not only the ones this host happens to lack.
install -d "$work/db/local"
pacman --config "$work/pacman.conf" --dbpath "$work/db" --cachedir "$cache" \
  -Syw --noconfirm "${pkgs[@]}"

rm -f "$cache"/nomad-offline.db* "$cache"/nomad-offline.files*
repo-add -q "$cache/nomad-offline.db.tar.zst" "$cache"/*.pkg.tar.zst

cat > "$NOMAD_PKGCACHE/offline.conf" <<EOF
# Used by: bootstrap-host.sh --offline
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
[nomad-offline]
# Detached .sig files downloaded next to the packages are verified when present. The drive is
# already fully trusted: bootstrap-host.sh runs from it as root.
SigLevel = PackageOptional DatabaseNever
Server = file://$cache
EOF

glibc=$(find "$cache" -name 'glibc-[0-9]*.pkg.tar.zst' -printf '%f\n' | sort -V | tail -n1)
glibc=${glibc#glibc-}; glibc=${glibc%-x86_64.pkg.tar.zst}
echo "$glibc" > "$NOMAD_PKGCACHE/GLIBC_VERSION"
date -u +%Y-%m-%d > "$NOMAD_PKGCACHE/BUILD_DATE"

info "Offline repo: $cache ($(du -sh "$cache" | cut -f1)), glibc $glibc, gpu: $gpu"
