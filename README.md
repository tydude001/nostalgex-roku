# nostalgex-roku

A Roku port of [Nostalgex](https://github.com/chadMueller/Nostalgex), the
retro live-TV channel guide for your own media library. The upstream project
ships an Apple TV app and a browser tuner, and Roku is
[not on its roadmap](https://github.com/chadMueller/Nostalgex/discussions/8).
This port fills that gap.

The goal is a faithful port, rewritten in BrightScript and SceneGraph. It
signs in to Plex, Jellyfin or Emby, reads your library, and airs upstream's
channels, packages and schedules (a channel shows the same programme at the
same minute as on Apple TV) in the Apple TV app's guide, with live playback.
Once signed in it opens on its saved guide in under a second, or on a later
day in a few seconds from the saved channel pools, and refreshes in the
background.

**Server collections become channels on Plex only so far.**

## Install (developer mode)

Until there is a store listing, it installs by sideloading:

1. Enable developer mode on the TV once: press Home ×3, Up ×2, Right, Left,
   Right, Left, Right on the remote, then set a developer password. The TV
   reboots.
2. `cp .env.example .env` and fill in `ROKU_HOSTS` and `ROKU_DEV_PASSWORD`.
3. `scripts/deploy.sh` zips the app, installs it on every TV in `ROKU_HOSTS`
   and launches it (`ROKU_HOSTS=<tv-ip> scripts/deploy.sh` for one TV).

A Roku holds one sideloaded app at a time, and installing replaces whatever is
there. Debug output is on the TV's port 8085 (`nc <tv> 8085`).

## Servers

Only the Plex servers you own are read at first, since servers friends share
with you can be most of an account's items and most of a first load. Settings
lists every server once there is more than one, to switch any of them on or
off. An account with only shared servers reads all of them.

## Deep links

A deep link's `contentId` names a channel, by its id or else its guide
number, and the app tunes it fullscreen. Any `mediaType` is taken, since every
channel is live; one that names no channel opens the guide as usual. Try one
over the TV's control port (`source/guide/DeepLink.brs`):

```sh
curl -d '' "http://<tv>:8060/launch/dev?contentId=7&mediaType=live" # at launch
curl -d '' "http://<tv>:8060/input?contentId=12&mediaType=live"     # while running
```

## Security

- **Sign-in is plex.tv's link code**, typed in or scanned from the QR code
  beside it. The TV never sees your Plex password, and draws the QR itself,
  so the code goes to no QR service.
- **The Plex token stays on the TV**, in this app's private registry section.
  It is never written to the repo, to logs, or to the debug console (port
  8085), which anyone on the network can read. `tests/run.sh` fails if a
  `print` statement could output a token, URL or header.
- **HTTPS, certificates checked, to plex.tv.** The Plex server itself may be
  reached at its plain-HTTP address on your home network, as Plex's own
  apps do at home, because on some networks a TV's traffic over the public
  address stalls and the secure in-house address doesn't resolve. The app
  only does that for a private address (192.168.x, 10.x, 172.16-31.x), so
  the token never leaves the house unencrypted, and it travels in a header,
  never in a URL. If your server isn't found at all, set Plex's
  *Settings > Network > Secure connections* to *Preferred*.
- **Jellyfin and Emby** sign in with Jellyfin's Quick Connect code or with a
  username and password. The password goes to your server once and is
  cleared; only the access token the server returns is kept. Server requests
  follow the same rule as Plex: HTTPS, or plain HTTP to a private address
  only, with the token in a header.
- **Read-only.** The app never reports playback to your server and never
  changes watch status or anything else in your library.
- **The saved guide** (`cachefs:`) holds titles and schedules, and the saved
  pools the library items each channel draws on. Both are deleted on
  sign-out.
- **Enrichment is off unless a build turns it on** (`NOSTALGEX_ENRICHMENT` in
  `.env`, see [docs/PORTING.md](docs/PORTING.md)). When on, only TMDB and
  IMDb ids leave the TV, to the Nostalgex relay and its shared cache, as the
  web tuner sends them. Its local cache is deleted on sign-out too.
- **Sign out in Settings** (SIGN OUT OF PLEX, then OK a second time), or
  with \* on the sign-in and error screens. That removes the token, the
  server list and the device ID the app stored.

## Tests

The port is checked against golden vectors generated from upstream's own
engine (see [docs/PORTING.md](docs/PORTING.md)):

```sh
tests/run.sh               # off-device, in the RokuCommunity brs interpreter
scripts/deploy.sh --test   # on every TV in ROKU_HOSTS; the one that counts
node tests/gen-vectors.mjs # regenerate after following a new upstream commit
```

GitHub Actions (`.github/workflows/ci.yml`) runs `tests/run.sh` on every
push to the [GitHub copy](https://github.com/tydude001/nostalgex-roku),
against a fresh clone of upstream. Actions is off on Gitea, so a commit that
has only reached Gitea hasn't been through CI.

The live checks compare the port with upstream's code on a real Plex server.
They need this computer linked to Plex once, which saves `PLEX_TOKEN` and
`PLEX_CLIENT_ID` to `.env`:

```sh
node tests/live/plex-link.mjs     # shows a plex.tv/link code; the token is never printed
scripts/deploy.sh --live          # TV: load the library, log fingerprints to out/live-<tv>.log
node tests/live/compare.mjs       # same pools and schedules as upstream?
node tests/live/collections.mjs   # same server collections and folds? (no TV)
```

`scripts/sca.sh` runs Roku's Static Channel Analysis, the Channel Store's own
check, and fails on any error it reports.

## Layout

| Path | What |
|------|------|
| `manifest` | Roku app manifest |
| `source/` | BrightScript entry point (`main.brs`) |
| `components/` | SceneGraph screens (sign-in, guide, settings) and background tasks |
| `source/schedule/` | The daily schedule builder, ported from upstream |
| `source/filter/` | The channel filter, ported from upstream |
| `source/franchise/` | The franchise builder, ported from upstream |
| `source/collections/` | Server collections as channels from CH 500, and their fold into franchises, ported from upstream |
| `source/guide/` | Lineup: bundles, daily shuffle, time restrictions, day schedules; franchise channels and their switches |
| `source/plex/` | Plex sign-in, library loader, playback |
| `source/mediabrowser/` | Jellyfin and Emby: sign-in, LAN discovery, library loader, playback |
| `source/enrich/` | TMDB and IMDb enrichment through the Nostalgex relay, off unless a build turns it on |
| `source/subtitles/` | Subtitle settings and language matching, ported from upstream |
| `source/util/` | Shared helpers |
| `data/` | Upstream's channel config and franchise dictionary, vendored unchanged (`data/UPSTREAM`) |
| `fonts/` | DM Mono and VT323, with their licenses (`THIRD-PARTY-LICENSES.md`) |
| `images/` | Home-screen icons, splash and in-app logo, and the guide's overlays in `images/look/` |
| `scripts/deploy.sh` | Zip and sideload to every TV (`--test` runs the vectors, `--live` the live check) |
| `scripts/icons.sh` | Draws the icons, splash and logo: the Nostalgex wordmark, from upstream's `logo/` |
| `scripts/look-images.py` | Draws `images/look/` (scanlines, vignette, focus outline, static) from the Apple TV app's drawing code |
| `scripts/sca.sh` | Roku's Static Channel Analysis, the Channel Store's own check (`out/sca/report.txt`) |
| `scripts/post-upstream.sh` | Posts to upstream's GitHub Discussions; it can reach nothing else |
| `tests/` | Golden vectors from upstream's code, and the runner |
| `tests/live/` | Live checks against a real Plex server (`plex-link.mjs`, `compare.mjs`, `collections.mjs`) |
| `tests/bench/` | Channel build, franchise step and schedule benchmarks over a saved library; their logs diff two builds result by result |
| `docs/PORTING.md` | What is ported from where, and how parity is proven |
| `docs/UPSTREAM.md` | Working with the Nostalgex project |

## License

MIT. It includes portions of Nostalgex, copyright Chad Mueller / Muell Haus
Inc., under the same license. See [LICENSE](LICENSE).
