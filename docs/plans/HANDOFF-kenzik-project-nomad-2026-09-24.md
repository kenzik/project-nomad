# HANDOFF — Project N.O.M.A.D. on the X1 Pro (as of 2026-09-24)

Supersedes `HANDOFF-kenzik-project-nomad-2026-09-23.md` (kept for the history of how each item was
found and fixed). Design: `PLAN-kenzik-project-nomad-init.md`. Runbook: `install/cachyos/README.md`.

## Start here (new session)
1. Read this file; the 09-23 handoff only when a "why" is needed. Memory has the standing rules
   (ask before content installs; upstream PRs only on explicit go, fix-only, from `upstream/dev`).
2. Which OS is up: `ssh -o BatchMode=yes nomad hostname` (primary) or `… nomad-rescue hostname`.
   Quick health from the daily driver: `curl -4 -s http://10.0.10.186:8080/api/health`,
   `ssh nomad 'systemctl is-active project-nomad nomad-ollama; nomad-downloads; df -h /mnt/nomad'`.
3. State of both hosts as of 2026-09-24 07:40: primary on 6.18.52-lts, rescue on 6.18.50-lts, both
   with toolkit `495fd39` installed and the drive copy current; image archive `20260924T112953Z`
   (16 images) loaded on both; pkgcache 199 files. The X1 Pro checkout `~/project-nomad` is at
   `495fd39` (docs-only behind `origin/cachyos-portable`; `git pull` there is optional).
4. Nothing is running or half-done. The only live loose ends are open items 3 and 5 below, and the
   Kolibri password (open item 9).
5. The session scratchpad had `dlstatus.py` (queue viewer, superseded by `nomad-downloads`) and a
   Kolibri session cookie jar; both are gone with the session. Nothing persistent lives outside the
   repo, the two hosts and the datastore.

## Working arrangement (unchanged)
- Claude Code on the daily driver, repo `~/src/project-nomad`, branch `cachyos-portable` on the fork
  `kenzik/project-nomad` (no PR; long-lived). `upstream` remote = `Crosstalk-Solutions/project-nomad`.
- `ssh nomad` (primary, mDNS `nomad.local`) and `ssh nomad-rescue` (`nomad-rescue.local`) are
  passwordless for read-only checks; only one OS runs at a time. Root/destructive commands are run by
  the user, output pasted back. `sudo efibootmgr --bootnext 0007 && sudo reboot` boots the rescue OS
  once; a plain reboot returns to the primary.
- For scripts on the daily driver use the X1 Pro's IPv4 `10.0.10.186`: `nomad.local` resolves to a
  link-local IPv6 first, which Python's urllib cannot use (curl `-4` is fine).

## State: DONE and verified
- Both OSes boot the LTS kernel by default (7.2.x amdgpu logout bug, see the 09-23 handoff §4d).
- Toolkit at `495fd39` on both OSes and on the drive copy (`/mnt/nomad/host-bootstrap/toolkit`).
  Includes: `Type=exec` background start, `OLLAMA_IGPU_ENABLE=1`, desktop parity for the rescue OS,
  NetworkManager drop-in (`0f7044e`), `nomad-downloads` + `jq` (`495fd39`).
- Section-5 verification complete: exposure toggle (DOCKER-USER rule works under iptables-nft; note
  the IPv6 userland-proxy bypass is moot without global IPv6), clean stop + `e2fsck -fn` clean,
  offline start on the primary (after the NM fix), rescue OS boots with the drop-in and adopts apps.
- Content on the datastore (521 GB used of 3.4 TB): Wikipedia `all-maxi` (124 GB), all six Kiwix
  categories at `*-comprehensive` (62 ZIMs, 214 GB total), FDA drug reference (262,880 labels),
  nine US map collections + `north-america_20260924_z15.pmtiles` (35 GB) +
  `south-america_20260924_z15.pmtiles` (8.5 GB), Kolibri: all 43 English public Studio channels
  (250 GB). Kolibri facility "Home Facility for dkenzik", superuser `dkenzik` (password was a
  temporary one — user to change it).
- Apps installed by the user in the Supply Depot besides kiwix/kolibri/qdrant: cyberchef,
  excalidraw, it_tools, jellyfin, meshcore_web, stirling_pdf, vaultwarden. `installed-services.txt`
  lists all ten; the rescue OS adopted the seven new ones on 2026-09-24 07:25 (online pull).

## Open items
1. DONE 2026-09-24 07:29 on the rescue OS: `save-images.sh` → generation `20260924T112953Z`, 16
   images, 3.0 GB. The primary's `/var/lib/nomad-host/images.generation` is still the 09-23 one, so
   its next boot `docker load`s the new archive once (a minute; images already present). Re-run
   `save-images.sh` after every app install/update.
2. DONE 2026-09-24: `build-pkgcache.sh` re-run on the rescue OS (69 packages, 6.9 GB, includes `jq`).
3. **Kiwix manifest workaround in place** (details in the 09-23 handoff §6): two files renamed on
   disk to the manifest's old ids (`canadian_prepper_{bugoutconcepts,winterprepping}_en_2026-08.zim`).
   When upstream PR https://github.com/Crosstalk-Solutions/project-nomad/pull/1364 is merged and
   `POST /api/manifests/refresh` picks it up, rename them back to
   `canadian-prepper_en_{bugoutconcepts,winterprepping}_2026-08.zim`, `docker restart nomad_admin`,
   `POST /api/zim/rescan-library`. Kiwix catalog auto-update does not cover these two until then.
4. **Manual DB fix applied** (v1.34.1 bug): `installed_resources.resource_type` widened to
   `enum('zim','map','dataset')` and the `openfda-drug-labels` dataset row inserted by hand. Upstream
   `dev` has migration `1778800000001_add_dataset_to_installed_resources_type`; it is idempotent with
   what was done. Nothing to do at upgrade time.
5. **Map "Manage Map Regions" size estimate** fails for continent-scale selections: admin kills
   `pmtiles extract --dry-run` at 60 s (`map_service.ts:44`); measured NA+SA needs ~110 s. Workaround:
   `POST /api/maps/extract {countries, maxzoom}` needs no estimate (that is how the two continents
   were queued). Upstream PR raising `DRY_RUN_TIMEOUT_MS` to `5 * 60_000` is drafted in the head but
   NOT opened — the user said no PR for now.
6. Kernel 7.2.x: when a newer 7.2.x lands, test logout → greeter on it before switching
   `BOOT_ORDER` back (both OSes).
7. Optional: GTT tuning for larger models (`ttm.pages_limit`/`ttm.page_pool_size`), unverified.
8. Decide whether `cachyos-portable` ever becomes a PR; NOMAD does not support non-Debian hosts.
9. Kolibri superuser `dkenzik` still has the temporary password used for the API imports; change it
   in Kolibri (user menu → Profile). The imports do not depend on it.
10. `nomad-expose local` only covers IPv4: Docker's userland proxy also listens on `[::]:<port>` and
    connects to the containers from the host, bypassing DOCKER-USER. Moot on this LAN (no global
    IPv6 on the X1 Pro), but if that changes, add an `ip6tables` rule or set `"userland-proxy": false`
    / `"ipv6": false` in `/etc/docker/daemon.json` and re-test from a v6 client.

## Candidate next work (none started; pick with the user)
- Suspend/resume on the primary: same NetworkManager path as `networking off`; the drop-in should
  make it a non-event — verify `ip -4 addr show br-nomad` and `:8080` after a resume.
- Backups of the state that is not re-downloadable: `mysql/` (NOMAD DB), `storage/kolibri-gen2/`
  (facility + user data), Vaultwarden data, Jellyfin config. Everything else on the datastore is
  re-fetchable. No backup exists today; the drive is the single copy.
- Jellyfin/Vaultwarden/MeshCore first-run setup happened in the UI on the primary (not tracked
  here); check they behave on the rescue OS (they adopted and run, but no one has logged in there).
- Model choice for the AI Assistant: only `qwen3:0.6b` has been pulled (test model); pull whatever
  the user wants via Settings → Models (lands in `/mnt/nomad/ollama/models`, 32 GiB VRAM budget on
  the 890M, `default_num_ctx=32768`). Optional GTT tuning (item 7) if a larger model is wanted.
- `build-backup-os.sh --refresh` after any desktop-config change on the primary, and `pacman -Syu`
  inside the rescue OS occasionally.
- Upstream: watch PR #1364; the `DRY_RUN_TIMEOUT_MS` PR only if the user says go (item 5).

## Commands worth remembering
- Queue: `nomad-downloads` (`retry|cancel|rm <jobId>`); admin API is unauthenticated on localhost.
- Kiwix: `curl -s localhost:8080/api/zim/curated-categories | jq '.[] | {slug, installedTierSlug}'`.
- Kolibri tasks (needs a session): login `POST /api/auth/session/` `{username,password,facility}`,
  then `X-CSRFToken` from the `kolibri_csrftoken` cookie; imports are
  `POST /api/tasks/tasks/ {"type":"kolibri.core.content.tasks.remoteimport","channel_id","channel_name"}`.
- Kiwix mirrors when `download.kiwix.org` throttles: `https://laotzu.ftp.acc.umu.se/mirror/kiwix.org/zim/…`
  (~95 MB/s seen), `https://ftp.fau.de/kiwix/zim/…`; download with
  `POST /api/zim/download-remote {url, metadata:{title}}` — bookkeeping keys on the filename.
- MySQL one-off: `sudo docker exec -i nomad_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" nomad' <<EOF … EOF`.
