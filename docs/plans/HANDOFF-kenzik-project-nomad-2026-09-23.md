# HANDOFF — Project N.O.M.A.D. on the X1 Pro (as of 2026-09-23)

Continuation of `PLAN-kenzik-project-nomad-init.md`. Read that first for the design; this file is the
current state, what is unverified, and the next steps. Runbook: `install/cachyos/README.md`.

## Working arrangement
- Claude Code runs on the daily driver (repo at `~/src/project-nomad`, branch `cachyos-portable`).
  `ssh nomad` works passwordless from the daily driver (`ssh -o BatchMode=yes nomad …`), so Claude
  runs read-only / non-root checks on the X1 Pro directly. `sudo` needs a password: the user runs
  anything that needs root or is destructive and pastes output back.
- Fork: `git@github.com:kenzik/project-nomad.git`. Branch `cachyos-portable`, pushed. Commits:
  `34cff24` toolkit + plan, `663c377` background-start fix (see "Open item 1").
- On the X1 Pro the checkout is `~/project-nomad`; toolkit dir `~/project-nomad/install/cachyos`.

## Hardware / disk state on the X1 Pro (MINISFORUM X1 Pro-370, 64 GB, Radeon 890M)
- Primary CachyOS (installer defaults, znver4 repos) on the 1 TB Kingston `OM8TAP41024K1` (4 GiB
  vfat `/boot` + btrfs root). ufw active. Limine (`Boot0003`).
- NVMe device names are NOT stable across boots: the Lexar was `nvme0n1` when the backup OS was
  built and is `nvme1n1` as of the 2026-09-23 evening check. The toolkit resolves everything by
  PARTLABEL/UUID; always use `/dev/disk/by-partlabel/NOMAD_*` in hand-typed commands.
- Lexar 4 TB (`Lexar SSD NM790 4TB`, serial ends `P220J`):
  | Part | PARTLABEL | FS | State |
  |---|---|---|---|
  | p1 1 MiB | `NOMAD_BIOS` | — | Limine BIOS stage written ("installed successfully" in the log) |
  | p2 4 GiB | `NOMAD_ESP` | vfat `FB19-D43F` | `EFI/BOOT/BOOTX64.EFI`, `limine-bios.sys`, `limine.conf`, kernels+initramfs under `7faf24feb75c4ca288c87ff391f66d46/` |
  | p3 330 GiB | `NOMAD_ROOT` | ext4 `0244d04a-4457-41bb-80e8-81eeadbfc13e` | backup OS, built OK (see item 4), never booted |
  | p4 3.4 TiB | `NOMAD_DATA` | ext4 | UUID `45d74f7a-ccca-42b7-9507-52218872436c`, mounted `/mnt/nomad` |
- Firmware entries: `Boot0007 "UEFI OS"` → `HD(2,GPT,4f09ef2c…)` is the firmware's own auto-detected
  entry for `NOMAD_ESP`'s fallback path (not created by the chroot build). `efibootmgr --bootnext 0007`
  boots the Lexar once without touching BootOrder.
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
on every non-chroot `bootstrap-host.sh` run since `663c377`). As of the last check it is still the
pre-`663c377` copy (no `lib/nomad-start`, oneshot unit); the item-1 re-run refreshes it.

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

### 3. Offline-asset scripts — DONE, verified 2026-09-23
`docker-images/`: `GENERATION 20260923T185117Z`, `nomad-images.tar.zst` 1.1 GB, `IMAGES.txt` has all
9 images (project-nomad v1.34.1, dozzle v10.0, disk-collector, sidecar-updater, kiwix-serve 3.8.1,
kolibri 0.19.4, mysql 8.0, qdrant v1.16, redis 7-alpine). `installed-services.txt` =
`nomad_kiwix_server nomad_kolibri_2 nomad_qdrant`. `pkgcache/GLIBC_VERSION 2.44+r24+g16be1518495f-1`.

### 4. Backup OS: first boot verified 2026-09-23 15:57; toolkit update on it still pending
`~/backup-os.log` ends with "Backup OS ready" and the script's verify step raised no warnings.
Two log entries that look like errors and are not: (a) three 404s from `archlinux.cachyos.org`
during pacstrap (glibc, libgfortran, ttf-dejavu) fell back to another mirror and installed;
(b) stage 1's `Updating linux initcpios` hook fails with `call to execv failed` because stage 1
has no kernel yet; stage 2 built both initramfs images (`linux-cachyos 7.2.5`, `linux-cachyos-lts
6.18.50`) successfully.
The OS as built has NO sshd. The toolkit now installs `openssh`, opens 22/tcp in ufw and copies the
user's `authorized_keys` (uncommitted change to `build-backup-os.sh` + README, 2026-09-23 evening).
DONE on the built OS 2026-09-23 via chroot from the primary, kept for reference (ufw is flipped to
ENABLED=no around the rule add so it writes `user.rules` instead of programming the primary's
netfilter; verified: rule present, `ENABLED=yes`, `sshd.service` enabled, `authorized_keys` 0600):
```
T=/run/nomad-backup-os; sudo mkdir -p $T
sudo mount /dev/disk/by-partlabel/NOMAD_ROOT $T
sudo mount -o fmask=0077,dmask=0077 /dev/disk/by-partlabel/NOMAD_ESP $T/boot
sudo arch-chroot $T pacman -Syu --needed --noconfirm openssh
sudo arch-chroot $T systemctl enable sshd.service
sudo sed -i 's/^ENABLED=yes/ENABLED=no/' $T/etc/ufw/ufw.conf
sudo arch-chroot $T ufw allow 22/tcp comment sshd
sudo sed -i 's/^ENABLED=no/ENABLED=yes/' $T/etc/ufw/ufw.conf
sudo install -d -m700 $T/home/dkenzik/.ssh
sudo install -m600 ~/.ssh/authorized_keys $T/home/dkenzik/.ssh/authorized_keys
sudo arch-chroot $T chown -R dkenzik:dkenzik /home/dkenzik/.ssh
sudo grep -- '--dport 22 ' $T/etc/ufw/user.rules; sudo grep ENABLED $T/etc/ufw/ufw.conf
sudo umount -R $T
```
Booting it: `sudo efibootmgr --bootnext 0007 && sudo reboot` from the primary (one-shot; BootOrder
stays primary-first, so a plain reboot returns to the primary), or F7 at power-on → the Lexar
"UEFI OS" entry. It takes the primary's DHCP lease (10.0.10.186) with its own host key; the daily
driver has `ssh nomad-rescue` (alias → that IP, own `UserKnownHostsFile`). sshd does not wait for
`project-nomad.service`. `hostname` binary is absent (no inetutils) — `nomad-up` now uses `ip`.

First boot 2026-09-23 15:57, verified over SSH:
- `nomad-rescue`, kernel `7.2.5-1-cachyos`, `root=UUID=0244d04a…`, `/` `/boot` `/mnt/nomad` all on
  the Lexar, `BootCurrent 0007`, no firmware entries added, no non-x86_64 packages. Login screen is
  stock SDDM/Plasma without CachyOS theming — expected for a pacstrap, and a handy tell.
- sshd/ufw/NetworkManager/docker/nomad-ollama (0.34.3 generic) active; preflight applied the deferred
  Ollama ufw rule and loaded image archive `20260923T185117Z`; compose up; kiwix, kolibri, qdrant
  adopted; `project-nomad` finished. `/etc/nomad-host.conf` there: `GPU=vulkan,cuda,rocm`.
- From the LAN: `:8080` ok, `:8310` Kolibri answers, `:8090` Kiwix serves "Wikipedia 100" (the ZIM
  downloaded on the primary), `:11434` times out (ufw). Kolibri has no channels yet.
- Old oneshot unit confirmed there: `project-nomad.service +1min 16s` → `graphical.target` at 1:26.

Remaining, on the rescue OS (root; the drive's toolkit copy is at the `663c377` state, which has
the new unit):
```
sudo bash /mnt/nomad/host-bootstrap/toolkit/bootstrap-host.sh --autostart --expose=lan --gpu=vulkan,cuda,rocm --yes
systemctl cat project-nomad | grep -E '^(Type|ExecStart)='   # expect Type=exec, nomad-start
sudo efibootmgr --bootnext 0007 && sudo reboot                # come back to the rescue OS once more
```
DONE 2026-09-23 16:23: after the toolkit update and reboot, `project-nomad.service +10ms`,
`graphical.target` at 9.3 s (was 1 min 26 s), Ollama on ROCm from boot, model persisted.
The rescue OS still has the hand-installed `nomad-ollama.service` (same content as `11e8c7a`);
re-run bootstrap from the drive copy there once the primary has refreshed it.

### 4b. Ollama runs CPU-only: iGPU dropped by default (found 2026-09-23 on the rescue OS)
`journalctl -u nomad-ollama` shows `dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1`
for both the ROCm (gfx1150) and Vulkan (RADV STRIX1) views of the Radeon 890M, then
`inference compute … library=cpu`, `total_vram=0 B`. Ollama ≥ 0.34 skips iGPUs by default; the
primary (0.34.2) confirmed the same 2026-09-23 16:27 (`dropping integrated GPU … library=Vulkan`).
Fix: `Environment=OLLAMA_IGPU_ENABLE=1` added to `units/nomad-ollama.service` (uncommitted). GPU
device nodes (`/dev/dri/renderD128`, `/dev/kfd`) are 0666 on CachyOS, so no group change is needed.
Rollout: commit → on the primary `git pull` + `bootstrap-host.sh` re-run (installs the unit and
refreshes the drive's toolkit copy) → on the rescue OS re-run bootstrap from the drive copy. For the
immediate test the unit was installed by hand on the rescue OS (16:2x): Ollama now reports
`inference compute library=ROCm compute=gfx1150 type=iGPU total="30.2 GiB"`, `default_num_ctx=32768`.
It picked ROCm over Vulkan (both installed there). Tested with `qwen3:0.6b` (pulled via the API,
522 MB, on the datastore as ollama:ollama): `offloaded 29/29 layers to GPU`, load 1.6 s, generate
OK; ROCm gfx1150 works under the bundled `rocm_v7_2`. The primary has only `ollama-vulkan` → Vulkan;
rolled out to the primary 2026-09-23 16:30 (`git pull` → `bc8f4c3`, bootstrap re-run, Ollama
restarted): `inference compute library=Vulkan … type=iGPU total_vram=32.2 GiB`, `offloaded 29/29
layers`, generate OK. Both OSes now run the model on the 890M. The drive's toolkit copy is current.
"No Models Installed" in the AI Assistant is expected until a model is pulled: `blobs/` on the
datastore has been empty since creation (`total blobs: 0`); "Remote Connected" confirms
`host.docker.internal:11434` works on the rescue OS too.

### 4c. Desktop parity for the rescue OS — DONE (user-confirmed 2026-09-23 18:20 on 6.18.50-lts)
Second `--refresh` (after `91dd56d`/`16519a5`) completed the greeter system setup, LTS-first Limine,
and PAM keyring: login without the keyring dialog (`login.keyring` created), desktop matches the
primary with the Nord palette, logout → greeter visible → login again. That refresh also re-ran
`bootstrap-host.sh --chroot`, so the rescue OS's units are the toolkit's (hygiene item closed).
Leftover `[output] scale = 2.0` block in `/var/lib/noctalia-greeter/greeter.toml` on the rescue OS:
removed by the user 2026-09-23 18:2x (file now ends with `[auth]` and `[session]` only).
Applied with `--refresh` (commits `8cecde6`…`91dd56d`); verified over SSH after reboot: greetd runs
`noctalia-greeter` (sddm disabled), all Hyprland `config/*.lua` present, Noctalia `builtin = "Nord"`
in config and state, black wallpaper, 84 JuliaMono faces (carried from the AUR package), shell zsh,
os-release "CachyOS", `/etc/motd`, systemd-resolved stub + mDNS, avahi → `nomad-rescue.local`
resolves from the daily driver (its `nomad-rescue` alias now uses that name). Boot chain 13 ms,
NOMAD healthy, model visible. Lessons: `ttf-juliamono-nerd-font` is AUR-only (fonts of `pacman -Qm`
packages are now copied to `/usr/local/share/fonts/`); `noctalia-greeter`'s install hook runs before
sysusers creates `greeter` in a chroot, so the script re-runs `setup_greeter_system.sh` afterwards.
The primary is NOT Plasma: it is the CachyOS Hyprland + Noctalia edition (`cachyos-hypr-noctalia`
meta, `noctalia-greeter` on greetd with `/etc/greetd/environments` = `/usr/bin/Hyprland`, shell zsh
with `cachyos-zsh-config` + `~/.p10k.zsh`, Noctalia palette `Ayu` pinned in
`~/.config/noctalia/config.toml` and `~/.local/state/noctalia/settings.toml`, solid-black wallpaper
at `~/.local/share/wallpapers/solid-black.png`, Hyprland config in Lua under `~/.config/hypr/`,
monitor pinned by EDID description; `~/.local/bin/whispr` bound to Pause/Scroll_Lock/Insert).
`build-backup-os.sh` now installs that stack, copies the user's desktop dotfiles, matches the login
shell, enables systemd-resolved (required by `cachyos-settings`' `dns=systemd-resolved`) and avahi
(`nomad-rescue.local`), writes `/etc/motd`, and patches the Noctalia palette to `--theme` (default
`Nord`) as the visual tell. New `--refresh` mode applies it to the existing rescue OS in place.
To apply (primary, root; ~2 GB of packages):
```
cd ~/project-nomad && git pull && cd install/cachyos
sudo bash build-backup-os.sh --user dkenzik --refresh 2>&1 | tee ~/backup-os-refresh.log
```
Then boot the rescue OS (`sudo efibootmgr --bootnext 0007 && sudo reboot`) and check: greeter is
Noctalia's, Hyprland session with your layout/binds, bar in the Nord palette, black wallpaper,
`ssh nomad-rescue.local` resolves (then switch the daily driver's alias from the IP to it).
Not carried over on purpose: `~/.local/bin` (whispr, herdr), Plymouth splash, `cachyos-hello`.

### 4d. Kernel 7.2.x amdgpu regression: blank greeter after logout (found 2026-09-23 evening)
Symptom: after logging out of Hyprland (or `systemctl restart greetd`), the screen shows a solid
colour (purple, later green) although greeter and compositor log a normal modeset, first frame and
even accept the password blind (login works, the session is equally invisible). Kernel messages:
`amdgpu … REG_WAIT timeout … optc35_disable_crtc` at boot on every kernel (noise), nothing at the
failure. Isolation: rescue OS 7.2.5 → broken; primary 6.18.52-lts → fine; primary 7.2.6 → broken.
Same greeter, config, monitor (Dell S2725QS 4K@120 over HDMI). Ruled out: `pam_gnome_keyring` lines,
greeter `sync.toml`, stale greeter sessions, greeter scale relayout (pinning `[output] scale = 2`
changes the colour, not the result). Workaround: LTS first in `/etc/default/limine`
`BOOT_ORDER="*lts, *, *fallback…"` + `limine-update` on both OSes; the build script now defaults to
LTS-first and `--refresh` re-applies it. On the primary the installer's `limine.conf` header also has
`remember_last_entry: yes`, which overrides `default_entry: 2` with whatever was picked last;
`limine-update` preserves the header, so it was set to `no` by hand (2026-09-23 18:0x). Config
precedence in the CachyOS Limine tooling: `/etc/limine-entry-tool.conf` then `/etc/default/limine`
(highest). Revisit when a 7.2.x fix lands (test: log out on 7.2.x).
Keyring: the primary has a user-created `Default_keyring.keyring` and no `pam_gnome_keyring` in its
greetd PAM; the rescue OS has the PAM lines (script) — after the first PAM login there it should
own a `login.keyring`; check `~/.local/share/keyrings/` there.

### 5. Remaining verification (from the plan)
- Both OSes now default to the LTS kernel (primary 6.18.52, rescue 6.18.50); logout → greeter
  verified on both. When a newer 7.2.x lands, test logout on it before switching `BOOT_ORDER` back.
- Offline start on the primary: DONE 2026-09-23 18:46 after the fix in `0f7044e` (first attempt
  18:31–18:37 failed, see below). Re-run: networking off 18:45:01 → `nomad-down` 18:45:35 →
  `NOMAD is up` 18:46:10, no pull/registry lines in the docker log, NM left `br-nomad` alone,
  networking restored by the trap, all ports answering. The 28 `[resolver] connect failed` docker
  warnings are containers trying DNS while offline; harmless.
  Rescue OS still needs the drop-in: boot it and run
  `sudo bash /mnt/nomad/host-bootstrap/toolkit/bootstrap-host.sh --autostart --expose=lan --gpu=vulkan,cuda,rocm --yes`
  (the drive copy was refreshed 18:44), then `nmcli device status | grep br-nomad` → `unmanaged`.
  Run it as a transient unit so it survives the SSH session dropping:
  `sudo systemd-run --unit=nomad-offline-test --collect bash -c 'trap "nmcli networking on" EXIT; nmcli networking off; sleep 2; nomad-down; READY_TIMEOUT=300 nomad-up'`
  then `journalctl -u nomad-offline-test`.
  What happened: compose came up (mysql/redis healthy 18:32:55, admin started), but `nomad-up` got
  `Connection reset by peer` from `localhost:8080` for the full 300 s. Cause: NetworkManager 1.58.1
  had assumed Docker's `br-nomad` (and `docker0`) as "external" connections
  (`nmcli device` showed `connected (externally)`); `networking off` deactivated them
  (`state change: activated -> deactivating (reason 'networking-off', managed-type: 'external')`)
  and flushed `172.18.0.1/16`; `networking on` re-activated `br-nomad` with an empty profile, so the
  address never came back. With no route to 172.18.0.0/16 docker-proxy cannot dial the containers
  → every published port dead, even from localhost, while container-to-container traffic (admin →
  mysql) is fine. NM's suspend/resume path is the same code, so a suspend would do this too.
  Fix: `units/50-nomad-unmanaged.conf` → `/etc/NetworkManager/conf.d/` (`unmanaged-devices=
  interface-name:br-nomad;docker0;br-*;veth*`), installed by `bootstrap-host.sh` (+ NM reload),
  removed by `uninstall-host.sh`. Immediate recovery: `sudo ip addr add 172.18.0.1/16 dev br-nomad`.
  Rollout: primary `git pull` + bootstrap re-run (refreshes the drive copy) → rescue OS bootstrap
  re-run from `/mnt/nomad/host-bootstrap/toolkit` (it has NM too). Then re-run the offline test.
- DONE 2026-09-23 18:3x on the rescue OS (toolkit is identical on both): with `nomad-expose local`
  every published port (`:8080 :8310 :8090 :8311`) times out from the LAN while `localhost:*` and the
  host's own LAN IP still answer — the DOCKER-USER rule works under iptables-nft. `nomad-expose lan`
  restores 302/302/200. `:11434` from the LAN times out in both modes (ufw default deny drops, so
  "timeout", not "refused"). Note the app ports are published by the admin with `0.0.0.0` and `::`
  docker-proxy listeners; the host has no global IPv6, so the userland-proxy IPv6 bypass of
  DOCKER-USER is moot here but would apply on an IPv6-routed LAN.
- DONE 2026-09-23 18:23 on the rescue OS: `nomad-down --unmount` (clean; containers stopped apps
  first, then mysql/redis) → `e2fsck -fn /dev/disk/by-partlabel/NOMAD_DATA` clean, `1094/57040896
  files, 4426201/912640081 blocks`, under a minute → `nomad-up` healthy in ~35 s, apps re-started
  by `nomad-start-children`, ports answering again.
- DONE: `efibootmgr` on the primary shows no "Limine" entry from the chroot build (only the
  firmware's own `Boot0007 UEFI OS` for `NOMAD_ESP`).
- DONE (via API on the rescue OS): a pulled model lands in `/mnt/nomad/ollama/models` as 614:614.

### 6. Content — IN PROGRESS (started 2026-09-23 18:5x on the primary, via the admin API)
User's choices: Wikipedia `all-maxi` (124 GB), all six Kiwix categories at `<slug>-comprehensive`
(tiers include the lower ones via `includesTier`; ~87 GB incl. the FDA drug-label dataset), all nine
US map collections (~20 GB) after `POST /api/maps/setup-world-basemap` (base assets + ~15 MB
low-zoom world). 104 jobs were queued (BullMQ: 3 concurrent); `delayed` = retry backoff.
Watch: `python3 dlstatus.py` (scratchpad; reads `GET /api/downloads/jobs` on 10.0.10.186 — use the
IPv4 address, `nomad.local` resolves to a link-local IPv6 first for Python) or the Downloads page.
Do not reboot into the rescue OS while the queue is draining; the queue lives in the shared Redis
volume and the partial files are resumable, but there is no reason to test that now.
Kolibri (`:8310`): wizard done by the user 2026-09-23 18:54 ("Home Facility for dkenzik",
facility `50cbc6cb…`, superuser `dkenzik`, "on my own" setup). All 43 English public Studio
channels (328 GB) queued 2026-09-23 19:0x as `kolibri.core.content.tasks.remoteimport` tasks via
`POST /api/tasks/tasks/` (session login `POST /api/auth/session/` with `{username,password,
facility}`, then `X-CSRFToken` from the `kolibri_csrftoken` cookie); Kolibri runs 4 imports at a
time. Watch: Device → Channels in the UI, or `GET /api/tasks/tasks/` with the session cookie.
The user used a temporary superuser password for this; change it in Kolibri afterwards. Channel
list with ids/sizes: scratchpad `kolibri-en-channels.json` (regenerate from
`https://studio.learningequality.org/api/public/v1/channels?lang=en`, filter `language == en`).
After everything lands: re-run `save-images.sh` is NOT needed (content only), but check
`installed-services.txt` unchanged and `df -h /mnt/nomad`.

Result 2026-09-24 05:4x: Wikipedia `all-maxi` installed (`wikipedia_en_all_maxi_2026-02.zim`), all
nine map collections 50/50 files (16 GB), Kolibri: all 43 channels imported (250 GB; two imports
skipped 2343 + 709 files that 404 on Studio itself — upstream, not local). ~460 GB on the datastore.
Two problems met on the Kiwix side, both handled through the API:
- `download.kiwix.org` → `lb.download.kiwix.org` → `mirror.download.kiwix.org` throttled the 18 GB
  TED Conference ZIM to ~50–90 KB/s (same from the daily driver). Cancelled the job
  (`POST /api/downloads/jobs/:id/cancel`, deletes the partial) and re-queued it with
  `POST /api/zim/download-remote {url, metadata:{title}}` from
  `https://laotzu.ftp.acc.umu.se/mirror/kiwix.org/zim/…` (≈95 MB/s; `ftp.fau.de/kiwix/zim` ≈ 9 MB/s).
  `InstalledResource` bookkeeping keys on the filename-derived resource id, so a same-filename
  download from another mirror is recorded like the manifest's.
- Three manifest URLs are dead upstream (Kiwix renamed/rotated them): `canadian_prepper_bugoutconcepts_en_2026-02`,
  `canadian_prepper_winterprepping_en_2026-02` (now `canadian-prepper_en_<topic>_2026-08.zim`) and
  `librepathology_en_all_maxi_2025-09` (now `2026-09`). `POST /api/manifests/refresh` did not change
  `zim_categories`. Downloaded the current files via `download-remote` from the umu.se mirror and
  removed the failed jobs (`DELETE /api/downloads/jobs/:id`). Because the new filenames parse to
  different resource ids, the Survival tier showed no installed tier and Medicine 1 missing.
  Fix chosen 2026-09-24: (a) rename the two prepper files on disk to the manifest's ids
  (`canadian_prepper_<topic>_en_2026-08.zim`) + `docker restart nomad_admin` (reconcile runs only
  at admin start, `bin/server.ts`, and deletes rows whose id is not on disk — so DB edits do not
  stick) + `POST /api/zim/rescan-library`; LibrePathology's new filename already parses to its id.
  (b) Upstream PR https://github.com/Crosstalk-Solutions/project-nomad/pull/1364 (branch
  `fix/collections-renamed-kiwix-zims` on the fork, from `upstream/dev`, manifest only). When it is
  merged and the manifest refreshes, the ids become `canadian-prepper_en_<topic>` → rename the two
  files back to the Kiwix names (or re-download) so the tier matches again.
  DONE 2026-09-24 06:3x: after the rename + `docker restart nomad_admin` + rescan (62 books),
  Survival = `survival-comprehensive`.
- Medicine showed only `medicine-essential`: upstream bug in v1.34.1. `installed_resources.resource_type`
  is `enum('zim','map')`, so `IngestDrugDataJob`'s 'dataset' row for `openfda-drug-labels` failed with
  "Data truncated for column 'resource_type'" (admin.log) although the 262,880 labels ingested fine.
  Fixed upstream on `dev` by migration `1778800000001_add_dataset_to_installed_resources_type`
  (`ALTER TABLE installed_resources MODIFY COLUMN resource_type enum('zim','map','dataset') NOT NULL`).
  Applied the same ALTER by hand 2026-09-24 06:4x via
  `sudo docker exec -i nomad_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" nomad' <<EOF … EOF`
  and inserted the row the job had tried to write (values from the log; `collection_ref=medicine`,
  `version=2026-09-23`). Idempotent with the upstream migration when NOMAD is upgraded. Result: all
  six categories report `<slug>-comprehensive`; queue empty; 62 ZIMs / 214 GB.
  Current filenames: `curl -sL https://download.kiwix.org/zim/<dir>/ | grep -o '[a-z0-9_.-]*<name>[a-z0-9_.-]*\.zim'`.

### 6b. Map regions by country ("Manage Map Regions" modal) — size estimate times out
2026-09-24 06:46 the user selected the North America + South America groups; the modal showed an
estimate error, then "Still estimating size" on Download. Cause (admin.log, both attempts):
`pmtiles extract --dry-run` against the 138 GB Protomaps planet build is killed by the admin's
`DRY_RUN_TIMEOUT_MS = 60_000` (`admin/app/services/map_service.ts:44`, unchanged on upstream/dev
since #780). Measured with go-pmtiles 1.31.2 from the daily driver, maxzoom 15: CONUS 26 s,
Canada 64 s, North America 64 s, North+South America 109 s (44 GB result); at maxzoom 12 → 2 s.
`CountryPickerModal.startDownload()` refuses without a finished preflight, but
`POST /api/maps/extract {countries, maxzoom}` does not need one. Queued `north-america` (38
countries, includes US → duplicates the state files, harmless) and `south-america` (13) at z15 via
the API 2026-09-24 07:0x → `north-america_20260924_z15.pmtiles`, `south-america_20260924_z15.pmtiles`.
Possible upstream PR (pending the user's go): `DRY_RUN_TIMEOUT_MS = 5 * 60_000`, matching
`WORLD_BASEMAP_EXTRACT_TIMEOUT_MS` in the same file; no client (axios) or server timeout is shorter.
Queue view from the host: `nomad-downloads [retry|cancel|rm <jobId>]` (toolkit, needs `jq`, which
`bootstrap-host.sh` now installs; `build-pkgcache.sh` includes it too, so re-run that before the next
offline bootstrap). Extract jobs report no `totalBytes` until they finish (0 GB total is normal).

### 7. Later
- Re-run `save-images.sh` after any app install/update. Re-run `build-pkgcache.sh` occasionally.
- Optional iGPU GTT tuning for larger models (unverified): `ttm.pages_limit` / `ttm.page_pool_size`
  in `/etc/default/limine`, small BIOS UMA buffer.
- Decide whether to open a PR from `cachyos-portable` or keep it as a long-lived fork branch.
- Backup OS look: it is a bare pacstrap (stock SDDM with no theme config, plain Plasma, bash), not
  a copy of the primary's CachyOS theming. If it should match, list the primary's `cachyos-*` /
  SDDM-theme packages (`pacman -Qq | grep cachyos`) and add the arch-generic ones to the desktop
  list in `build-backup-os.sh`; they can be installed on the existing rescue OS with `pacman -S`.
