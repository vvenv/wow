---
name: vanilla-wow-local
description: Set up a local Vanilla WoW 1.12.1 (build 5875) private server on VMaNGOS plus the original Blizzard client running under Wine on Apple Silicon, from nothing to logged-in — sourcing a client data package, extracting server maps/vmaps/mmaps, wiring realmlist, creating an account, and verifying the auth chain. Also covers the client-side layers on top: 1.12-era addons, DLL mods loaded through dlls.txt, and patch-?.MPQ art patches. Use when someone wants to run WoW locally, set up a WoW private server, or asks about VMaNGOS / mangos / realmlist / MPQ extraction / WoWSilicon / 1.12 addons.
---

# Local Vanilla 1.12.1 realm + Wine client

Builds a working local realm and a client that connects to it. Everything runs on the
user's machine; no external hosting.

**Scope is fixed: Vanilla 1.12.1 (build 5875) on VMaNGOS.** Do not re-open this.
AzerothCore does not speak the 1.12 protocol and has no Vanilla branch, so "Vanilla +
AzerothCore" is not a thing; TBC/WotLK are out of scope by choice, not by accident.

**The client is the original Blizzard `WoW.exe` under Wine**, via
[WoWSilicon](https://wowsilicon.github.io/) (free, GPLv3, bundles its own Wine runtime —
no CrossOver, and Whisky was discontinued in April 2025, so ignore guides recommending it).
Native ARM64 *reimplementations* of the client exist and were evaluated; they lose to the
original binary on correctness, which is unsurprising — the original is the reference
implementation. There is no native macOS 1.12.1 build to fall back on: the Mac client of
that era was a PPC + i386 universal binary, and 32-bit Intel stopped running at Catalina.

## Step 1 — Survey the machine

```sh
uname -m && sw_vers                       # arm64 vs x86_64 decides which images work
docker info | grep -E "Server Version|Total Memory"
df -h ~                                   # need ~14 GB free, ~19 GB peak
```

## Step 2 — Start the client-data download early, in the background

It is 5+ GB and everything else can proceed in parallel. **Use `aria2c -x16`, not `curl`** —
on a slow link this was the difference between 3 hours and 25 minutes
(`scripts/fetch-client.sh` wraps it).

See `references/client-data.md` for vetted sources and **how to verify a package before
committing to the download**. Two traps worth knowing up front:

- Many archives are **Windows installers** (`setup-N.bin`, InstallShield), not extractable
  on macOS. Check with `lsar` on the partial file before waiting for a 5 GB download.
- You can read a remote ZIP's central directory with HTTP range requests and inspect its
  file list — and even pull small files like `README`/`SHA256SUMS` out — *before*
  downloading it. `scripts/peek-remote-zip.py` does this.

## Step 3 — Bring up the server while the client downloads

Use [vmangos-deploy](https://github.com/mserajnik/vmangos-deploy) — prebuilt `amd64` **and**
`arm64` images, so nothing is compiled:

```sh
git clone https://github.com/mserajnik/vmangos-deploy.git
cd vmangos-deploy
cp ./config/mangosd.conf.example ./config/mangosd.conf
cp ./config/realmd.conf.example ./config/realmd.conf
cp ./compose.yaml.example ./compose.yaml
```

Then edit `compose.yaml`: set `TZ` on every service. Defaults for image tag (`:5875`) and
realmlist (`127.0.0.1:8085`) are already right for local play. Leave everything else alone —
the README is explicit that undocumented changes are unsupported.

### ⚠️ The conf files are single-file bind mounts — never `sed -i` them

```yaml
- ./config/realmd.conf:/opt/vmangos/config/realmd.conf:ro
- ./config/mangosd.conf:/opt/vmangos/config/mangosd.conf:ro
```

A single-file bind mount is bound to the **inode**. `sed -i` (and anything else that writes
a temp file and renames it over the original) creates a *new* inode, so the container keeps
reading the old, now-unlinked file. The edit appears to have worked and changes nothing,
which is a miserable thing to debug. Edit in place instead:

```sh
python3 - <<'PY'
p = "config/mangosd.conf"
s = open(p).read().replace("Rate.XP.Kill = 1", "Rate.XP.Kill = 2")
open(p, "w").write(s)          # truncate + rewrite, same inode
PY
docker compose restart mangosd
```

### ⚠️ `StrictVersionCheck` and modified binaries

`config/realmd.conf` defaults to `StrictVersionCheck = 1`, which verifies the client
binary's integrity hash against `realmd.allowed_clients` (1.12.1 enUS Win x86 is
`95EDB27C7823B363CBDDAB56A392E7CB73FCCA20`). Any binary that is not byte-identical fails,
which by that mechanism should include `WoW_tweaked.exe` from vanilla-tweaks as well as any
reimplemented client — the reimplementation case is confirmed, the tweaked-exe case is
inferred and has not been re-tested.

Symptom: realmd logs `tried to login with modified client!` and the client says
`Login failed: Version mismatch`. **SRP6 password auth is unaffected**, so this is easy to
misdiagnose as a bad account. `scripts/auth-check.py` separates the two.

This setup runs `WoW_tweaked.exe`, so it keeps `StrictVersionCheck = 0`.

Start the database first so it initialises in parallel:

```sh
docker compose up -d database   # wait for healthy — do NOT interrupt DB creation
docker compose up -d realmd
```

## Step 4 — Extract server data, but split the slow part off

Put the client where the server extractor can see it (`storage/mangosd/client-data/`, with
`Data/` inside), then point the client directory at that **same** copy — see Step 5. One
copy of the MPQs serves both, saving ~5 GB.

The stock `extract-client-data` wrapper runs four steps in sequence and the last one
(`mmap_extract.py`) takes **hours**. Split it:

1. `scripts/02a-extract-maps-vmaps.sh` — maps + vmaps + dbc. **Minutes.** Enough to log in and play.
2. `scripts/02b-extract-mmaps.sh` — mmaps (NPC pathfinding). **Hours.** Run last, in the background.

Notes:

- The extractors are interactive; with stdin at EOF they take defaults, which are correct.
- `02a` deliberately keeps `Buildings/` — `02b` needs it.
- `scripts/04-mmaps-then-restart.sh` waits for `02b`, **verifies output before acting**, then
  restarts `mangosd`. Never restart on an unverified extraction.
- `mmap_extract.py` parallelises **across maps** with `--threads 1` each. Early on it saturates
  every core; at the end only maps 0 and 1 remain, so raising the CPU cap does nothing.
  Cap it while the user plays: `docker update --cpus=6 <container>`.
- **If an art patch (`patch-A.MPQ`) is installed, move it away before re-extracting.** It
  contains `.m2` models and `vmapextractor` reads m2 for collision, so leaving it in changes
  the collision data. See `references/addons-and-mods.md`.

## Step 5 — Install and wire up the client

Full detail in `references/client-wine.md`. The failure modes that cost the most time:

- **Editing `realmlist.wtf` is not enough.** `WTF/Config.wtf` caches a `SET realmList` line
  that **takes precedence**. Third-party client packages ship both pointing at their own
  server. Change both.
- **WoWSilicon's Play button silently no-ops until patching is done** — and the app writes
  no log, produces no stdout even when launched from a terminal, and shows no error. A
  correctly patched game directory has `mods/winerosetta.dll`, `mods/libDllLdr.dll`, a root
  `d3d9.dll`, and `mods/winerosetta.dll` listed in `dlls.txt`.
- **The game directory may be a symlink** into `storage/mangosd/client-data` — Wine handles
  that fine, and it is how the client and server share one copy of the MPQs.
- **Exclusive fullscreen hangs under Wine, and it is the default.** The client rewrites
  `Config.wtf` on exit and drops `gxWindow`/`gxMaximize` entirely, so "it went fullscreen by
  itself" happens on its own. Write `gxWindow "1"` + `gxMaximize "1"` before every launch and
  set `dxvk.allowFse = False`.

```sh
scripts/wowsilicon-setup.sh <game-dir> 127.0.0.1   # realmlist + patches + readiness check
scripts/wowsilicon-launch.sh <game-dir>            # bypass the UI entirely if Play still fails
```

Locale is decided at launch by `SET locale` in `Config.wtf` and cannot be changed in-game,
so a second language means a second game directory with its own `Data/`. The server follows
whatever locale the client reports and sends quest/item/NPC text to match.

Everything the user picks at launch — language, realm address, window mode, resolution —
lives in `Config.wtf`, so **one `.app` wrapper can serve every client directory**: write the
file, then `exec` the launch script. Which *monitor* the game opens on is not in there
(1.12 has no `gxMonitor`), and neither is "give the game its own Space" — both are solved on
the macOS side, with public APIs only; `references/client-wine.md` ranks the four routes.

## Step 6 — Create an account

`docker attach` fails with `cannot attach stdin to a TTY-enabled container because stdin is
not a terminal`. Use `scripts/mangos-console.py`, which allocates a pty and detaches cleanly
with Ctrl-P Ctrl-Q:

```sh
scripts/mangos-console.py "account create <name> <password>" "account set gmlevel <name> 6"
```

## Step 7 — Verify before handing off

Do not stop at "the containers are healthy". `scripts/auth-check.py` is a standalone SRP6
client that proves the whole chain — password, client build acceptance, realm list:

```sh
scripts/auth-check.py <account> <password>
```

Then confirm server-side that the character actually exists:

```sh
docker exec <db-container> mariadb -umangos -pmangos characters \
  -e "SELECT guid,name,level,online FROM characters;"
```

## Step 8 — The layers on top of a working client

Once you can log in there are three independent layers, each with its own rules. All of
them are in `references/addons-and-mods.md`; the headlines:

- **Addons** — only 1.12-era addons work (`## Interface: 11200`). Anything written for
  Classic Era 1.13+ calls APIs that do not exist in 1.12; "load out of date addons" does not
  help. Addons *can* be shared between two client directories by symlinking
  `Interface/AddOns`.
- **DLL mods** — loaded through `dlls.txt` by a code cave patched into `DivxDecoder.dll`,
  **not** by `VanillaFixes.exe`. This layer is **per client directory** and is not shared by
  the addon symlink.
- **Art patches** — `patch-?.MPQ` is a single-character wildcard slot, so `patch-3`..`patch-9`
  and `patch-A`..`patch-Z` all load, later characters winning.

## Troubleshooting index

- `references/client-wine.md` — WoWSilicon install and wiring, realmlist, patching, manual
  launch, window/fullscreen mode, picking which monitor the game opens on, `Config.wtf`
  rewrite rules, verifying the client actually rendered.
- `references/client-data.md` — vetted client packages, how to verify one before downloading,
  disk budget.
- `references/addons-and-mods.md` — addon compatibility rules, the DLL load chain, art patches.

## Diagnostic method that paid off

When something looks broken, prove where it is before changing anything.

- **Check the data before blaming it.** Parse the DBC header (`WDBC`, record/field counts)
  and compare field offsets against the client's own layout. Every "missing asset" chased
  this way turned out to be present and correct.
- **Beware truncated evidence.** `ls -l ... | head -20` sorts alphabetically and cut off
  `spell.dbc`, which briefly looked like a missing file. Grep the full list.
- **Decompose garbage values.** A bogus field read as `1677787136` = `0x64010000` decomposed
  into `[spellId high bytes][state=1][cost low byte=0x64]`, which located a packet parser's
  read offset to the byte. That turns "it's broken" into a filable bug report.
- **Read the server's source to settle who is wrong.** VMaNGOS's `SendTrainerSpellHelper`
  writes 38 bytes/entry in canonical MaNGOS order — which proved the server correct and a
  client's parser wrong.
- **Check the inode, not just the content.** The bind-mount trap above is the same class of
  bug: the file you edited and the file being read were different objects.
- **Ask the binary instead of the internet.** "Can the client be told which monitor to use?"
  was settled in one command — `strings -a WoW_tweaked.exe | grep -oE '^gx[A-Za-z]+$'` lists
  every graphics cvar the build actually has. The same trick answers most "does 1.12 support
  X" questions faster than searching.
- **No screen-recording permission is not the same as no eyes.** An app can always capture
  its own views — `cacheDisplay` / `CALayer.render` are in-process and bypass TCC entirely.
  Wire a signal handler that dumps a PNG, drive a synthetic press with `CGEvent`, and you can
  inspect a pressed-state rendering bug frame by frame. Layout is separately checkable with
  the Accessibility API, which reports every control's frame as numbers.
- **Before blaming your own code, A/B it.** A hidden page rendering the same control six ways
  (bare, wrapped, restyled, and the AppKit original) settled in one screenshot what two rounds
  of blind fixes could not: the defect was in the platform, not the layout.
- **When the app can't be told, tell macOS instead.** The client has no monitor setting and
  no "own Space" setting, but the window it creates is an ordinary Cocoa window: the
  Accessibility API can move it (`AXPosition`) and full-screen it (`AXFullScreen`), and
  macOS creates the Space itself. Reach for the private/SIP-disabling APIs last, not first.
- **A permission that looks granted may not be.** macOS TCC keys on the *designated
  requirement*, and an ad-hoc signature's is a bare cdhash — so every rebuild silently
  revokes Accessibility while the System Settings toggle still shows as on. `codesign -d -r-`
  tells you which you have; a local self-signed certificate makes the grant stick.
- **A message at the moment of death is not the cause of death.** `MachExc: PT_THUPDATE
  failed` is printed by the Rosetta shim while the process is already going away, so it shows
  up for unrelated failures. Look at what the client *wrote on its way out* instead.
