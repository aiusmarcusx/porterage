# Porterage

Move files between an Android phone and a Mac, over the cable, without the parts that usually go
wrong.

Plug the phone in and Porterage shows what is on it — as a list, or as a grid of real photo
thumbnails. Drag files out to the Finder, drop files in, and copy whole folders to the Mac.

**macOS 14 or later. Apple silicon and Intel. No Wi-Fi, no account, no cloud.**

---

## Why another one of these

Everything here came out of measuring a real phone rather than reading a specification. A few of the
things that turned up:

**Copying many small files wedges MTP.** The phone raises an interrupt event for every object
written. A client that never reads that queue slows from 53 ms per file to about 1.1 seconds, and
after roughly 211 files MTP stops answering until the cable is physically unplugged. Porterage drains
the queue, so small files stay fast and the connection survives.

**Listing a folder does not have to be slow.** Asking the phone about each file in turn takes 3.2
seconds for 345 files. Asking for one property across the whole folder takes 0.56. Porterage speaks
MTP directly to get at the faster command.

**Two files can differ only in case — and destroy each other.** The phone's storage ignores case
while the protocol does not, so `Report.txt` and `report.txt` both appear in a listing while sharing
one file underneath. Writing the second silently overwrites the first. Porterage compares names the
way the phone's storage actually does — against what is already there, and across the files you drop
together — and stops before anything is written.

**A locked phone looks like a missing one.** It still answers, but hands over an empty list of
storage, which other tools report as "not connected". Porterage says the phone is locked, and
fills the window in by itself once it is unlocked.

**An interrupted copy to the Mac picks up where it stopped.** It is written as `.part` until the last
byte arrives; copy it again and only the missing bytes are fetched. The phone can resume uploads
too — measured byte for byte with SHA-256 — but the app does not do that yet.

The full set of findings, with the numbers, is in [NOTES.md](NOTES.md).

## Building

Requires the Xcode command line tools and Swift 6. No Xcode install needed.

```sh
Scripts/build-libusb.sh      # once: builds libusb into Vendor/, universal, for macOS 14
Scripts/make-app.sh release  # produces build/Porterage.app
```

`Scripts/make-app.sh` with no argument makes a faster host-only debug build.

## Checking a connection from the terminal

```sh
swift run mtpcheck             # connect, show storage, list a folder, with timings
swift run mtpcheck selftest    # full round trip: create, upload, verify SHA-256, rename, delete
```

Useful when reporting a problem: the output says which of the connection states the phone is in.

## Layout

| Path | What it holds |
|---|---|
| `Sources/MTPKit` | The MTP implementation: USB plumbing, the protocol, listing, transfers, thumbnails |
| `Sources/PorterageApp` | The SwiftUI app |
| `Sources/mtpcheck` | Terminal diagnostics |
| `NOTES.md` | Everything measured against real hardware, and why the code is shaped the way it is |

The only native dependency is libusb, built from source and linked statically, so a finished `.app`
needs nothing installed on the user's machine.

## Licence

Apache-2.0 — see [LICENSE](LICENSE). The name Porterage is not part of that grant;
the licence explicitly covers code, not trade names. Third-party components and the
libusb relinking terms are set out in [NOTICE](NOTICE).
