# MeshCore terminal client for Linux/macOS: research report

Date: 2026-09-28. Scope: keyboard-driven terminal client for MeshCore direct messages and channels, driven over USB serial (RAK4631 companion_radio_usb v1.17.1, fw_ver 13; ThinkNode M9 Wadamesh beta_85, fw_ver 27), usable over ssh, on CachyOS/Arch and macOS.

## 1. Recommendation

Adopt, do not build. Three maintained full-screen TUIs exist, all Python on top of the official `meshcore` library (meshcore_py, MIT, v2.3.14 released 2026-09-19), and all four candidate tools were test-installed into a scratch Python 3.14.7 venv on this machine with `uv` and imported cleanly (pycryptodome resolves via its `cp37-abi3` wheel, so the "no 3.14 wheels" worry does not apply).

Evaluate in this order, one afternoon total:

1. **meshssi** (dmellok, AGPL-3.0, v0.4.2 released 2026-09-28). irssi-style windows per channel/DM, persistent scrollback per node, DM ack/RTT markers, tab completion, notifications, and a `--serve` daemon that owns the serial port and re-serves it to multiple meshssi instances on `127.0.0.1:5001`. Closest match to the stated wants (keyboard-first, channels + DMs, ssh/tmux friendly, radio sharing). Risks: three weeks old, one author, 5 stars, no PyPI release (install from GitHub), AGPL.
2. **MeshTerm** (jpmartineau, Apache-2.0, v0.10.1 released 2026-09-27). Most polished and the only one shipping single-file binaries (PyInstaller; linux x64/arm64 38 MB, macOS arm64/x64 21 MB). Rich/prompt_toolkit menu UI, chat transcript with pinned input, SQLite history, courier store-and-forward, plus dashboard/map/trace screens the user does not need. Heavier terminal requirements (emoji, braille, powerline glyphs). First public release 2026-09-22; 865 commits, one author.
3. **meshtui** (ekollof, MIT, PyPI 0.2.11, 2026-08-14). Textual chat client with per-device SQLite history, delivery tracking with retry/flood fallback, channel management, Linux D-Bus notifications, and an experimental `meshcore-tcp-proxy` (serial to TCP, naive broadcast). Older and quieter (no commits since 2026-08-18; 8 open issues), but the most conventional "chat app" layout.

Fallback that works today with zero evaluation: `meshcore-cli` chat mode (`meshcli -s /dev/ttyACM0`), a prompt_toolkit line REPL with `to <contact|channel>`, incoming messages printed inline, `!` prompt marker for unacked sends. Not full-screen, no on-disk message history.

Install story that respects "nothing on the host": `uv` is in the Arch `extra` repo (0.12.13) and already at `~/.local/bin/uv` on paradigm; on macOS `brew install uv`. Then `uv tool install --python 3.12 meshtui` (or `meshssi@git+https://github.com/dmellok/meshssi`), which keeps everything under `~/.local/share/uv` and needs no pip. MeshTerm needs nothing but its binary.

Effort if building anyway: Python + `meshcore` + Textual, DMs/channels/contacts/SQLite/ack tracking: 5 to 8 days to reach where meshtui is now. Go (meshcore-go v1.6.0 exists, no BLE) or Rust (meshcore-rs, 0.1, 0 stars) with a fresh TUI: 10 to 15 days, more if BLE is wanted. None of that buys anything the three existing clients lack except a static binary, which MeshTerm already provides.

If the decision is to build regardless (a specific feel, a tiny dependency surface, or a tool that ships inside the NOMAD toolkit), section 3a lays out the POSIX C and Rust routes. Short version: Rust with ratatui + crossterm + tokio-serial + rusqlite (bundled) as the default; C with ncursesw + termios + poll + SQLite if the smallest host footprint and readability outrank terminal-layer effort. Serial + TCP transports only; no BLE.

## 2. Existing tools

Stars/dates from the GitHub API on 2026-09-28. "Proto" = how the companion protocol is implemented.

| Tool | Kind | Lang / UI | Transports | DMs / channels / history / notify | Proto | Stars, last push, latest release | License | Install |
|---|---|---|---|---|---|---|---|---|
| [meshssi](https://github.com/dmellok/meshssi) | full TUI, irssi-style | Python 3.11+, Textual >=0.80 | serial, BLE, TCP; `--serve` daemon | yes / yes / per-node scrollback in `~/.local/share/meshssi` / desktop + mention highlight | `meshcore>=2.3` | 5, 2026-09-28, v0.4.2 (2026-09-28) | AGPL-3.0 | `uv tool install git+...`, `install.sh`, no PyPI |
| [MeshTerm](https://github.com/jpmartineau/MeshTerm) | full TUI + scripted CLI | Python 3.10+, Rich + prompt_toolkit | serial (`--port`), BLE, TCP (`--tcp host[:5000]`), SPI | yes / yes / SQLite in `~/.meshterm` / not documented | `meshcore>=2.3` | 33, 2026-09-28, v0.10.1 (2026-09-27) | Apache-2.0 | single binaries for linux/macOS/win; `pip install git+`; PyPI pending |
| [meshtui](https://github.com/ekollof/meshtui) | full TUI | Python 3.10+, Textual | serial (`-s`), BLE (`-a`), TCP (`-t`, port 5000); TCP proxy extra | yes / yes (slots 1-7, `#name` hash secrets or 32-hex) / per-device SQLite `~/.config/meshtui/devices/<pubkey>.db` / Linux D-Bus | `meshcore>=2.1.9` | 42, 2026-08-18, 0.2.11 on PyPI (2026-08-14) | MIT | `pipx`/`uv tool install meshtui`; PKGBUILDs in repo (AUR `meshtui` is a different Meshtastic tool) |
| [meshcore-cli](https://github.com/meshcore-dev/meshcore-cli) | line REPL "chat mode" + scripting | Python 3.10+, prompt_toolkit | serial, BLE, TCP | yes / yes / none on disk / `!` prompt marker | `meshcore>=2.3.11` | 201, 2026-09-23, 1.6.4 (2026-09-16) | MIT | `pipx install meshcore-cli`, nix flake, AUR `meshcore-cli-git` |
| [QTC](https://github.com/initsixdev/QTC) | TUI with detachable background core | C11 + SQLite | serial only | yes / yes / SQLite / desktop + sound | own C impl. | 11, 2026-08-08, v1.0.0 (2026-08-07, linux x86_64 binary; macOS build from source) | GPL-3.0 | binary or `make` |
| [tui-meshcore](https://github.com/guax/tui-meshcore) | TUI for a bare LoRa HAT via pyMC_core | Python, Textual | SPI radio, not a companion | n/a for this use | pyMC_core | 21, 2026-02-14, no release | GPL-3.0 | git clone |
| [MeschaTUI](https://github.com/g-d-j-evans/MeschaTUI) | learning project | Python, Textual | serial, BLE | yes / yes / unified log / toasts | meshcore_py | 0, 2026-04-22, none | none | git clone |
| [meshcore.js](https://github.com/liamcottle/meshcore.js) | library only | JS | Web BLE/Serial, Node TCP/serial | no CLI shipped | own | 49, 2026-09-07 | MIT | npm |
| [meshcore-go](https://github.com/meshcore-go/meshcore-go) | library (tracks fw 1.17.1) | Go | serial, TCP; no BLE | no client | own, "58 commands, 29 responses, 17 pushes" | 16, 2026-09-26, v1.6.0 | MIT | `go get` |
| [meshcore-rs](https://github.com/cammeresi/meshcore-rs) | library, port of meshcore_py | Rust, tokio | serial, TCP, optional BLE (btleplug) | examples only | own | 0, 2026-09-27, crate 0.1 | MIT | cargo |

Radio-sharing helpers:

| Tool | What | Notes |
|---|---|---|
| meshssi `--serve` | serial/BLE upstream, TCP 127.0.0.1:5001 downstream | serializes requests, fans pushes out, shared message log; only meshssi clients (README) |
| meshtui `meshcore-tcp-proxy` | serial upstream, TCP 5000 | "no protocol translation": every device frame is broadcast to all clients and client commands are forwarded unarbitrated (`proxy.py`, `tcp_server.py`); marked experimental, bug #11 open |
| [rgregg/meshcore-proxy](https://github.com/rgregg/meshcore-proxy) | serial or BLE upstream, TCP 5000, Python, Docker image `ghcr.io/rgregg/meshcore-proxy` | 46 stars, last push 2026-03-26, v0.4.0; multi-client behaviour not documented |
| [compumike/meshcore-tcp-mux](https://github.com/compumike/meshcore-tcp-mux) | protocol-aware mux, TCP upstream only, Crystal static binary / Docker | 3 stars, 2026-09-19; keeps a per-client inbox so each client gets every incoming message; cannot see peers' outgoing messages (protocol has no such event) |
| ser2net / socat | raw serial to TCP | TCP framing is byte-identical to serial framing (`<`/`>` + LE16 length; meshcore_py `tcp_cx.py`), so a raw bridge works for one client at a time; MeshMonitor docs recommend ser2net on port 5000 |

Nothing exists in Go or Rust with a TUI; searches for "meshcore ratatui/bubbletea" returned only the Python projects. [awesome-meshcore](https://github.com/samuk/awesome-meshcore) lists the same set under "Terminal UI".

## 3. Approach comparison (if building)

| | (a) Python + `meshcore` + Textual | (b) Go + own protocol + Bubble Tea | (c) Rust + ratatui + serialport | (d) TS + meshcore.js + Ink |
|---|---|---|---|---|
| Distribution | `uv tool install` (uv fetches its own CPython; verified on 3.14.7); PyInstaller binary if wanted (MeshTerm proves it, 21-38 MB) | true static binary, trivial cross-compile | static binary; BLE via btleplug is heavy | needs Node runtime, or `bun build --compile` |
| Protocol maintenance | zero: meshcore_py is the reference lib (meshcore-dev org), released 3 times on 2026-09-19 alone | meshcore-go tracks 1.17.1 but is a one-org project (16 stars); pushes >0x8A are yours to follow | meshcore-rs is 0.1/0 stars; effectively fresh code | meshcore.js has 19 open issues, no CLI examples |
| Serial / BLE / TCP | all three (bleak works on Linux BlueZ and macOS) | serial + TCP only | serial + TCP, BLE optional | Node: serial + TCP |
| Persistence | sqlite3 stdlib | modernc sqlite or bolt | rusqlite | better-sqlite3 (native build) |
| ssh/tmux | Textual is fine with `TERM=xterm-256color`/`tmux -T` | fine | fine | fine |
| Radio sharing | reuse meshssi daemon / tcp-mux | write a mux | write a mux | write a mux |
| Effort to parity with meshtui | 5-8 days | 10-15 days | 12-18 days | 8-12 days |

The single-binary argument for Go/Rust is real but already satisfied by MeshTerm's binaries, and `uv tool install` on Arch/macOS is a one-package host footprint. Protocol drift is the recurring cost: MeshCore added frame size 176, 6-byte acks, anon requests and raw packets in v1.16 (June 2026), region scopes and multi-interface companions in v1.17; meshcore_py absorbs these, a fresh Go/Rust implementation would not.

Sharing the radio with the GUI: the Chromium Web Serial path cannot be shared at all (the browser holds the port). A serial-to-TCP daemon fixes this only if the GUI can speak TCP: the official Liam Cottle app has Wi-Fi/TCP on Android/iOS since v1.11 (May 2025) and "standalone linux builds with wifi/tcp" since v1.37 (Jan 2026); the browser build cannot open raw TCP. MeshCore Open (Flutter, MIT, 622 stars) supports TCP on Linux and macOS desktop. So the workable topology is: one daemon owns `/dev/ttyACM0` and listens on TCP 5000; TUI and a desktop GUI both connect over TCP. Of the daemons above, only compumike/meshcore-tcp-mux is protocol-aware for arbitrary clients (chained behind ser2net or meshcore-proxy because it wants a TCP upstream); meshssi's daemon is the simplest if the only clients are meshssi.

## 3a. Rolling our own: POSIX C and Rust

The protocol side is small in any language. The companion device does all cryptography (identity, DM encryption, channel keys are 16 opaque bytes handed to the device), so a client is: frame codec (`<`/`>` + LE16 length), a state machine (contacts, channels, sync loop, acks, pushes), a message store, and a UI. Neither language changes that. What differs is the terminal layer and the distribution story.

### POSIX C

| Framework | What it gives | What you carry | Availability |
|---|---|---|---|
| **ncursesw** | Windows, pads, colors (256 + optional true color via `init_extended_color`), key input, resize signal. Stable for decades. | Unicode display widths (`wcwidth`, emoji are double-width and often wrong in the terminal's own table), input decoding for modifiers, scrollback and wrapping, all widgets. Must link the wide-char build (`-lncursesw`). | Base system on every Linux; macOS ships it (older 5.7 API, adequate) and Homebrew has current. |
| **notcurses** (nick-black) | True color, Unicode widths and grapheme handling done, planes with z-order, a real input layer with modifiers, direct mode for line-oriented use. | A runtime dependency users must install; the API moves faster than ncurses; heavier build (libunistring, libdeflate). | Arch `extra`, Homebrew. Not in the base system anywhere. |
| **termbox2** | Single header: a cell grid, 256/true color, key and mouse events, resize. Tiny and readable. | Everything above the cell grid: windows, scrolling, wrapping, widths. | Vendored header; no package needed. |
| **libtickit** | Middle ground: windows, expose/rerender model, Unicode-aware, used by neovim's terminal work. | Small community; packaging is thin (AUR only on Arch, not in Homebrew). | Vendored or built from source. |

Supporting pieces already in the base system: `termios` for the serial port, `poll` for the loop over serial fd + stdin + a timer fd (or `kqueue`/`select` on macOS; `poll` is portable to both), SQLite's C API for history (`-lsqlite3`, present on macOS and every Linux). No JSON, no crypto, no threads required.

Shape of the program: one `poll` loop; a frame decoder that appends serial bytes to a ring buffer and emits payloads; a dispatch table by response code; a model (contacts array keyed by pubkey prefix, channels, per-conversation message lists backed by SQLite); ncurses redraw on model change or resize. Roughly 3 to 4 thousand lines of C for parity with meshtui.

Effort: 10 to 15 days. The terminal layer, not the protocol, is where the days go: wide-character handling, resize races, input sequences from different terminals over ssh/tmux, and scrollback. notcurses cuts that by several days at the cost of the dependency.

### Rust

| Framework | What it gives | Notes |
|---|---|---|
| **ratatui + crossterm** | Immediate-mode widgets (paragraph with wrapping, list, table, scrollbars, layout constraints), Unicode widths handled (`unicode-width`), true color, resize and key/mouse events from crossterm on Linux and macOS. The de-facto stack for new Rust TUIs; large ecosystem of examples. | Immediate mode means you own app state and redraw each tick; fine for a chat client. |
| **cursive** | Retained widgets, dialogs, layouts, focus handling, ncurses or crossterm backends. Fastest path to a working chat screen. | Less control over look and per-cell rendering; smaller community than ratatui. |
| **tuirealm**, **iocraft** | Component/React-style layers over ratatui. | Extra abstraction; not needed for one screen and a sidebar. |

Supporting crates: `serialport` (sync) or `tokio-serial` (async) for the port, `tokio` for the event loop (serial reader task, stdin/event task, timers, a TCP listener if the client also acts as the bridge), `rusqlite` with the `bundled` feature so SQLite is compiled in, `bytes` for framing, `directories` for config paths. Optional later: `btleplug` for BLE (works on Linux BlueZ and macOS CoreBluetooth, but pulls in a lot; keep out of scope).

Shape: `cargo` workspace with a `meshcore-proto` crate (codec + typed commands/responses + tests against captured frames) and a `meshcore-tui` binary. The proto crate is reusable for a headless bridge/daemon binary later. Roughly 4 to 6 thousand lines for parity with meshtui.

Effort: 7 to 12 days. Distribution: `cargo build --release` gives one binary per platform with no runtime dependencies; cross-compiling for macOS from Linux needs the Apple SDK and is not worth it, so build on a Mac or in CI (GitHub Actions has macOS runners). Arch packaging via a PKGBUILD in the NOMAD toolkit is straightforward.

### Recommendation if building

1. **Default: Rust, ratatui + crossterm, tokio + tokio-serial, rusqlite bundled.** It removes the whole class of terminal-layer bugs, gives a single static binary on both platforms, and the proto crate doubles as the base for a serial-to-TCP bridge that lets the desktop GUI and the TUI share nomad's radio.
2. **C, ncursesw + termios + poll + SQLite** if the smallest host footprint and code readability outrank the terminal-layer effort, or if the tool should live in `install/cachyos/` next to the existing shell scripts with only the base system as a dependency. Prefer ncursesw over notcurses so the binary depends on nothing the host lacks; accept plainer visuals.
3. **Scope for a first cut**, either language: serial + TCP transports; contacts list with adverts and last-seen; DMs with ack/round-trip markers and retry; channels (public + configured); sync loop (`PUSH_CODE_MSGS_WAITING` → `CMD_SYNC_NEXT_MESSAGE` until empty); SQLite history per node key; send-advert command; radio settings read and set. Out of scope: BLE, maps, GPS, firmware updates, repeater admin.
4. **Protocol maintenance** is the recurring cost either way. Pin to `FIRMWARE_VER_CODE` 13 (v1.17.x), send `app_target_ver` 3 in `CMD_DEVICE_QUERY`, handle both 4- and 6-byte ack widths, and keep a frame-capture test corpus from the RAK4631 and the Wadamesh M9 (fw_ver 27) so upgrades are caught by tests rather than in the field.
5. **Do the daemon first** regardless of language if the Chromium workaround is to go away: a bridge that owns `/dev/ttyACM0` and serves TCP 5000 is a few hundred lines and immediately lets MeshCore Open or the official desktop app connect from the laptop while the TUI develops.

## 4. Protocol notes

Primary sources: [MyMesh.cpp](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp) / [MyMesh.h](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.h) on `main` (`FIRMWARE_VER_CODE 13`, matching the RAK's fw_ver 13), the [Companion Radio Protocol wiki](https://github.com/meshcore-dev/MeshCore/wiki/Companion-Radio-Protocol) (updated 2026-04-11, the most complete layout reference), [docs.meshcore.io/companion_protocol](https://docs.meshcore.io/companion_protocol/) (BLE-centric, updated 2026-03-08, partial), and meshcore_py `reader.py`, `commands/device.py`, `commands/messaging.py`.

Everything observed by the parent session matches `main`:

- Framing: host to device `<` + LE16 len + payload; device to host `>` + LE16 len + payload; identical over TCP (`tcp_cx.py`); frames over 300 bytes rejected by the lib; firmware max frame 176 since v1.16.
- `CMD_DEVICE_QUERY` (22): byte 1 is `app_target_ver`, "which version of protocol does app understand". meshcore_py sends `16 03`, i.e. it asks for protocol 3. `RESP_CODE_DEVICE_INFO` (13): fw_ver, then for fw_ver>=3 max_contacts/2, max_channels, ble_pin u32, build[12], model[40], version[20]; fw_ver>=9 repeat-enabled byte; fw_ver>=10 path_hash_mode. The only firmware-side gate is `if (app_target_ver >= 3)`; everything else is additive fields. Wadamesh's fw_ver 27 should parse (meshcore_py gates on >=3/9/10 and ignores trailing bytes) but this was not tested.
- `CMD_APP_START` (1): meshcore_py sends `01 03` + 6 spaces + `mccli`; reply `RESP_CODE_SELF_INFO` (5): type, tx_power, max_tx_power, pubkey[32], lat i32, lon i32, multi_acks, advert_loc_policy, telemetry_modes, manual_add_contacts, freq u32 (kHz), bw u32, sf, cr, name.
- Contacts: `CMD_GET_CONTACTS` (4) with optional `since` u32; `RESP_CODE_CONTACTS_START` (2) carries total count u32; `RESP_CODE_CONTACT` (3) is the 148-byte layout in the task brief (`writeContactRespFrame`); `RESP_CODE_END_OF_CONTACTS` (4). Add from advert: with `manual_add_contacts=0` the firmware auto-adds and pushes `PUSH_CODE_ADVERT` (0x80, 32-byte pubkey); with `=1` it pushes `PUSH_CODE_NEW_ADVERT` (0x8A) carrying a full contact frame that the app echoes back as `CMD_ADD_UPDATE_CONTACT` (9): pubkey[32], type, flags, out_path_len, out_path[64], name[32], last_advert u32, optional lat/lon. `PUSH_CODE_CONTACT_DELETED` 0x8F and `PUSH_CODE_CONTACTS_FULL` 0x90 are recent additions.
- Direct message: `CMD_SEND_TXT_MSG` (2): txt_type (0 plain, 1 CLI, 2 signed), attempt, sender_timestamp u32, pubkey prefix[6], text. Reply `RESP_CODE_SENT` (6): byte 1 = 1 if flood else 0, expected_ack u32, est_timeout u32 ms. Ack arrives as `PUSH_CODE_SEND_CONFIRMED` (0x82): ack u32 + round-trip u32 ms (9-byte frame in `main`; the v1.16 notes mention 6-byte acks "for extended attempt numbering", which I could not reconcile with the current source, so treat ack width as something to check at runtime). `path_len` 0xFF in received frames means direct (not flooded); `CMD_RESET_PATH` (13) forces the next send to flood. The firmware keeps `EXPECTED_ACK_TABLE_SIZE` entries and clears an entry on first match.
- Receive/sync: on a received message the firmware appends the pre-built response frame to an in-RAM `offline_queue` (`OFFLINE_QUEUE_SIZE` 16; when full the oldest channel message is dropped) and, if a host is connected, sends a 1-byte `PUSH_CODE_MSG_WAITING` (0x83). The host loops `CMD_SYNC_NEXT_MESSAGE` (10) until `RESP_CODE_NO_MORE_MESSAGES` (10). With app_target_ver>=3 the replies are `RESP_CODE_CONTACT_MSG_RECV_V3` (16): snr i8 x4, 2 reserved, prefix[6], path_len, txt_type, sender_ts u32, [sig 4 if txt_type 2], text; and `RESP_CODE_CHANNEL_MSG_RECV_V3` (17): snr, 2 reserved, channel_idx, path_len, txt_type, ts, text. Older apps get codes 7/8 without the SNR header. The queue is not persisted to flash, so the client owns history; meshcore_py's `start_auto_message_fetching()` implements the loop and emits `CONTACT_MSG_RECV`/`CHANNEL_MSG_RECV` events.
- Channels: `CMD_SEND_CHANNEL_TXT_MSG` (3): txt_type (must be 0), channel_idx, ts u32, text; reply is `RESP_CODE_OK`, no ack (channel sends are flood only, "no acknowledgement on a channel"). `CMD_GET_CHANNEL` (31) / `CMD_SET_CHANNEL` (32): idx, name[32], secret[16]; 32-byte secrets return `ERR_CODE_UNSUPPORTED_CMD`. Reply `RESP_CODE_CHANNEL_INFO` (18). Public channel is index 0 with a fixed key; app-side conventions (hash of `#name` for a shared secret, `meshcore://` links) live in the clients, not the firmware.
- Other pushes seen: 0x81 `PATH_UPDATED` (pubkey), 0x88 `LOG_RX_DATA` (RF packet log, emitted when the rx-log telemetry mode is on). Time: `CMD_GET_DEVICE_TIME` (5) / `CMD_SET_DEVICE_TIME` (6) epoch u32; clients normally push host time on connect because the companion has no battery-backed RTC. BLE: the PIN is exposed in DEVICE_INFO and set with `CMD_SET_DEVICE_PIN` (37); meshcore_py's `create_ble(addr, pin=...)` handles pairing. Full command table (1..65) and response table (0..28) are in `MyMesh.cpp` lines 6-135.

meshcore_py wraps all of this: `create_serial/create_ble/create_tcp`, `commands.send_msg`, `send_msg_with_retry` (waits for the ack event), `send_chan_msg`, `get_channel/set_channel`, `get_contacts(since)`, `add_contact`, `get_msg`, and an event dispatcher with attribute filters; `reader.py` parses DEVICE_INFO per fw_ver, both v2 and v3 message frames, and pushes up to 0x90.

## 5. Risks and open questions

- Bus factor: meshssi and MeshTerm are one-person projects that first shipped this month; meshtui has been idle since August. Any of them could stall; the mitigation is that all sit on meshcore_py, so patches are small.
- meshssi's daemon only serves meshssi; sharing with a GUI needs tcp-mux behind a serial bridge, which is three processes for one radio. Not tested here.
- meshtui's proxy broadcasts every response to every client; two active clients will see each other's command replies and both consume the same SYNC_NEXT_MESSAGE stream. Treat it as single-client.
- Notifications over ssh: meshtui's are D-Bus (local only); meshssi says "desktop alerts when unfocused" (mechanism over ssh unverified); MeshTerm documents none. A terminal bell or tmux `monitor-activity` may be the practical answer.
- MeshTerm's glyph requirements (emoji, braille, powerline) will look wrong in plain xterm or macOS Terminal.app (its own docs say braille misaligns there); test in the actual ssh terminal before committing.
- Wadamesh fw_ver 27 with the M9's own keyboard UI: nothing here was verified against it; the on-device UI and a host client both draining the offline queue is an unknown.
- Ack width (4 vs 6 bytes since v1.16) and the exact `PUSH_CODE_SEND_CONFIRMED` layout on 1.17.1 should be confirmed with one live send; the wiki and `main` say 4+4.
- Not verified: AUR packaging for any of the three TUIs (AUR `meshtui` is PeterGrace's Meshtastic tool; only `meshcore-cli-git` and `python-meshcore-git` exist, the latter with a reported hatchling build failure), Homebrew formulas (none found), and MeshTerm on PyPI (name pending).

NOMAD packaging: the cleanest fit with `install/cachyos/` (bash + stdlib Python) is a `nomad-mesh` wrapper that does `pacman -S --needed uv` and `uv tool install --python 3.12 <client>`, keeping host Python untouched; `udev` uaccess on `/dev/ttyACM0` already covers permissions. A container (`--device /dev/ttyACM0 --group-add uucp`, `docker run -it`) works for a TUI over ssh but adds tty/TERM friction and loses BLE; the better container use is a serial-to-TCP daemon (rgregg/meshcore-proxy publishes an image) with the TUI installed on the host or on the laptop pointing at `nomad:5000` over Tailscale.

## 6. Sources

- meshssi: https://github.com/dmellok/meshssi (README, pyproject, commits, releases v0.4.0-0.4.2)
- MeshTerm: https://github.com/jpmartineau/MeshTerm (README, pyproject, packaging/meshterm.spec, docs/cli.md, docs/features.md, docs/terminals.md, releases); https://meshterm.net/
- meshtui: https://github.com/ekollof/meshtui (README, pyproject, src/meshtui/proxy/*, docs/MESHCORE_TCP_PROXY_DESIGN.md, issues, commits); https://pypi.org/project/meshtui/
- meshcore-cli: https://github.com/meshcore-dev/meshcore-cli (README, pyproject, src/meshcore_cli/meshcore_cli.py imports); https://pypi.org/project/meshcore-cli/
- meshcore_py: https://github.com/meshcore-dev/meshcore_py (README, pyproject, src/meshcore/{tcp_cx,reader,meshcore}.py, commands/{device,messaging}.py); https://pypi.org/project/meshcore/
- MeshCore firmware: https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp and MyMesh.h; releases https://github.com/meshcore-dev/MeshCore/releases (companion-v1.16.0 2026-06-06, v1.17.0 2026-08-09, v1.17.1 2026-08-14); release notes https://blog.meshcore.io/2026/06/06/release-1-16-0 and https://blog.meshcore.io/2026/08/09/release-1-17-0
- Protocol docs: https://github.com/meshcore-dev/MeshCore/wiki/Companion-Radio-Protocol ; https://docs.meshcore.io/companion_protocol/ ; https://docs.meshcore.io/faq/
- Sharing/bridging: https://github.com/compumike/meshcore-tcp-mux ; https://github.com/rgregg/meshcore-proxy ; https://meshmonitor.org/features/meshcore.html (ser2net note)
- GUI clients with TCP: https://github.com/zjs81/meshcore-open ; official app changelog https://app.meshcore.nz/assets/CHANGELOG.md (v1.11.0, v1.37.0, v1.50.0)
- Other clients/libraries: https://github.com/initsixdev/QTC ; https://github.com/guax/tui-meshcore ; https://github.com/g-d-j-evans/MeschaTUI ; https://github.com/liamcottle/meshcore.js ; https://github.com/meshcore-go/meshcore-go and https://pkg.go.dev/github.com/meshcore-go/meshcore-go/companion ; https://github.com/cammeresi/meshcore-rs ; https://github.com/Duncaen/meshcore-rs ; https://github.com/jmpuch/meshcore-cfg ; https://github.com/samuk/awesome-meshcore
- Packaging: https://aur.archlinux.org/packages/meshcore-cli-git ; https://aur.archlinux.org/packages/python-meshcore-git ; https://aur.archlinux.org/packages/meshtui (Meshtastic, unrelated) ; https://docs.astral.sh/uv/concepts/python-versions/ ; https://pypi.org/project/pycryptodome/ (abi3 wheels) ; https://pypi.org/project/textual/ (3.14 classifier)
- Local verification: `pacman -Si uv python-textual python-bleak python-pycryptodome` on this host; `uv venv --python 3.14` + `uv pip install meshtui meshcore-cli git+MeshTerm git+meshssi` in the session scratchpad, all imports succeeded on CPython 3.14.7.
