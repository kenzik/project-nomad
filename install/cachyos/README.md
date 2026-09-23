# Project N.O.M.A.D. on CachyOS with a removable-ready datastore

Host software comes from pacman. All NOMAD state (content, databases, secrets, LLM models) lives on
one drive that also carries a generic backup CachyOS, so the drive can be moved to a USB enclosure
and booted on another PC. Design and rationale: `docs/plans/PLAN-kenzik-project-nomad-init.md`.

Not supported upstream: NOMAD officially targets Debian-based systems. Do not file upstream issues
for problems with this setup.

**Status: authored on a machine without the target hardware. Verified there: `bash -n` on every script,
the compose-generation dry run, and the drive-preflight guards (no match, mounted disk, system disk).
Nothing that needs root, Docker or the drive has been executed yet. Treat the first run on the X1 Pro
as the test run, especially `build-backup-os.sh`.**

## Drive layout

| # | PARTLABEL | Size | Purpose |
|---|---|---|---|
| 1 | `NOMAD_BIOS` | 1 MiB | Limine legacy-BIOS stage |
| 2 | `NOMAD_ESP` | 4 GiB FAT32 | ESP for the backup OS (kernels + initramfs live here) |
| 3 | `NOMAD_ROOT` | 330 GiB ext4 | Generic x86-64 backup CachyOS |
| 4 | `NOMAD_DATA` | rest, ext4 | Datastore, mounted at `/mnt/nomad` |

```
/mnt/nomad/project-nomad/   compose.yml (0600, secrets)  storage/  mysql/  redis/
/mnt/nomad/ollama/models/   owned 614:614
/mnt/nomad/host-bootstrap/  toolkit/  installed-services.txt  docker-images/  pkgcache/
```

## Runbook

Commands marked **[you run]** need root or destroy data.

### 1. Primary OS
Install CachyOS on the internal OS disk with the normal installer. Disable Secure Boot in firmware.

```
sudo pacman -S --needed git gptfdisk arch-install-scripts        # [you run]
git clone -b cachyos-portable https://github.com/kenzik/project-nomad.git
cd project-nomad/install/cachyos
```

### 2. Partition the datastore drive **[you run, destructive]**
```
bash print-partition-commands.sh          # read-only: finds the drive, prints the command block
```
It matches an NVMe disk of 3.9–4.1 TB whose model contains `Lexar`, and refuses if the disk is
mounted or backs the running system. Other drives: `--model REGEX`, `--min-bytes`, `--max-bytes`,
`--allow-usb`. Check the printed model and serial, then run the printed block. `NOMAD_ROOT` stays
unformatted until step 7.

### 3. Bootstrap the host **[you run]**
```
sudo bash bootstrap-host.sh --autostart --expose=lan --gpu=vulkan
```
| Flag | Effect |
|---|---|
| `--autostart` | NOMAD starts at boot (with `--hotplug`: when the drive is plugged in) |
| `--hotplug` | Drive is removable: `noauto` in fstab, UUID-matched udev rule |
| `--expose=lan\|local` | See "Exposure" below |
| `--gpu=vulkan,rocm,cuda,none` | Ollama GPU backends to install |
| `--offline` | Install from the drive's `pkgcache` (step 6) |
| `--docker-subvols` | btrfs root: keep Docker image layers out of snapper snapshots |

It pins the `ollama` user to UID/GID 614, mounts the datastore by UUID on an immutable mountpoint,
installs docker, docker-compose and ollama, installs the units and `nomad-*` commands, and adds the
ufw rule that lets containers reach native Ollama.

### 4. Initialise the datastore and start **[you run]**
```
sudo bash init-nomad-data.sh
sudo nomad-up
```
Open `http://localhost:8080` and, **before anything else**, set Settings → Models → Remote Ollama URL
to `http://host.docker.internal:11434`. Then run Easy Setup. Turn NOMAD auto-update off.

### 5. Content and models
Pick ZIM tiers, Wikipedia and maps in the UI. Khan Academy: open Kolibri (`:8310`) → Device → Channels
→ Import. Pull models in Settings → Models; they land in `/mnt/nomad/ollama/models`.

Optional, unverified on current kernels: for larger models on the Radeon iGPU, keep the BIOS UMA
frame buffer small and raise GTT with `ttm.pages_limit` / `ttm.page_pool_size` in `/etc/default/limine`.
Check the VRAM Ollama reports with `journalctl -u nomad-ollama`.

### 6. Offline assets **[you run]**
```
sudo bash save-images.sh                  # after every NOMAD or app update
sudo bash build-pkgcache.sh --gpu=vulkan  # while online
```

### 7. Backup OS **[you run, destructive to NOMAD_ESP and NOMAD_ROOT]**
```
sudo bash build-backup-os.sh --user <login>
```
Pacstraps a generic x86-64 CachyOS (Plasma, Firefox, Docker, Ollama with Vulkan/CUDA/ROCm) with an
initramfs built without `autodetect`, Limine on the removable EFI path plus legacy BIOS, and no firmware
boot entry. It asks for the last 4 characters of the disk serial before formatting. Flags:
`--hostname`, `--no-desktop`, `--no-nvidia`, `--no-rocm`.

`sshd` is enabled with port 22 open in ufw, and `<login>`'s `~/.ssh/authorized_keys` from this host
is copied over. The backup OS has its own host key and hostname (`nomad-rescue`), so if it takes the
same DHCP lease as the primary, use a separate `Host` alias with its own `UserKnownHostsFile`.

Test it: reboot, open the firmware boot menu, choose the datastore drive (or, from the primary,
`sudo efibootmgr --bootnext <the "UEFI OS" entry on NOMAD_ESP> && sudo reboot`). NOMAD should come
up with all content. Update it occasionally from inside (`sudo pacman -Syu`).

## Operating

| Command | |
|---|---|
| `sudo nomad-up` | Start (mounts the datastore if needed) |
| `sudo nomad-down [--unmount\|--eject]` | Clean stop; `--eject` powers off a USB enclosure |
| `sudo nomad-expose lan\|local` / `nomad-expose status` | Switch exposure |
| `systemctl status project-nomad nomad-ollama` | State |

Do not use `docker compose down` on the NOMAD project: app containers created by the admin share its
network. Do not run upstream's `install_nomad.sh` or `update_nomad.sh`; update from the NOMAD UI, then
re-run `save-images.sh`.

At boot, `project-nomad.service` starts NOMAD in the background; the login screen does not wait for
it. The admin is typically reachable a minute after boot (`journalctl -u project-nomad -f` to watch).

### Updating the toolkit
```
git pull
sudo bash bootstrap-host.sh <same flags as before>   # see /etc/nomad-host.conf
```
It reinstalls the units and scripts and refreshes the copy on the drive. The backup OS carries its
own copy; update it from there the same way (its checkout is `/opt/nomad-toolkit`, or use the drive's
`host-bootstrap/toolkit`).

### Exposure
NOMAD's admin API has no authentication and the admin container holds the Docker socket: anyone who
can reach port 8080 can gain root on the host. Docker-published ports bypass ufw. `lan` is for
networks you control; run `sudo nomad-expose local` before joining any other network. Native Ollama
(11434) is never exposed to the LAN while ufw is active.

## If the computer dies
1. Move the drive to an NVMe USB enclosure and plug it into any x86-64 PC.
2. Firmware boot menu → the USB drive. Secure Boot must be off on that PC (Limine is not
   Microsoft-signed). Pre-Turing NVIDIA cards get an unaccelerated desktop.
3. The backup OS boots and starts NOMAD. On first start it loads the image archive and re-creates the
   app containers from `installed-services.txt` against the existing data.

To use the datastore from another existing CachyOS/Arch install instead:
```
sudo mount /dev/disk/by-partlabel/NOMAD_DATA /mnt
(cd /mnt/host-bootstrap/toolkit && sha256sum -c SHA256SUMS)
sudo umount /mnt
sudo bash <copy of toolkit>/bootstrap-host.sh --hotplug [--autostart] [--offline]
sudo nomad-up
```

## How moving between hosts works
Containers and images live in each host's Docker, not on the drive. When an app's container is missing,
the admin marks it "not installed" (`admin/app/services/system_service.ts`, `_syncContainersWithDatabase`).
`nomad-stop-containers` records installed apps in `installed-services.txt` on every clean stop
(`save-images.sh` writes it too), and
`nomad-adopt-host` reinstalls them through `POST /api/system/services/install` on a host that lacks them.
Bind-mounted data is reused. `nomad_ollama` is never adopted; native Ollama owns port 11434.

Two operating systems share one database. Keep the admin image tag pinned (done by
`init-nomad-data.sh`), keep auto-update off, and re-run `save-images.sh` after updates so every host
loads the same image versions.

## Removing
`sudo bash uninstall-host.sh [--purge-containers]` removes the host-side setup. The datastore is never
modified.

## To confirm on first run
- Lexar model string matches the preflight default.
- `ghcr.io/crosstalk-solutions/project-nomad:v<version>` exists (`init-nomad-data.sh` falls back to `latest`).
- `nomad-expose local` blocks LAN access under iptables-nft.
- ROCm works on the 890M (gfx1150) before adding `rocm` to `--gpu` on the primary OS.
- Kiwix re-adoption does not re-download its bootstrap ZIM.
