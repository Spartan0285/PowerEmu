# Updating PowerEmu

PowerEmu looks for new versions itself. This is what has to be put on the
web for that to work, and what PowerEmu does with it.

## The feed

A JSON file, fetched at most once a day, served from this repository:

    https://raw.githubusercontent.com/Spartan0285/PowerEmu/main/appcast.json

It sits next to the source and points at a release asset on the same
repository, so there is one place to keep up to date and it is the same
place anyone can get the source from -- which is what the GPL asks of us
anyway. That does mean the repository has to be public: a private one
serves neither the feed nor the download without a token, and a token in
a shipped app is not a secret.

That address can be changed without a rebuild, the same way the feedback
endpoint can:

    defaults write com.spartan0285.poweremu PEUpdateFeed https://example.com/appcast.json

or, for one run, `POWEREMU_UPDATE_FEED` in the environment.

```json
{
  "version": "0.2",
  "build": 2,
  "published": "2026-10-01T12:00:00Z",
  "minimumSystem": "14.0",
  "notes": "What changed, in plain words. Shown to the reader as it is.",
  "url": "https://example.com/downloads/PowerEmu-0.2.zip",
  "sha256": "…",
  "history": [
    { "version": "0.1", "build": 1, "published": "2026-09-20T10:00:00Z",
      "notes": "The first one." }
  ]
}
```

* `build` is the only thing compared; it must go up. `version` is what the
  reader is shown.
* `url` is a zip of `PowerEmu.app`, made with `ditto -c -k --keepParent`.
  Ordinary `zip` does not keep the symlinks inside a bundle and breaks its
  signature.
* `sha256` is optional but worth having: it catches a download that arrived
  damaged. It is not what makes this safe — see below.
* `minimumSystem` is optional. A version needing a newer macOS than this Mac
  has says so and cannot be installed.

`history` is what **What's New** reads: the releases before this one,
newest first, kept to the last twenty. `scripts/release.sh` rolls it
forward, so there is no second file to maintain and one fetch answers both
"is there something newer" and "what changed, and what changed before
that".

Notes are plain text with three conveniences: a blank line separates
paragraphs, a line starting with `- ` or `* ` is a point, and a line
starting with `#` is a heading. Deliberately not full Markdown -- these
are read far more often than they are written, and anything that does not
render is worse than plain text.

## What's New

Shown once, the first time a newer PowerEmu than last time is opened, and
from PowerEmu -> What's New in PowerEmu whenever it is wanted. It shows
the notes for the version actually running -- not the one being offered --
and the releases before it. A first-ever run says nothing: there is no
"since" to talk about.

The notes come from the feed, so a copy that has never looked has nothing
to show until it does; the window offers to look.

## What PowerEmu checks before installing

1. The download matches `sha256`, if the feed gave one.
2. What was downloaded is an app with **PowerEmu's own bundle identifier**.
3. Its signature is valid, including everything nested inside it.
4. It was signed by the **same developer as the copy that is running**.

Step 4 is the one that matters. A feed that has been tampered with can serve
a matching `sha256` for whatever it likes; it cannot sign an app as us.
Both refusals have been tried: a download that does not match the feed is
turned away as damaged, and a correctly-checksummed app with one byte
changed inside it is turned away as not properly signed. In both cases the
copy already installed is left exactly as it was.

## What happens then

The copy being replaced is moved to the **Trash**, not deleted, so it can be
dragged back if the new one turns out to be wrong. If putting the new one in
place fails, the old one is moved straight back.

Virtual Macs must be shut down or asleep first; PowerEmu says so rather than
replacing itself underneath a running machine.

## Notarising

A Developer ID signature is not enough on its own. Anything downloaded
carries a quarantine flag, and macOS refuses to open a quarantined app
that has not been **notarised** -- not a warning to click past, a refusal.
Before this was set up, `spctl --assess` on a build said exactly that:

    build/PowerEmu.app: rejected
    source=Unnotarized Developer ID

Notarising requires the **hardened runtime**, which is now on for every
build -- including development ones, deliberately: the first thing it
breaks is the emulator's JIT, and that is the whole machine, so it is not
something to discover while cutting a release. The emulator translates
PowerPC into arm64 and runs what it wrote (`tcg/region.c` asks for
`MAP_JIT`), which the hardened runtime refuses without
`com.apple.security.cs.allow-jit`. That entitlement is in
`app/Resources/PowerEmuVM.entitlements`, and a guest has been booted to
its desktop with it on.

The credentials live in the keychain, once per Mac:

    xcrun notarytool store-credentials PowerEmu \
        --apple-id you@example.com --team-id 7B2D3VV69V --password APP-SPECIFIC-PASSWORD

`release.sh` then submits, waits, staples the ticket into the app so it
opens on a Mac that cannot reach Apple, packs it **again** (stapling
changes the app, so the zip made before it is the wrong one), and checks
what will actually be downloaded with `codesign`, `stapler validate` and
`spctl`.

## Cutting a release

    scripts/release.sh 0.2 2 "What changed, in plain words."

It builds at that version, packs the app with `ditto`, checks the
signature survived the packing (a release that fails this would be
refused by every copy out there), attaches the zip to a GitHub release,
writes `appcast.json` and pushes it. It refuses a build number that is not
higher than the one already published, because that is what the updater
compares.

## Trying it without a release

The app takes two arguments, which is how the above was tested:

```
PowerEmu.app/Contents/MacOS/PowerEmu --update-check
PowerEmu.app/Contents/MacOS/PowerEmu --update-install
PowerEmu.app/Contents/MacOS/PowerEmu --whats-new
```

Point `POWEREMU_UPDATE_FEED` at a local file server, and run the second one
against a *copy* of the app: it replaces whichever copy is running.
