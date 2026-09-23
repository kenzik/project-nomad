# PLAN — Project N.O.M.A.D. on CachyOS (MINISFORUM X1 Pro-370) with a removable-ready 4 TB datastore

## Context

Run Project N.O.M.A.D. on a fresh CachyOS install on a MINISFORUM X1 Pro-370 (Ryzen AI 9 HX 370,
Radeon 890M, 64 GB). Host software comes from pacman; every byte of state (ZIMs, maps,
Kolibri/Khan, Qdrant, MySQL, Redis, compose file with secrets, LLM models) lives on a new Lexar
4 TB NVMe in slot 2. That drive also carries its own ESP and a 330 GiB generic CachyOS, so if the
X1 Pro dies the drive can go into a USB enclosure and boot on an arbitrary Intel/AMD PC with
NOMAD intact. Nothing is installed on the daily driver; this session only authors the toolkit
and pushes it to the fork (`kenzik/project-nomad`).

## Topology

| Disk | Role |
|---|---|
| Slot 1, 512 GB | Primary CachyOS (normal installer, optimized repos). NOMAD host. |
| Slot 2, Lexar 4 TB | p1 BIOS-boot 1 MiB · p2 ESP 4 GiB `NOMAD_ESP` · p3 330 GiB backup OS `NOMAD_ROOT` (ext4, generic x86-64) · p4 rest (~3.3 TiB) ext4 `NOMAD_DATA` → `/mnt/nomad` |

## Decisions (from Q&A)

- ext4, unencrypted data partition. Docker + docker-compose from pacman; stock NOMAD images.
- Native Ollama from `extra`, models on the drive, NOMAD pointed at it via Remote Ollama URL.
  Primary host: `ollama` + `ollama-vulkan` (890M); `ollama-rocm` opt-in via flag.
- Backup OS: scripted pacstrap from the primary OS; generic x86-64; mesa (AMD+Intel),
  nvidia-open + `ollama-cuda`, `ollama-rocm`, `ollama-vulkan`; Plasma + Firefox.
- Autostart on; exposure = LAN, switchable with `nomad-expose local|lan`.
- Extras: immutable mountpoint guard, Docker image archive, offline pacman cache.
  Not selected: btrfs subvolumes for Docker (kept as opt-in flag `--docker-subvols`, default off;
  without it image layers sit inside snapper snapshots of the 512 GB root).

## Findings that shape the design

- No AUR package; upstream installer is Debian-only and hardcodes `/opt/project-nomad`
  (`install/install_nomad.sh:32,79`). Its compose template (`install/management_compose.yaml`) and
  secret substitutions (`install_nomad.sh:420-440`) are reused; its `rm -rf mysql` (`:428`) is not.
- Storage relocation is upstream-supported (compose `:21-31`, `docker_service.ts:526-603`);
  `mysql/`, `redis/` and `compose.yml` are outside it and are moved explicitly.
- Updater sidecar hardcodes `/opt/project-nomad/compose.yml` inside its container
  (`install/sidecar-updater/update-watcher.sh:9`) → bind real path `…:/opt/project-nomad`.
- `pull_policy: always` (compose `:13,116,127`) breaks `compose up` offline → `missing`.
- Missing containers flip apps to not-installed (`system_service.ts:957-1000`); bind data
  survives. A second host re-adopts via `POST /api/system/services/install {"service_name"}`.
  `nomad_ollama` is exempt when `ai.remoteOllamaUrl` is set and must never be installed.
- Admin API is unauthenticated and holds the Docker socket; Docker-published ports bypass ufw.
  ufw only governs native Ollama (11434).
- Packaged `ollama.service` hardcodes `OLLAMA_MODELS` and waits on `network-online.target`
  → ship a dedicated `nomad-ollama.service` (`Conflicts=ollama.service`), UID/GID pinned to 614.
- CachyOS + Limine: kernels live on the ESP, `limine-install` writes NVRAM entries, `chwd` drops
  machine-specific initramfs configs, installer selects znver4 repos on this CPU.

## Data partition layout (`/mnt/nomad`)

```
project-nomad/   compose.yml (0600, secrets)  storage/  mysql/  redis/
ollama/models/   (614:614)
host-bootstrap/  toolkit/ (copy of install/cachyos + SHA256SUMS)  installed-services.txt
                 docker-images/{nomad-images.tar.zst,GENERATION}  pkgcache/generic/
```

## Deliverables (fork, branch `cachyos-portable`)

`docs/plans/PLAN-kenzik-project-nomad-init.md` and `install/cachyos/`:

| File | Purpose |
|---|---|
| `README.md` | Runbook: every command, marked **[you run]** where root/destructive |
| `preflight-drive.sh` | Read-only. Finds the Lexar by model/size (3.9–4.1e12 B); refuses if any partition is mounted or it backs `/`, `/home`, `/boot`; prints the `/dev/disk/by-id/…` path. `--allow-usb` for enclosure use |
| `print-partition-commands.sh` | Prints the sgdisk/mkfs block for that by-id path; executes nothing |
| `bootstrap-host.sh` | Idempotent host setup. Flags: `--autostart --hotplug --expose=lan\|local --gpu=vulkan,rocm,cuda --offline --docker-subvols --chroot` |
| `init-nomad-data.sh` | One-time datastore init; refuses if `compose.yml` or `mysql/` exists |
| `lib/` | `nomad-preflight`, `nomad-start-children`, `nomad-stop-containers`, `nomad-adopt-host` (installed to `/usr/local/lib/nomad/` so the stop path never depends on the drive) |
| `nomad-up`, `nomad-down`, `nomad-expose` | Operator commands in `/usr/local/bin` |
| `units/` | `nomad-ollama.service`, `project-nomad.service`, `nomad-expose-local.service`, `99-nomad-autostart.rules` (hotplug only), `sysusers-ollama.conf` |
| `save-images.sh`, `build-pkgcache.sh` | Offline assets |
| `build-backup-os.sh` | Guarded pacstrap of the generic OS onto `NOMAD_ESP`/`NOMAD_ROOT` |
| `uninstall-host.sh` | Removes host-side units/config; never touches the drive |

## Steps

### Phase 0 — this session (daily driver, nothing installed here)
1. Copy this approved plan to `docs/plans/PLAN-kenzik-project-nomad-init.md`.
2. Create branch `cachyos-portable`; author the deliverables above.
3. Static checks: `bash -n`, `shellcheck` if present, and `init-nomad-data.sh --dry-run --root <scratchpad>`
   asserting no `replaceme` and no `/opt/project-nomad/` left-hand bind remains.
4. Commit. Push to `origin` after you confirm.

### Phase 1 — X1 Pro primary OS **[you run]**
Install CachyOS to the 512 GB SSD with the normal installer. In firmware: Secure Boot off.
`sudo pacman -S --needed git gptfdisk arch-install-scripts`, then clone the branch
(or `rsync` it from the daily driver).

### Phase 2 — Partition the Lexar **[you run; destructive]**
I run `preflight-drive.sh` (read-only) and show the resolved device; you confirm the serial, then run:
```
DISK=/dev/disk/by-id/nvme-Lexar_…_<SERIAL>
sudo sgdisk --zap-all "$DISK"
sudo sgdisk -n1:1M:+1M -t1:EF02 -c1:NOMAD_BIOS -n2:0:+4G -t2:EF00 -c2:NOMAD_ESP \
            -n3:0:+330G -t3:8304 -c3:NOMAD_ROOT -n4:0:0 -t4:8300 -c4:NOMAD_DATA "$DISK"
sudo partprobe "$DISK"; sudo udevadm settle
sudo mkfs.fat -F 32 -n NOMAD_ESP /dev/disk/by-partlabel/NOMAD_ESP
sudo mkfs.ext4 -L NOMAD_DATA -m 0 -i 65536 /dev/disk/by-partlabel/NOMAD_DATA
```
p3 stays unformatted until Phase 7. I verify with `lsblk -o NAME,SIZE,FSTYPE,PARTLABEL`.

### Phase 3 — Host bootstrap **[you run]**
`sudo bash install/cachyos/bootstrap-host.sh --autostart --expose=lan --gpu=vulkan`
1. `/etc/sysusers.d/ollama.conf` pinning 614:614 before the package installs (renumber the host
   user on mismatch; never `chown -R` the drive).
2. `pacman -S --needed docker docker-compose ollama ollama-vulkan` (offline: `[nomad-offline]` file repo).
3. `mkdir /mnt/nomad && chattr +i /mnt/nomad` (unmounted), then fstab by UUID:
   `UUID=… /mnt/nomad ext4 noatime,nofail,nodev,nosuid,x-systemd.device-timeout=10s 0 2`
   (`--hotplug`: adds `noauto` + UUID-matched udev rule).
4. Install units, libs, commands; symlink `/opt/project-nomad → /mnt/nomad/project-nomad` (convenience only).
5. `ufw allow in on br-nomad to any port 11434 proto tcp`; warn loudly if no firewall is active.
6. Enable `docker.service`, `nomad-ollama.service`, `project-nomad.service`; `nomad-expose-local.service` only for `--expose=local`
   (`iptables -I DOCKER-USER ! -i br-nomad -o br-nomad -m conntrack --ctstate NEW -j DROP`).

`project-nomad.service`: `Type=oneshot RemainAfterExit`, `Requires=docker.service`, `BindsTo/After=mnt-nomad.mount`,
`ExecStartPre=nomad-preflight` (mountpoint check; `docker load` if archive `GENERATION` differs from the host's),
`ExecStart=docker compose -p project-nomad -f /opt/project-nomad/compose.yml up -d`, then `nomad-start-children`,
`ExecStartPost=-nomad-adopt-host`, `ExecStopPost=nomad-stop-containers` (apps `-t 30`, then mysql/redis `-t 90`;
writes `installed-services.txt` only when adoption completed this session). Never `compose down`.

`nomad-ollama.service`: `OLLAMA_MODELS=/mnt/nomad/ollama/models`, `OLLAMA_HOST=0.0.0.0:11434`, `OLLAMA_NO_CLOUD=1`,
`OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_VULKAN=1`, `User=ollama`, `BindsTo=mnt-nomad.mount`, `After=network.target`.

### Phase 4 — Datastore init and first run **[you run]**
`sudo bash install/cachyos/init-nomad-data.sh` generates `compose.yml` from the fork's
`install/management_compose.yaml`: the installer's five `replaceme` substitutions (`URL=http://localhost:8080`,
32-char alnum secrets), anchored rewrites of the storage (×3), mysql, redis binds to `/mnt/nomad/project-nomad/…`,
updater bind `/mnt/nomad/project-nomad:/opt/project-nomad`, `pull_policy: missing`, admin tag pinned to the current
release (verified with `docker manifest inspect`, else `latest` + warning), and a `networks.default` block naming
the bridge `br-nomad`. Asserts `docker compose config` passes; copies the toolkit to `host-bootstrap/`.

Then `sudo nomad-up` → `http://localhost:8080`. First: Settings → Models → Remote Ollama URL
`http://host.docker.internal:11434`. Then Easy Setup (Kiwix, Kolibri, Qdrant, etc.). Disable NOMAD auto-update.

### Phase 5 — Content and models
Choose ZIM tiers, Wikipedia, maps in the UI; import Khan Academy inside Kolibri (`:8310` → Device → Channels);
pull models in Settings → Models. Reference sizes: all categories Comprehensive ≈ 85 GB, Wikipedia maxi ≈ 121 GB,
US maps ≈ 19 GB, planet map 100 GB+.
Optional iGPU tuning (unverified on kernel 7.x): small BIOS UMA buffer plus `ttm.pages_limit` /
`ttm.page_pool_size` in `/etc/default/limine` to raise GTT toward ~48 GiB; check Ollama's reported VRAM in `journalctl -u nomad-ollama`.

### Phase 6 — Offline assets
- `save-images.sh`: `compose config --images` ∪ images of all `nomad_*` containers → `docker save | zstd` →
  atomic rename; bump `GENERATION`; refresh `installed-services.txt`. Re-run after every NOMAD/app update.
- `build-pkgcache.sh`: generic config (`Architecture = x86_64`, `[cachyos] [core] [extra]`), blank `--dbpath` so all
  dependencies download, `-Syw` of docker, docker-compose, ollama, ollama-vulkan, both keyrings; `repo-add`; records
  build date + glibc version for the offline-install guard.

### Phase 7 — Generic backup OS on p3 **[you run; destructive to p2/p3 only]**
`sudo bash install/cachyos/build-backup-os.sh --user <name>`; targets by partlabel only, requires both on the same
disk as `NOMAD_DATA`, typed serial confirmation before `mkfs.ext4` on p3.
1. Generic pacman config; `pacstrap -K`: base, `linux-cachyos` + `linux-cachyos-lts` (with matching prebuilt
   nvidia-open modules), linux-firmware, amd-ucode, intel-ucode, mesa, vulkan-radeon, vulkan-intel,
   intel-media-driver, nvidia-utils, networkmanager, ufw, zram-generator, plasma-desktop, sddm, konsole, dolphin,
   firefox, docker, docker-compose, ollama + vulkan/cuda/rocm, git, gptfdisk, arch-install-scripts.
2. Before any limine package: `systemd-machine-id-setup --root`; `/etc/default/limine` with `ESP_PATH=/boot`,
   `SKIP_UEFI=yes`, `ENABLE_LIMINE_FALLBACK=yes`, `root=UUID=<p3>`. Then `limine limine-mkinitcpio-hook`.
3. `HOOKS=(base systemd microcode kms modconf block keyboard sd-vconsole filesystems)`: no `autodetect`, no
   `10-chwd*.conf`, NVIDIA modules not forced into the initramfs.
4. Legacy BIOS: `limine bios-install "$DISK" 1` + `limine-bios.sys` on the ESP.
5. UUID-only fstab (root, `/boot`, `/mnt/nomad` with `nofail`); hostname, locale, user, `ufw enable`.
6. In chroot: `bootstrap-host.sh --chroot --autostart --expose=lan --gpu=vulkan,cuda,rocm`.
7. Assert no optimized packages: `pacman -Qi | awk '/^Name/{n=$3} /^Architecture/{if($3!="x86_64"&&$3!="any")print n,$3}'` prints nothing.

### Phase 8 — Emergency / other-host procedure (documented in README)
Lexar → NVMe USB enclosure → firmware boot menu → USB. Secure Boot must be off on that PC. NOMAD autostarts;
images load from the archive; `nomad-adopt-host` reinstalls apps from the manifest against existing data.
Alternative: on any existing CachyOS/Arch host, mount p4 and run
`host-bootstrap/toolkit/bootstrap-host.sh --hotplug [--offline]` after verifying `SHA256SUMS`.

## Verification

- Guard: `lsattr -d /mnt/nomad` shows `i` when unmounted; with p4 unmounted `docker start nomad_mysql` fails and `/mnt/nomad` stays empty.
- Offline start: `nmcli networking off` → `sudo nomad-down && sudo nomad-up` succeeds with no pull.
- Ollama: `stat -c %u:%g /mnt/nomad/ollama/models` = `614:614`; a model pulled in the UI lands there;
  `docker exec nomad_admin curl -s host.docker.internal:11434/v1/models` works; `curl <ip>:11434` from another LAN device is refused.
- Exposure: `:8080` reachable from a LAN device in `lan`; times out after `nomad-expose local`.
- Clean stop: after `nomad-down`, `e2fsck -fn /dev/disk/by-partlabel/NOMAD_DATA` is clean.
- Simulated new host (on the primary): `nomad-down`, remove all `nomad_*` containers, network, update volume and images,
  `uninstall-host.sh`, networking off, `bootstrap-host.sh --offline …`, `nomad-up` → archive auto-loads, apps re-adopt,
  ZIMs/Kolibri/notes/models present.
- Backup OS: boot it on the X1 Pro from the firmware boot menu; NOMAD comes up; `efibootmgr` on the primary shows no new entry.
  Optional: QEMU with `-drive file=$DISK,format=raw,snapshot=on -cpu Westmere` under OVMF and SeaBIOS (after `nomad-down`).
  Once an enclosure is on hand, one real boot on a different PC.

## Limits and items to confirm at run time

- Secure Boot must be disabled on any rescue PC (Limine is not Microsoft-signed). Pre-Turing NVIDIA cards get an unaccelerated desktop.
- To confirm on the X1 Pro: Lexar model string for the preflight match; GHCR tag for the current release; `u!` sysusers
  syntax via `systemd-sysusers --dry-run`; `DOCKER-USER` rule behaviour under iptables-nft; ROCm on gfx1150 before using `--gpu=rocm`;
  Kiwix pre-install idempotence on adopt.
- Two hosts share one DB: keep the admin tag pinned, auto-update off, and re-run `save-images.sh` after updates so the backup OS loads matching images.
