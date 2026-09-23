# HANDOFF — Project N.O.M.A.D. on the X1 Pro (as of 2026-09-23)

Continuation of `PLAN-kenzik-project-nomad-init.md`. Read that first for the design; this file is the
current state, what is unverified, and the next steps. Runbook: `install/cachyos/README.md`.

## Working arrangement
- Claude Code runs on the daily driver (repo at `~/src/project-nomad`, branch `cachyos-portable`).
  The X1 Pro is reached by the user over SSH; Claude prepares commands, the user runs anything that
  needs root or is destructive and pastes output back.
- Fork: `git@github.com:kenzik/project-nomad.git`. Branch `cachyos-portable`, pushed. Commits:
  `34cff24` toolkit + plan, `663c377` background-start fix (see "Open item 1").
- On the X1 Pro the checkout is `~/project-nomad`; toolkit dir `~/project-nomad/install/cachyos`.

## Hardware / disk state on the X1 Pro (MINISFORUM X1 Pro-370, 64 GB, Radeon 890M)
- Primary CachyOS (installer defaults, znver4 repos) on the 512 GB NVMe. ufw active. Limine.
- Lexar 4 TB = `/dev/nvme0n1`:
  | Part | PARTLABEL | FS | State |
  |---|---|---|---|
  | p1 1 MiB | `NOMAD_BIOS` | — | Limine BIOS stage (written only if `build-backup-os.sh` finished) |
  | p2 4 GiB | `NOMAD_ESP` | vfat | formatted by `build-backup-os.sh` (result unconfirmed) |
  | p3 330 GiB | `NOMAD_ROOT` | ext4? | backup OS target; build result unconfirmed |
  | p4 3.4 TiB | `NOMAD_DATA` | ext4 | UUID `45d74f7a-ccca-42b7-9507-52218872436c`, mounted `/mnt/nomad` |
- Mirror fix applied: `krfoss.org` entries commented out in `/etc/pacman.d/cachyos-v4-mirrorlist`
  and `cachyos-mirrorlist` (those mirrors serve packages without `.sig` files). A future
  `cachyos-rate-mirrors` run may bring them back.

## Host bootstrap (done, verified)
`sudo bash bootstrap-host.sh --autostart --expose=lan --gpu=vulkan` → `/etc/nomad-host.conf`:
`AUTOSTART=yes HOTPLUG=no EXPOSE=lan GPU=vulkan`. Verified: docker + ollama + ollama-vulkan from
pacman, `ollama` uid/gid 614, `/mnt/nomad` mounted by UUID, ufw rule `11434/tcp on br-nomad`,
`nomad-ollama` and `project-nomad` active, `/opt/project-nomad` symlink.
The user is not in the `docker` group by default; `sudo docker …` or `usermod -aG docker dkenzik`.

## Datastore (done, verified)
`init-nomad-data.sh` ran: `compose.yml` (0600) pinned to `project-nomad:v1.34.1`, binds under
`/mnt/nomad/project-nomad/{storage,mysql,redis}`, `pull_policy: missing`, bridge `br-nomad`.
`/mnt/nomad/ollama` owned by ollama. Toolkit copy at `/mnt/nomad/host-bootstrap/toolkit` (refreshed
on every `bootstrap-host.sh` run since `663c377`).

## NOMAD state (done)
- 9 containers up: admin, dozzle, mysql, redis, updater, disk_collector, kiwix_server, kolibri_2, qdrant.
  No `nomad_ollama` (native Ollama in use).
- Remote Ollama URL set in the UI to `http://host.docker.internal:11434` (validated from the admin
  container). UI quirks: the "AI Assistant" Settings entry is hidden until this is configured — go to
  `/settings/models` directly; Kolibri is listed as "Education Platform (Gen 2)"; Qdrant is a hidden
  dependency service, auto-installed.
- Updates: core and app auto-update OFF; content auto-update ON (content only writes ZIM/map files,
  so this is fine for two operating systems sharing the DB).
- Content downloads and model pulls: whatever the user started in the UI; not tracked here.

## Open items, in order

### 1. Boot delay fix not yet applied on the primary
`systemd-analyze critical-chain graphical.target` showed `project-nomad.service +37.8s` (oneshot
wanted by multi-user.target → login screen waits for NOMAD). Fix is in `663c377` (`Type=exec`,
single `lib/nomad-start`, `nomad-up` polls readiness). It was NOT applied before the last reboot
(sudo failed at that moment), so the delay is still present. To apply:
```
cd ~/project-nomad && git pull && cd install/cachyos
sudo bash bootstrap-host.sh --autostart --expose=lan --gpu=vulkan --yes
systemctl cat project-nomad | grep -E 'Type=|ExecStart='   # expect Type=exec, nomad-start
```
Then reboot and re-check `systemd-analyze critical-chain graphical.target`.
Unrelated: `NetworkManager-wait-online` 5.9 s is stock behaviour.

### 2. Transient sudo failure (resolved, cause unknown)
After `build-backup-os.sh` ran, `sudo` rejected the correct password; a reboot fixed it. Most likely
`pam_faillock` after mistyped attempts (the backup-OS `passwd` prompt was interleaved). Nothing in
the toolkit touches host accounts; the chroot `passwd`/`useradd` calls act on `NOMAD_ROOT`. If it
recurs: `faillock --user dkenzik`.

### 3. Confirm the offline-asset scripts completed
The user ran `save-images.sh`, `build-pkgcache.sh --gpu=vulkan` and `build-backup-os.sh --user
dkenzik 2>&1 | tee ~/backup-os.log` but their outputs were never reviewed. Check:
```
sudo cat /mnt/nomad/host-bootstrap/docker-images/GENERATION /mnt/nomad/host-bootstrap/docker-images/IMAGES.txt
sudo ls -la /mnt/nomad/host-bootstrap/docker-images/ /mnt/nomad/host-bootstrap/pkgcache/
sudo cat /mnt/nomad/host-bootstrap/pkgcache/GLIBC_VERSION /mnt/nomad/host-bootstrap/installed-services.txt
tail -30 ~/backup-os.log
```
Expected manifest: `nomad_kiwix_server`, `nomad_kolibri_2`, `nomad_qdrant`.

### 4. Backup OS: build result unknown, never booted, has the OLD unit
`build-backup-os.sh` is the one script never tested before this run. If `~/backup-os.log` does not
end with "Backup OS ready", re-run it (safe: it only reformats p2/p3; NOMAD keeps running on p4).
Then: reboot → firmware boot menu (F7 on most MINISFORUM units; Del = Setup) → the Lexar "UEFI OS"
entry → log in as `dkenzik`. First boot loads the image archive before the login screen appears
(old oneshot unit; several minutes; `Esc` shows console). Verify:
```
systemctl --no-pager -n 15 status project-nomad nomad-ollama
sudo docker ps --format '{{.Names}}\t{{.Status}}' | sort
curl -s localhost:8080/api/health; cat /var/lib/nomad-host/images.generation; cat /etc/nomad-host.conf
```
Then update its toolkit from the drive's copy (flags from its `/etc/nomad-host.conf`; GPU there is
`vulkan,cuda,rocm` unless `--no-nvidia/--no-rocm` was used):
```
sudo bash /mnt/nomad/host-bootstrap/toolkit/bootstrap-host.sh --autostart --expose=lan --gpu=vulkan,cuda,rocm --yes
```
Open `http://localhost:8080` there and confirm the ZIMs and Kolibri content are visible.

### 5. Remaining verification (from the plan)
- Offline start on the primary: `nmcli networking off; sudo nomad-down; sudo nomad-up` with no pull.
- Exposure: `:8080` reachable from a LAN device; `sudo nomad-expose local` blocks it (confirms the
  DOCKER-USER rule under iptables-nft); `curl <ip>:11434` from the LAN refused.
- Clean stop: `sudo nomad-down --unmount` then `sudo e2fsck -fn /dev/disk/by-partlabel/NOMAD_DATA`.
- `efibootmgr` on the primary shows no new "Limine" entry from the chroot build.
- Model pulled in the UI lands in `/mnt/nomad/ollama/models` (614:614).

### 6. Later
- Content: ZIM tiers / Wikipedia / maps in the UI; Kolibri channel import at `:8310`.
- Re-run `save-images.sh` after any app install/update. Re-run `build-pkgcache.sh` occasionally.
- Optional iGPU GTT tuning for larger models (unverified): `ttm.pages_limit` / `ttm.page_pool_size`
  in `/etc/default/limine`, small BIOS UMA buffer.
- Decide whether to open a PR from `cachyos-portable` or keep it as a long-lived fork branch.
