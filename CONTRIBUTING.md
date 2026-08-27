# Contributing

## Getting a build

```bash
git clone --recurse-submodules https://github.com/ergofobe/imogen-ios
cd imogen-ios
open imogen.xcodeproj
```

`imogen-sdk/` is a git submodule, and its Swift package is built from source. There is no
published `ImogenSDK` release yet, and vendoring a copy of the client would mean two copies
of the API contract drifting apart — which is the exact failure the conformance suite in
that repository exists to prevent.

Changing the SDK means committing there first, then bumping the submodule pointer here:

```bash
cd imogen-sdk && git pull && cd ..
git add imogen-sdk && git commit -m "Move to the current SDK"
```

## The project file

`imogen.xcodeproj` is generated from `project.yml` by XcodeGen and committed, so that
opening the repository in Xcode needs nothing installed first. After changing `project.yml`:

```bash
brew install xcodegen   # once
xcodegen generate
```

CI fails if the two disagree.

## Checks

```bash
swift test                          # the logic
TZ=America/Los_Angeles swift test   # and again somewhere that is not UTC
TZ=Pacific/Auckland swift test
xcodebuild -project imogen.xcodeproj -scheme imogen \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

The timezone runs are not superstition. The timeline's headings are the server's UTC day
buckets, and rendering them with a local-time formatter shifted every one of them by a day
for everybody west of Greenwich. A machine on UTC never notices.

Integration tests against a live server are skipped unless you point them at one:

```bash
IMOGEN_TEST_SERVER=http://127.0.0.1:3100 \
IMOGEN_TEST_EMAIL=you@example.com \
IMOGEN_TEST_PASSWORD=… swift test
```

## Where things go

Anything worth testing goes in `Sources/ImogenKit`, which does not import UIKit and
therefore runs under `swift test` with no simulator. `TimelineIndex`, `AccountBook`,
`TokenSet`, `normalizeServerURL` and the formatting helpers all live there, and anything
with arithmetic or a decision in it should join them.

`App/Sources` is SwiftUI and the frameworks that only exist on a phone. Views take what
they need as parameters and hand events back out.

## Scope

This is a user client, on purpose. Server administration — accounts, invitations, the
processing queue, connected applications, public links — lives in the web interface behind
a browser session, and the app asks for the scopes a photo client needs and no more.
Please do not add administration here.
