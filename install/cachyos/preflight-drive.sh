#!/bin/bash
# Read-only. Locate the NOMAD target disk and print its stable /dev/disk/by-id path.
# Refuses unless exactly one disk matches and nothing on it is in use.
#
#   preflight-drive.sh [--model REGEX] [--allow-usb] [--min-bytes N] [--max-bytes N]
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib/common.sh"

model_re='Lexar'
allow_usb=no
min_bytes=3900000000000
max_bytes=4100000000000
while (($#)); do
  case $1 in
    --model) model_re=$2; shift 2 ;;
    --allow-usb) allow_usb=yes; shift ;;
    --min-bytes) min_bytes=$2; shift 2 ;;
    --max-bytes) max_bytes=$2; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

system_disks=$(for mp in / /home /boot /boot/efi; do disks_backing "$mp"; done | sort -u)

candidates=()
while read -r name type; do
  [[ $type == disk ]] || continue
  size=$(lsblk -dnbo SIZE "/dev/$name")
  tran=$(lsblk -dno TRAN "/dev/$name")
  model=$(lsblk -dno MODEL "/dev/$name")
  ((size >= min_bytes && size <= max_bytes)) || continue
  case $tran in
    nvme) ;;
    usb) [[ $allow_usb == yes ]] || continue ;;
    *) continue ;;
  esac
  # In an enclosure the model string belongs to the USB bridge, so only size is matched there.
  [[ $tran == usb ]] || [[ $model =~ $model_re ]] || continue
  candidates+=("$name")
done < <(lsblk -dno NAME,TYPE)

((${#candidates[@]} == 1)) || {
  lsblk -do NAME,SIZE,TRAN,MODEL,SERIAL
  die "Expected exactly one matching disk, found ${#candidates[@]}: ${candidates[*]:-none}"
}
disk=${candidates[0]}

for d in $system_disks; do
  [[ $d == "$disk" ]] && die "/dev/$disk backs the running system; refusing"
done
if lsblk -nro MOUNTPOINTS "/dev/$disk" | grep -q .; then
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "/dev/$disk"
  die "Partitions of /dev/$disk are mounted; unmount them first"
fi

byid=
for link in /dev/disk/by-id/*; do
  [[ $(readlink -f "$link") == "/dev/$disk" ]] || continue
  case ${link##*/} in
    nvme-eui.*|nvme-nvme.*|wwn-*|*_1) continue ;;
  esac
  byid=$link
  break
done
[[ -n $byid ]] || die "No /dev/disk/by-id link found for /dev/$disk"

info "Target disk"
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,FSTYPE,LABEL,PARTLABEL "/dev/$disk"
if lsblk -nro FSTYPE "/dev/$disk" | grep -q .; then
  warn "This disk already holds filesystems. Partitioning destroys them."
fi
echo
echo "DISK=$byid"
echo "SERIAL=$(lsblk -dno SERIAL "/dev/$disk")"
