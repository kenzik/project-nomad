#!/bin/bash
# Prints the partitioning commands for the disk found by preflight-drive.sh.
# Executes nothing destructive; you run the printed block yourself.
#
#   print-partition-commands.sh [preflight-drive.sh options]
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

out=$("$here/preflight-drive.sh" "$@") || { echo "$out"; exit 1; }
echo "$out"
disk=$(sed -n 's/^DISK=//p' <<<"$out")
[[ -n $disk ]] || exit 1

cat <<EOF

# ---- Run these yourself. Everything on $disk is destroyed. ----
DISK=$disk
sudo sgdisk --zap-all "\$DISK"
sudo sgdisk -n1:1M:+1M   -t1:EF02 -c1:NOMAD_BIOS \\
            -n2:0:+4G    -t2:EF00 -c2:NOMAD_ESP \\
            -n3:0:+330G  -t3:8304 -c3:NOMAD_ROOT \\
            -n4:0:0      -t4:8300 -c4:NOMAD_DATA "\$DISK"
sudo partprobe "\$DISK"; sudo udevadm settle
sudo mkfs.fat -F 32 -n NOMAD_ESP /dev/disk/by-partlabel/NOMAD_ESP
sudo mkfs.ext4 -L NOMAD_DATA -m 0 -i 65536 /dev/disk/by-partlabel/NOMAD_DATA
# ---- Verify ----
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "\$DISK"
EOF
