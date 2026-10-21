# Jellyfin and Emby

Discussion #8, item 4. Upstream's Apple TV app (1.0.26) and web tuner
(tuner-v1.0.1) read Jellyfin and Emby as well as Plex, and so does the port.
This is what upstream does, how the port fits it in, where it differs, and
what was measured.

## What upstream does

Read from upstream `origin/main` at 8a55386:

- `Nostalgex/Services/JellyfinAPIService.swift`, `EmbyAPIService.swift` and
  `JellyfinPlaybackResolver.swift`.
- Their tests.
- `scripts/nostalgex-jellyfin-urls.js` and `plex-tuner.html`.

Jellyfin is a fork of Emby, and upstream drives both through one MediaBrowser
code path.

**Sign-in**

- Header on every request:
  `Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…`.
- Password: `POST /Users/AuthenticateByName` with `{Username, Pw}`. The answer
  carries `AccessToken` and `User.Id`.
- Jellyfin also has Quick Connect: the TV shows a code, and you approve it in
  Jellyfin's web or phone app. The calls are `GET /QuickConnect/Initiate` (the
  port sends a POST, which Jellyfin 12.2 needs; below), then
  poll `GET /QuickConnect/Connect?Secret=` every 2 s, then
  `POST /Users/AuthenticateWithQuickConnect`. A 401 on Initiate means the server
  has Quick Connect switched off.
- Servers answer a UDP broadcast on port 7359 (`who is JellyfinServer?` or
  `who is EmbyServer?`), so the TV can find them without anyone typing an
  address.

**Library**

- The libraries come from `/UserViews?userId=` on Jellyfin and
  `/Users/{id}/Views` on Emby. Emby answers 404 to the first.
- Items: `GET /Items?userId=&ParentId=&Recursive=true&IncludeItemTypes=` with
  the `Fields` list (`ProviderIds,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData`),
  in pages of 200.
- TV shows: list the series, then each series' episodes, several series at a
  time. Each episode takes its show's genres, TMDB id, year, studio and
  ratings, because the channel rules match on the show.
- Runtime is `RunTimeTicks` (10,000,000 per second). Items with none are
  dropped.
- Collections are `BoxSet` items. Jellyfin lists a collection's series; Emby
  lists their episodes instead.
- There is no library-changed signature. Upstream rescans Jellyfin and Emby in
  full every time.

**Playback**

- Direct play: `/Videos/{id}/stream.mp4?Static=true&MediaSourceId=`.
- Otherwise: `POST /Items/{id}/PlaybackInfo` with a device profile, and the
  server's `TranscodingUrl` (HLS).
- If neither works, a hand-built `/Videos/{id}/master.m3u8`. Emby needs a
  `PlaySessionId` on it or every segment fails with 400.
- **Never put `StartTimeTicks` on an HLS address**: Jellyfin then rejects every
  segment with 400. Joining a channel part-way through a programme means
  starting the stream at 0 and seeking on the client.
- To stop a stream: `DELETE /Videos/ActiveEncodings?deviceId=&playSessionId=`.
- Reporting what was watched back to the server is off by default upstream.

**Emby differs from Jellyfin** in these places:

1. the libraries call;
2. no Quick Connect;
3. `PlaySessionId` on the hand-built HLS address;
4. the retry after a failed direct play has to turn off both direct play and
   direct stream;
5. collection members (episodes rather than series);
6. how the server name is found;
7. HLS segments: TS for H.264 (above), fMP4 otherwise;
8. a Dolby Vision profile 5 file goes on no channel. Emby names the profile
   in the video stream's `ExtendedVideoSubType` ("DoviProfile50"), and 4.10.1
   sends it in a form drawn green and purple (upstream `5d6d65f`,
   `ccb6854`). It stays in the library; only the channels leave it out.

## What we checked on test servers

Jellyfin 12.2 and Emby 4.10.1 in containers, each reading a test library
read-only.

- **The token can stay in a header for streams.** On both servers a static
  stream answered 206 with the token only in the `Authorization` header. The
  Roku player sends a content node's `HttpHeaders` with every request, as the
  Plex path already does. So the token never goes in an address, and the maintainer's new
  Roku privacy text ("your token travels in a request header, not in the
  address") stays true. Upstream puts `api_key` in addresses because AVPlayer
  can't add headers. We don't need to.
  - HLS too (2026-10-18). Emby wants the token on the master playlist and
    not on segments. Jellyfin wants it on the master, the variant and every
    segment (401 without it). With the header alone, every stream in the spike
    below played on the TV, and Jellyfin logged no rejected request.
- **Signing in again cancels the device's previous token on Jellyfin** (not on
  Emby). A token stopped working the moment the same `DeviceId` signed in
  elsewhere. The app has to keep one `DeviceId` per install (the Plex client id
  already is one) and must never sign in again in the background while a
  stream is using the old token.
- **Jellyfin burns subtitles into the picture unless told not to.** Two MKVs
  came back from PlaybackInfo with `SubtitleMethod=Encode`
  (`SubtitleCodecNotSupported`), which means a full video transcode. Even with
  `SubtitleStreamIndex: -1` in the body, the `TranscodingUrl` still named a
  subtitle stream. The app needs `SubtitleProfiles` in its device profile (text
  subtitles delivered as HLS or External), or it has to drop those parameters.
- **Jellyfin serves a static stream to anyone who knows the item id**: it
  answered 206 with no token at all. Emby answered 401. That is the server's
  business, not ours, but it is worth knowing when reading logs.
- Jellyfin's `/System/Info/Public` answered in camelCase before its first-start
  setup and in PascalCase after. BrightScript's associative arrays ignore case,
  so the app is safe either way.

## On a TV (2026-10-18)

The build (roku `49c628d`) ran on a 1080p TCL Roku TV against the test
servers, driven over ECP.

**Jellyfin 12.2**

- The broadcast found the server.
- Quick Connect signed in.
- 5,133 items read in 10 s.
- The guide was on screen 21 s after sign-in, with 15 channels. The same
  library through Plex gives 16.
- Tuning seven channels:
  - MP4 and MKV played directly, joined part-way, picture in 1.4 to 3.3 s.
  - One HLS stream had a picture in 1.7 s.
  - Leaving the HLS channel sent `DELETE /Videos/ActiveEncodings`, which
    answered 204.
- A relaunch went straight back to the Jellyfin guide.

**Emby 4.10**

- Typed address, then username and password.
- 5,422 items read in 7 s.
- The guide was on screen 18 s after sign-in.
- An HLS channel had a picture in 2.6 s.
- Only 3 channels, because the test server's libraries had no metadata
  fetchers (3 of 943 titles had genres). The app read what the server had.

**Found on the TV**, each now fixed:

- **Two components called a function their scripts don't load.** BrightScript
  only finds out when the call runs, so the tests passed.
  `tests/tools/check-includes.py` now fails the run when this happens.
- **Quick Connect needs a POST.** Jellyfin 12.2 answers
  `GET /QuickConnect/Initiate` with 405; `POST` works. Upstream's Apple TV app
  and web tuner sent the GET then. Told upstream, both start with a POST since
  2026-10-19 (`1f1a55f`, `180fbd7`, in Docker `tuner-v1.0.2`).
- **A string compared with an object stopped the sign-in task.** BrightScript
  raises a type mismatch where JavaScript would answer false.
- **The password keyboard closed as soon as it opened.** The username
  keyboard's closing notice arrived after the password keyboard was up.
- **A sign-in the server now refuses** left the saved guide up with nothing
  playable. A launch now checks the token (`GET /Users/{id}`); on a 401 it
  signs out and says why, as a refused Plex token does.

- **Emby restarts its transcode on every segment after a mid-file join**
  (2026-10-19, Emby 4.10.1, Discussion #8). Joined 335 s into an MKV whose
  audio it converts, the 43S45 fetched each segment once, but Emby
  started ffmpeg again for each one ("segmentGap is 53 … requestedIndex=55",
  then 54, 55, …: 26 restarts in 11 s). curl alone does the same, so it's
  Emby's, not the TV's: it seems to count the restarted ffmpeg's segments
  from 0, not from its `-start_number`. A file whose streams are only copied
  restarted once. This fits the maintainer's 500s ("Error starting ffmpeg")
  and repeated fetches. `StartTimeTicks` on the playlist is dropped from the
  segment requests, so it's no way round it. Not fixed here yet; a single
  progressive stream for these files is the next thing to try.
- **What that restart costs is sync, upstream found** (Discussion #8,
  2026-10-20). With the video copied and the audio converted, fMP4 stamps
  both tracks from zero, so on their Apple TV the sound ran early by up to a
  GOP (H.264 + DTS joined at 247 s: -1,720 ms on fMP4, +35 ms on TS). TS
  segments carry the source timestamps. The port now asks Emby for TS when
  the video is H.264, as upstream's `embySegmentContainer` (`72c844d`); a
  file that may be HEVC stays fMP4. Upstream tried it on a Streaming Stick
  Plus against Emby 4.10.1 (Discussion #8, 2026-10-20): an H.264 + DTS file
  joined 48 s in asked for `SegmentContainer=ts`, Emby copied the video and
  converted DTS to AAC, and the picture came up in 1.6 s. Sync after the join
  is not yet checked on a Roku.

## How it fits the app

Channels, filtering, enrichment, the guide, saved libraries and package
switches work on scanned items, and a Jellyfin or Emby item is made into the
same shape as a Plex one, so none of them changed. What does differ by server:

| Step | Plex | Jellyfin and Emby |
|---|---|---|
| Sign-in | `PlexSignInTask`, the plex.tv/link code | `components/ConnectView.*` and `MediaBrowserSignInTask`: the 7359 broadcast or a typed address, then Quick Connect (Jellyfin) or a username and password |
| Saved server | registry `plex` section, `servers` | the same list, one server with `kind`, `uri`, `userId`, `accessToken`, keyed by the server's `Id`; `kind` in the section too (`source/mediabrowser/ServerKind.brs`) |
| Library | `NxPlexScanServer` | `NxMbScanServer` (`MediaBrowserLibrary.brs`), chosen by `NxScanServerFor` |
| Change signature | section stamps | none, as upstream, so each load scans |
| Collections | `NxCollectionsFetchPlex` | none yet (no BoxSets) |
| Playback | `NxPlexStreamContent` | `NxMbStreamContent` (`MediaBrowserPlayback.brs`), both through `NxStreamContent` and `NxApplyStreamAuth` |
| Stop | Plex's transcode stop | `DELETE /Videos/ActiveEncodings`, through `NxStopStream` |
| Launch check | plex.tv account | `GET /Users/{id}`; a 401 signs out to CONNECT YOUR LIBRARY with the reason |

**One kind at a time, as upstream does.** The Apple TV app holds one
`backend_kind`: a TV is signed in to Plex, or to one Jellyfin server, or to
one Emby server. Mixing them would mean channels that cross backends, which
upstream doesn't do.

**HLS built on the TV, not taken from PlaybackInfo.** That would be a POST
before every tune, and PlaybackInfo had Jellyfin burn subtitles into the
picture (above). Direct play when the TV decodes the file (MKV only on the
home network), else `master.m3u8` copying the video.

**No reporting to the server.** The Roku app sends Plex nothing about what you
watch, and its privacy policy says so; Jellyfin and Emby are the same, which
also leaves out upstream's watch-state restore.

## Playback spike (2026-10-18)

Before building the rest: a throwaway app on a 1080p TCL Roku TV (OS 16.0.4)
played each case with `PlayStart = 1200` (20 minutes in) and the token only in
`HttpHeaders`.

| Case | Playing after | Rebuffers in 60 s |
|---|---|---|
| Jellyfin MP4 H.264, direct | 2.6 s | 0 |
| Jellyfin MP4 HEVC 10-bit (`hev1`), direct | 1.5 s | 0 |
| Jellyfin MKV HEVC 10-bit, direct | 3.6 s | 0 |
| Jellyfin MKV HEVC, PlaybackInfo HLS, fMP4 | 2.6 s | 0 |
| Jellyfin MKV H.264, PlaybackInfo HLS, TS | 3.3 s | 0 |
| Jellyfin MKV HEVC, hand-built HLS, fMP4 | 5.7 s | 0 |
| Emby MP4 HEVC 10-bit, direct | 1.7 s | 0 |
| Emby MKV HEVC, PlaybackInfo HLS, fMP4 | 1.6 s | 0 |
| Emby MKV H.264, hand-built HLS with `PlaySessionId`, TS | 3.0 s | 0 |

- **How each row was checked.** The player reached `playing`, and its
  position advanced about 55 s per minute from 1200. Developer screenshots
  don't capture the video plane, so the picture itself wasn't seen.
- **Seeking on the client works.** HLS joins needed no `StartTimeTicks`: the
  player asks for the segment at the offset, and both servers start there
  within a second or two.
- **Direct MKV joined fine here**, unlike the MKV crawl seen through Plex.
  That was over HTTPS and this was plain HTTP on the LAN, so it isn't the same
  comparison.

## Tests

- **The scan:** `tests/gen-mediabrowser.mjs` runs upstream's own
  `fetchJellyfinLibraryFromServer` over `tests/fixtures/mediabrowser-server.json`
  (answers trimmed from a Jellyfin 12.2 server, plus made-up cases), and
  `tests/MediaBrowserTests.brs` holds `NxMbScanServer` to its requests and
  items. It also covers dates, typed addresses, `/System/Info/Public` and
  sign-in answers.
- **On the TV:** the rest was checked by driving a TV over ECP (above):
  sign-in each way, a guide build, joining part-way, a channel change stopping
  the stream, sign-out, and a refused sign-in.
