<div align="center">
  <h1>imogen for iOS</h1>
  <p><strong>Your photo library, on your own server — on your phone.</strong></p>
</div>

A native client for [imogen](https://github.com/ergofobe/imogen-server), written in Swift
and SwiftUI. It browses the library, backs up what the camera takes, and does both against
as many servers as you have accounts on.

- **Pair by pointing the camera at a QR code** — no hostname to type
- **Several accounts, several servers** — switch between them from Settings
- **Backup to more than one** — choose two accounts, get two copies
- **iPhone and iPad** — a tab bar on one, a sidebar and a wider grid on the other
- **A timeline that survives fifty thousand photographs** — see below

Administration is deliberately absent. Accounts, the processing queue, connected
applications and public links are managed in the web interface, behind a signed-in browser
session; this app asks for the scopes a photo client needs and no more, so a lost phone is
not a lost server.

---

## Building it

```bash
git clone --recurse-submodules https://github.com/ergofobe/imogen-ios
cd imogen-ios
open imogen.xcodeproj
```

`--recurse-submodules` matters: the client library lives in
[imogen-sdk](https://github.com/ergofobe/imogen-sdk) and is built from source as part of
this build. If you have already cloned without it, `git submodule update --init`.

The project file is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, so opening the repository
in Xcode needs nothing installed. After changing `project.yml`, run `xcodegen generate`;
CI checks that the two agree.

## Pairing

The hard part of installing a self-hosted photo app is the first screen, where it asks a
phone keyboard for a hostname somebody chose themselves. imogen does not.

1. On a computer, open imogen and go to **Settings → Devices → Pair a device**.
2. On the phone, open imogen and tap **Scan a pairing code**.
3. Point the camera at the square.

What crosses the camera is a one-time ticket, not a token. It carries the server address
and a code that lives five minutes and works once; the app registers a client for itself,
turns the ticket into an authorization code bound to a PKCE challenge it generated, and
exchanges that for tokens. Photographing somebody's screen gets you nothing, because the
verifier never left the phone.

If the phone is the thing looking at the web interface, the same dialog offers the ticket
as a link — tapping it opens the app directly.

Failing all that, **Enter a server address** runs the ordinary OAuth flow through Safari.

## Backup

**Settings → Photo backup.** Choose which accounts get a copy: each one you turn on gets
its own, so a family server and a personal one both end up with the photograph.

Uploads are idempotent by content — the server recognises a file it already has and does
not store it twice — and each file carries its `PHAsset` identifier, so the app knows what
it has already sent without re-reading the camera roll. Anything at or above 64 MB goes up
in resumable chunks, so a dropped connection costs one chunk of a video rather than the
whole thing.

The original bytes are what get uploaded, taken from `PHAssetResourceManager` rather than
re-encoded on the way out. A photograph that arrives without its EXIF is a photograph in
the wrong place in the timeline for ever.

iOS decides when a background upload may run — usually overnight, on a charger. A pass also
runs whenever the app is opened, which in practice is what catches this morning's
photographs. The app does not pretend otherwise.

## A timeline that scales

A library of fifty thousand photographs cannot be paged into a grid a hundred at a time.
Reaching 2011 that way is four hundred round trips, and the scroll indicator lies about how
much there is until the last one lands.

So the grid is not built from photographs. It is built from
`GET /api/v1/assets/timeline`, which returns one row per day with a count — a few thousand
rows for a lifetime, one request, no images. From that the app knows exactly how many cells
there are and where every day begins before fetching a single photograph:

- the grid is the right length from the first frame, so nothing reflows as data arrives
- **the rail** on the right edge is a thumb until you take hold of it, and then it is a
  ruler: year marks spaced by how much of the library each year holds, and the month under
  your thumb named as you drag. A year of nine thousand frames takes more rail than a year
  of two hundred, because that is where its photographs are
- the thumb is positioned by a segment table — a running total of estimated pixel heights,
  a heading plus however many rows each day needs — not by a photograph's position in the
  list. Those are different measurements, and using the wrong one is what makes a scrubber
  jump while the content scrolls smoothly
- days load as they come into view, one request each — jumping to a date five years back
  costs one request, not four hundred
- days scrolled far past are evicted, so scrolling end to end does not end with fifty
  thousand assets in memory
- nothing is fetched *during* a drag, and fetching resumes 150 ms after it settles, so a
  flick across a decade does not ask the server for every day it passes through

The same segment table is what the web timeline is being rebuilt on, so the three clients
describe the library the same way.

## Working on it

```bash
swift test                        # the logic, in about a second
TZ=America/Los_Angeles swift test # and again somewhere that is not UTC
xcodebuild -project imogen.xcodeproj -scheme imogen \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

### The shape of it

```
Sources/ImogenKit/   accounts, sessions, pairing, the day index, the upload ledger
Tests/               all of the above, without a simulator
App/Sources/         SwiftUI, PhotoKit, AVFoundation — the parts that need a phone
imogen-sdk/          the client library, as a submodule
```

`ImogenKit` does not import UIKit. That is the point: `swift test` runs the whole of the
logic on any machine with a toolchain, in under a second, with no Xcode and no simulator —
so the arithmetic the timeline depends on is checked on every commit rather than by
scrolling and squinting.

There are also integration tests that run the real pairing sequence against a real server.
They skip unless you point them at one:

```bash
IMOGEN_TEST_SERVER=http://127.0.0.1:3100 \
IMOGEN_TEST_EMAIL=you@example.com \
IMOGEN_TEST_PASSWORD=… swift test
```

### Running a development build

A simulator has no camera, and `simctl openurl` puts a system prompt in front of the app
that nothing on the command line can dismiss. So a debug build accepts a pairing URI from
its launch environment:

```bash
SIMCTL_CHILD_IMOGEN_PAIR_URI="imogen://pair?server=…&code=…" \
  xcrun simctl launch booted com.imogen.ios
```

That is compiled out of anything but a debug build.

## Licence

AGPL-3.0-or-later, the same as the server and the SDK.
