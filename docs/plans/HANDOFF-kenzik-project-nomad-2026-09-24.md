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
   2026-09-24 08:00: the primary has loaded the new image archive (`images.generation` now
   `20260924T112953Z`, item 1 fully closed) and `qwen3.5:35b-a3b` is pulled (see "AI model").
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
- **AI model** (2026-09-24 07:57): `qwen3.5:35b-a3b` (Q4_K_M, 23 GB, MoE 36B/3B-active, 256K
  context, capabilities completion/vision/tools/thinking) pulled by the user into
  `/mnt/nomad/ollama/models`, so both OSes see it. On the primary (Vulkan, RADV): 42/42 layers on
  the GPU, 21.2 GiB model buffer, KV only 640 MiB at the 32768 default context (hybrid attention),
  ≈10 GiB headroom of the 32.2 GiB budget; NOMAD's RAG bump to `num_ctx` 65536 still fits, so open
  item 7 (GTT tuning) is unnecessary for this model. Measured via the API with `think:false`:
  prompt eval 341 tok/s on a 3.2K-token prompt, generation 17 tok/s (11 tok/s on a first short
  call). iGPU was at full clocks (sclk 2885 MHz, mclk 2800 MHz, 99 % busy) during the test. The
  chat picker selects the model per session (no server-side default); `qwen3:0.6b` and
  `nomic-embed-text:v1.5` (NOMAD's RAG embedding model, auto-pulled) are the other two models.
  Why this one: on a bandwidth-bound iGPU a 3B-active MoE generates 2–3× faster than a dense
  9–12B while carrying 36B of knowledge; NOMAD's RAG tier keys on the reported 36B, so it gets the
  full 5 chunks uncapped; `gpt-oss:20b` was the runner-up (smaller, but stricter refusals on
  medical/survival topics and weaker recall). Measured while the KB indexer (below) had the GPU
  at 90 %; idle numbers will be higher.
- **Knowledge Base (RAG) indexing** (2026-09-24 08:45): NOMAD embeds every ZIM into Qdrant
  (`nomad_knowledge_base`, `storage/qdrant`) with `nomic-embed-text` — ~1,450 chunks/min on the
  890M, two workers, `llama-server` at ~4.7 cores; this is what "cranks" on the box. It had been
  running since the ZIMs landed on 09-23: 31 ZIMs (27.8 GB) → 83 k vectors, 487 MB. The queue
  still held `wikipedia_en_all_maxi` (124 GB → weeks of GPU and ~100 GB+ of vectors, more than
  RAM) and the two multilingual TED ZIMs (24 GB). Done via the admin API (all on localhost):
  `rag.defaultIngestPolicy` → `Manual` (no auto-queue of future ZIMs), `DELETE /api/rag/jobs`
  (42 jobs, no files deleted), then `POST /api/rag/files/embed {source, force}` for 24 ZIMs +
  the 12 NOMAD docs `.md` (their earlier failures predate the AI Assistant install), medical
  first. Deliberately NOT queued: `wikipedia_en_all_maxi`, `ted_mul_ted-conference`,
  `ted_mul_ted-ed`, `wikibooks_en_all_nopic` (same text as the queued `_maxi`), and the two
  `canadian-prepper_en_*_2026-08` entries (the KB tracks the new filenames, which do not exist
  on disk while open item 3's rename is in place; queue them after the rename-back). The two
  jobs that were mid-flight (`gutenberg_en_lcc-u` 81 %, `medlineplus` 2 %) were re-queued with
  `force:true` because chunk ids are random UUIDs — a plain re-queue would have duplicated the
  already-embedded part. With policy Manual, new ZIMs need `POST /api/rag/files/embed` (or the
  Knowledge Base UI) to be indexed; `GET /api/rag/active-jobs`, `/api/rag/files`
  (`state`/`chunksEmbedded` per file) and `/api/rag/failed-jobs` show progress.
  User decision 2026-09-24: the two TED ZIMs stay installed (one video + ~25 subtitle tracks per
  talk; the Spanish text is subtitles, not separable) — do not propose removing them again.

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
   Not needed for `qwen3.5:35b-a3b` (10 GiB headroom); only if a >26 GiB model is wanted.
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
- AI model follow-ups (model itself done, see "AI model" above):
  - Vulkan vs ROCm throughput: the rescue OS runs Ollama on ROCm (gfx1150) against the same model
    files; boot it once and run the benchmark one-liner below for a direct comparison. If ROCm is
    clearly faster, add `rocm` to `GPU=` in `/etc/nomad-host.conf` on the primary and re-run the
    bootstrap (`ollama-rocm` package). Also `powersave` EPP governor on the primary is untested vs
    `performance` for the CPU-side share (small for this model).
  - Query-rewrite/title/suggestion helper calls reasoning at length with a thinking model
    (v1.34.1: `ollama_controller.ts:480` passes neither `think` nor `thinkingCapable`) is
    **already fixed upstream**: `4acfef5` "fix(AI): stop <think> output leaking into titles,
    chips, and the RAG query (#1254)", 2026-08-18, first tag `v1.35.0-rc.1`; on `dev` the helpers
    now live in `chat_service.ts` and `rag_pipeline_service.ts` and pass `think:false` plus the
    memoised capability. No PR needed (checked 2026-09-24). The appliance runs stock v1.34.1
    images and picks it up with the v1.35.0 update; until then follow-up turns pause for the
    rewrite's thinking with `qwen3.5:35b-a3b`.
  - `qwen3:0.6b` can be deleted (Settings → Models) — no role once the real model is in.
- `build-backup-os.sh --refresh` after any desktop-config change on the primary, and `pacman -Syu`
  inside the rescue OS occasionally.
- Upstream: watch PR #1364; the `DRY_RUN_TIMEOUT_MS` PR only if the user says go (item 5).
- Network plan (user, 2026-09-24): a GL.iNet Beryl AX in **Router mode** goes between the X1 Pro
  and the main LAN (X1 Pro on the Beryl's 192.168.8.0/24 behind NAT); Tailscale on the X1 Pro for
  access whenever it has internet, nothing needed off-grid. Consequences once that happens:
  `nomad.local`/`10.0.10.186` stop working from the main LAN — use the MagicDNS name or 100.x
  address in `~/.ssh/config` (`Host nomad`/`nomad-rescue`; host keys unchanged) and in scripts from
  the daily driver; on the Beryl's own Wi-Fi mDNS still works. Firewall facts: ufw is active with
  `22/tcp` allowed from anywhere, so SSH over `tailscale0` passes; `:8080` and the app ports are
  Docker-published (bypass ufw) and reachable over Tailscale in `nomad-expose lan`, blocked in
  `local` (DOCKER-USER rule keys on `! -i br-nomad`); Ollama 11434 stays br-nomad-only. Tailscale
  is `extra/tailscale` (1.102.4 today); it is NOT in `build-pkgcache.sh`'s list nor in
  `build-backup-os.sh`'s pacstrap set — add both (and an opt-in in `bootstrap-host.sh`) if the
  rescue OS should carry it too; each OS is its own tailnet node.

## Commands worth remembering
- Queue: `nomad-downloads` (`retry|cancel|rm <jobId>`); admin API is unauthenticated on localhost.
- Knowledge Base: `nomad-kb` (status), `nomad-kb files [indexed|pending|failed]`, `nomad-kb failed`,
  `nomad-kb queue <file> [-f]`, `nomad-kb sync`, `nomad-kb cancel-all`. Added to the toolkit
  2026-09-24 after `495fd39`; **not yet installed on either OS** — `git pull` on the X1 Pro, then
  `sudo bash install/cachyos/bootstrap-host.sh` with the flags from `/etc/nomad-host.conf`
  (primary: `--autostart --expose=lan --gpu=vulkan --yes`), which also refreshes the drive copy;
  the rescue OS from its own checkout or the drive copy. Until then run it as
  `ssh nomad bash -s status < install/cachyos/nomad-kb` from the daily driver.
- Kiwix: `curl -s localhost:8080/api/zim/curated-categories | jq '.[] | {slug, installedTierSlug}'`.
- Kolibri tasks (needs a session): login `POST /api/auth/session/` `{username,password,facility}`,
  then `X-CSRFToken` from the `kolibri_csrftoken` cookie; imports are
  `POST /api/tasks/tasks/ {"type":"kolibri.core.content.tasks.remoteimport","channel_id","channel_name"}`.
- Kiwix mirrors when `download.kiwix.org` throttles: `https://laotzu.ftp.acc.umu.se/mirror/kiwix.org/zim/…`
  (~95 MB/s seen), `https://ftp.fau.de/kiwix/zim/…`; download with
  `POST /api/zim/download-remote {url, metadata:{title}}` — bookkeeping keys on the filename.
- MySQL one-off: `sudo docker exec -i nomad_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" nomad' <<EOF … EOF`.
- Ollama benchmark (non-root, on the X1 Pro): build a ~3K-token prompt and read the rates —
  `P="$(yes 'The quick brown fox jumps over the lazy dog near the river bank at dawn.' | head -160 | tr '\n' ' ') Summarize in one sentence."; jq -n --arg p "$P" '{model:"qwen3.5:35b-a3b",prompt:$p,stream:false,think:false,options:{num_predict:40}}' | curl -s localhost:11434/api/generate -d @- | jq '{prompt_tps:(.prompt_eval_count/(.prompt_eval_duration/1e9)|floor), gen_tps:(.eval_count/(.eval_duration/1e9))}'`.
  Offload check: `sudo journalctl -u nomad-ollama -b | grep -E 'offloaded|model buffer size'`.
