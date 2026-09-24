# HANDOFF — Project N.O.M.A.D. on the X1 Pro (as of 2026-09-24)

Supersedes `HANDOFF-kenzik-project-nomad-2026-09-23.md` (kept for the history of how each item was
found and fixed). Design: `PLAN-kenzik-project-nomad-init.md`. Runbook: `install/cachyos/README.md`.

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
- Content on the datastore (512 GB used of 3.4 TB): Wikipedia `all-maxi` (124 GB), all six Kiwix
  categories at `*-comprehensive` (62 ZIMs, 214 GB total), FDA drug reference (262,880 labels),
  nine US map collections + `north-america_20260924_z15.pmtiles` (35 GB) +
  `south-america_20260924_z15.pmtiles` (8.5 GB), Kolibri: all 43 English public Studio channels
  (250 GB). Kolibri facility "Home Facility for dkenzik", superuser `dkenzik` (password was a
  temporary one — user to change it).
- Apps installed by the user in the Supply Depot besides kiwix/kolibri/qdrant: cyberchef,
  excalidraw, it_tools, jellyfin, meshcore_web, stirling_pdf, vaultwarden. `installed-services.txt`
  lists all ten; the rescue OS adopted the seven new ones on 2026-09-24 07:25 (online pull).

## Open items
1. **Offline image archive is stale**: `docker-images/GENERATION 20260923T185117Z`, 9 images; the
   seven new apps are not in it. Run `sudo bash /mnt/nomad/host-bootstrap/toolkit/save-images.sh`
   (either OS) → expect 16 images in `IMAGES.txt`. Re-run after every app install/update.
2. **`build-pkgcache.sh`** should be re-run once (adds `jq` to the offline pkgcache).
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
