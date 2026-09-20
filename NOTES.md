# What the hardware actually does

Everything below was measured against a **Redmi 9T (MIUI, Android 11)** connected to a **MacBook Air
M1, macOS 26.5.1**. None of it came from documentation, and several findings contradict it.

These are not style preferences. Ignore any one of them and the app breaks in the way described.

**Which client took the measurements.** Everything dated 11–12 Sep came from a throwaway prototype
built on libmtp, before this app implemented MTP itself on 13 Sep. Those findings describe the phone
and the protocol. Figures for this app's own engine are in [Measured on this app's engine](#measured-on-this-apps-engine-15-sep);
quote those, not the prototype's, as the app's.

## Three rules that are not optional

### 1. One session, held open for the life of the connection

Opening a session makes the phone pop up its *"Use USB for…"* prompt again. Opening and closing one
every fifteen seconds makes that prompt appear over and over.

A locked screen blocks opening a new session: it opens, but `GetStorageIDs` comes back empty.

**Whether a lock stops a session that is already running is unresolved, so assume it does.**

| Measured | Result |
|---|---|
| 12 Sep, libmtp prototype: session open, then lock the screen | 11 consecutive 512 MiB reads, 29.1–29.5 MiB/s, zero errors |
| 15 Sep, this app's engine: 512 MiB reads in a loop, then lock the screen (two runs) | The read in progress stalled within seconds; commands then timed out, and the session only came back after unlocking |

In the 15 Sep runs no MTP event arrived before the stall (events were being drained between 8 MiB
slices) and the USB product id stayed `FF40`, so neither an unread event nor a mode change explains
it. Until the difference with 12 Sep is understood, nothing — app, README or website — may say a
copy survives a lock. The app tells the user to keep the phone unlocked while copying.

### 2. Drain the phone's event queue

The phone raises an interrupt event for every object written. Leave them unread and the queue fills:

| | Draining | Not draining |
|---|---|---|
| Pushing 400 small files | 53 ms each, 0 errors | ~1,100 ms each from file 11 onward |
| After ~211 objects | fine | **MTP wedges permanently — a USB reset does not recover it, only unplugging the cable** |

`PTPSession.drainEvents()` polls the interrupt endpoint between slices and after every operation.

Each poll waits 10 ms for an event. At 50 ms the waiting alone made every small file cost 129 ms;
at 10 ms it is 59 ms, and 1,000 files still showed no slowdown past the 211 mark.

### 3. One serial queue for every command

The phone answers one command at a time. `MTPDevice` funnels everything through a single dispatch
queue rather than locking per call.

## Why this app implements MTP itself

libmtp flags every Android device with `DEVICE_FLAG_BROKEN_MTPGETOBJPROPLIST` and exposes no public
way to clear it — the flag lives inside `params`, an opaque `void *`. The result is one
`GetObjectInfo` round trip per file.

| Listing a folder of 345 files | Time |
|---|---|
| libmtp (one request per file) | **3.2 s** |
| `GetObjectPropList` (one request per property) | **0.56 s** |

At 10,000 photos that is 95 seconds against roughly 6. Implementing the protocol directly also drops
the Homebrew dependency: the only native library left is libusb, which can be bundled.

Layout: `USBLink.swift` (find the phone, claim the interface, move bytes) · `PTP.swift` (containers
and transactions) · `MTPRaw.swift` (storage and listing) · `MTPRawTransfer.swift` (read, write,
thumbnails, resume) · `MTPProbe.swift` (synchronous wrapper used by the `mtpcheck` tool).

Run `swift run mtpcheck selftest` to exercise the whole layer against a real phone — it creates a
folder, uploads a file, verifies the size, reads it back, compares SHA-256, renames, fetches a
thumbnail, and cleans up.

Two more commands exist for the questions a harness cannot ask itself, because they need a person to
interfere at a moment of their choosing:

| Command | Answers |
|---|---|
| `mtpcheck mode` | Which mode the phone is in — product id, interface class, whether it advertises MTP through vendor extension 6, how many storages it admits to, and whether the interface offers an event endpoint at all. One line per fact, then the app's own name for the state. |
| `mtpcheck soak [minutes] [folder]` | Lists a folder and reads its largest file over and over, one timestamped line per cycle, reconnecting by itself every 3 s when the session dies. Lock the screen, pull the cable or close the lid at any moment; the log then says which call stalled, how long after the last good cycle, with what error, and whether it came back on its own — and prints the identity again after a reconnect, so a mode change shows as a changed product id. |

## Undocumented behaviour worth knowing

**`GetObjectPropList` at depth 1 returns the folder you asked about *along with* its children.** Left
in place, every folder contains itself and nests forever. `MTPRaw.entries(in:)` drops the queried
handle.

**The phone refuses `propertyCode = 0xFFFFFFFF`** ("send me every property") with `0xA801`, so each
property needs its own call.

**The first listing after the cable is plugged in takes about 17 seconds** while the phone builds its
index of roughly 34,000 objects. Every listing after that is around 0.17 s. The UI has to show
progress for that first one or it looks frozen.

**A data phase is one USB transfer, and a packet that is not full ends it.** Two consequences, both
measured on 15 Sep before the fix:

- Written separately, the 12-byte container header is itself a short packet, so the phone reads the
  file as a second transfer. A file that fills its last packet exactly — 512, 1024 or 4096 bytes —
  then never ends: those sizes hung for 60 s while 511 and 513 went through. About one file in 500.
- Every write but the last must therefore be a whole number of packets. A first write of header plus
  a full 8 MiB slice is 12 bytes over, and broke an 8 MiB + 500 byte file. For a file over 4 GiB,
  whose length the phone reads "until a short packet", it would silently cut the file at 8 MiB.

`sendObject` tops the first write up to exactly one slice, and `finishDataPhase` sends a zero-length
packet when the whole container is a multiple of the packet size. 24 sizes around the boundaries now
round-trip byte for byte, including a 221-character name that makes the ObjectInfo exactly 512 bytes.

**Stopping an upload needs MTP's Cancel Request**, the class-specific control request `0x64`, then
Get Device Status (`0x67`) until the phone answers OK. Only stopping the writes left the phone waiting
for the rest: Stop took 30.6 s to return and left a 136 MiB file on the phone. With the request it
returns in 0.3–0.4 s and nothing is left behind.

**A response can belong to an earlier command.** After a timeout the phone's late answer used to be
taken as the next command's: a delete was silently skipped, leaving a partial file. `awaitResponse`
now discards containers whose transaction id is not the one it sent.

**The phone deletes a folder with everything in it in one `DeleteObject`** — 1,000 files in 9.5 s.
The app still empties a folder first if a phone refuses.

## What only clicking found

Driven through the real window on 16 Sep, after everything below had passed in a harness:

| | |
|---|---|
| A click on a row in list view | Selected nothing. `List(selection:)` never saw it; `.onDrag` on the row takes the mouse-down. The row now sets the selection itself, the way the grid always did. |
| `.itemProvider` instead of `.onDrag` | Fixes selection but starts no drag at all: nothing could be dragged out. Both are needed — the tap gesture for selection, `.onDrag` for the drag. |
| Space bar, and the delete key | `.onKeyPress(.space)` and `.onDeleteCommand` on the list never fired. Both are hidden `keyboardShortcut` buttons now, switched off while a sheet is up so the search field keeps its space bar. |
| A file dragged out to the Finder | Landed as `photo.jpg.jpeg`: the item was registered as `public.jpeg`, and the Finder appends that type's extension to the suggested name. Registering plain `public.data` keeps the name. |
| The space bar inside the preview, and its arrow keys | Same story: `.onKeyPress` never fired, so the sheet would not close with the space bar. Hidden shortcuts again. |
| The space bar on a folder | Opened the preview, which then reported it could not read the file. Photos only now. |
| ⌘-click on a second row | Did not extend the selection: `NSEvent.modifierFlags` reports the keyboard at the moment it is asked, not the click being handled. `NSApp.currentEvent` does. |
| ⇧-click to take a range | Was not implemented at all — it landed as a plain click, so a folder of 300 photos took 300 clicks. Added 20 Sep, in both the list and the grid, with ⌘⇧ to add a run to the selection. |
| A phone that is unlocked but sharing no storage | Reported as "The phone is locked", which was wrong. It happens after switching USB modes back and forth, and picking File transfer again fixes it — the message now names both causes. |

## Selecting rows

The Finder's rules, because a file browser that invents its own are simply wrong:

| Click | What happens |
|---|---|
| Plain | Replaces the selection, and anchors there |
| ⌘ | Toggles that one row, and re-anchors on it |
| ⇧ | Takes the run between the anchor and the row. **The anchor does not move**, so a second ⇧-click re-measures from the same place instead of creeping down the list |
| ⌘⇧ | Adds that run to what is already selected |

The anchor is cleared whenever the rows under it change — entering a folder, and after a reload that
no longer contains it. A ⇧-click with no anchor, or an anchor that has gone, falls back to a plain
click: selecting a guessed range is worse than selecting one row.

The run is taken from `visibleEntries`, which is the sorted and filtered order actually on screen, so
⇧-click follows the sort the user chose rather than the order the phone returned.

This was the second-most-requested thing in OpenMTP's tracker — open five years across
[#243](https://github.com/ganeshrvel/openmtp/issues/243) and
[#316](https://github.com/ganeshrvel/openmtp/issues/316) — and it was missing here too.

## Checking what needs no phone

**`swift test` cannot run on this machine.** With the command line tools and no Xcode, neither
XCTest nor swift-testing is present, so a test target fails to compile at `import`. Rather than
leave the one piece of logic that needs no hardware unchecked, the checks are a flag on the app:

```
swift run PorterageApp --check
```

21 checks over the selection rules, exit 0 or 1, so it works in a script. Verified on 20 Sep that it
actually fails when the logic is broken — changing the range to a half-open one turned four checks
red and the exit code to 1. A check that cannot go red is not a check.

If Xcode ever gets installed, move these to a real test target; the logic is already a pure static
function taking its inputs as arguments for exactly that reason.

## Connection states

This is where other MTP clients do badly: every failure collapses into one unhelpful message.

| Situation | Signature | What to tell the user |
|---|---|---|
| Screen locked | Session opens, `GetStorageIDs` comes back empty | "Unlock the phone" |
| Set to PTP / photo transfer | Interface class 6 instead of 255, PID `FF10` instead of `FF40`. AOSP's `MtpServer` also leaves vendor extension 6 (`microsoft.com`) out of `GetDeviceInfo`, which is what the app checks — taken from the source, not yet measured | "Switch to File transfer" |
| Charging only | No MTP interface on the bus | "Pull down the notification shade and choose File transfer" |
| Another app holds it | `libusb_claim_interface` returns busy | "Quit OpenMTP / Android File Transfer" |
| MTP wedged (see rule 2) | Opening a session fails even after a USB reset, twice in a row | "Unplug and replug the cable" |

Apple devices (vendor `05AC`) are skipped outright: an iPhone's camera interface has the same class
as an MTP one, and claiming it would take the phone away from Photos.

After a replug, this phone defaults back to **no data transfer** and asks again.

## Measured on this app's engine, 15 Sep

Same phone and Mac, through `MTPDevice` and the app's own `PhoneBrowser`, `UploadPlan` and
`TransferQueue`, driven from a test harness instead of clicks.

| | Result |
|---|---|
| First listing after unlocking | 25.4 s (the old 30 s timeout would have failed on a slightly fuller phone; it is 120 s) |
| DCIM/Camera, 337 items | 0.37–0.45 s |
| 1,000 small files (4–256 KiB) onto the phone | 59 ms each (p90 79 ms, max 148 ms), no slowdown past 211 |
| 512 MiB onto the phone, twice | 17.8–18.2 MiB/s |
| 512 MiB back to the Mac, twice | 37.1–38.9 MiB/s, SHA-256 identical |
| 325 camera photos (2,062 MiB) to the Mac | 63.6 s: 32.4 MiB/s, 196 ms each → 1,000 photos ≈ 3.3 min |
| Download stopped at 50 %, copied again | `.part` held 256 MiB; the rest came at 37.9 MiB/s, SHA-256 identical |
| Upload stopped at 25 % and at 90 % | Returned in 0.3–0.4 s, nothing left on the phone, next upload fine |
| Device info in File transfer mode | Vendor extension 6 / `microsoft.com` present |
| Folder drops, both clash questions both ways, a 200 GiB drop refused up front, folder delete | All checks passed |
| 4,404,019,200 bytes (4.2 GiB) onto the phone and back | 237 s up (17.7 MiB/s), 111 s down (37.9 MiB/s), size exact, SHA-256 identical |

## Speed (prototype, 11–12 Sep)

Asymmetric, so estimates have to be per direction:

| Operation | Rate |
|---|---|
| Phone → Mac, large file | **29.4 MiB/s** |
| Mac → phone, large file | **15–16 MiB/s** (the phone's flash is the limit) |
| Phone → Mac, 324 real photos (2 GB) | 25.9 MiB/s, 4.1 files/s → **1,000 photos ≈ 4 minutes** |
| Pushing small files, events drained | 53 ms each |
| Deleting | ~25 ms each |

Per-file overhead costs about 12% against one large file, so there is no reason to batch.

39 consecutive 512 MiB round trips (~20 GB) ran without a single error and without drift.

## Resuming an interrupted copy

Works in both directions, verified byte for byte with SHA-256:

- **Upload:** `GetObjectPropList` reports exactly how many bytes the phone already holds, so
  `BeginEditObject` + `SendPartialObject` restart at the real boundary rather than a guess.
  Measured 19.4 MiB/s — faster than a plain push.
- **Download:** stitched `GetPartialObject64` slices run at 28.8 MiB/s, no slower than one large read.

Both were measured on the prototype. **The app resumes downloads only:** a copy to the Mac is
written as `<name>.part`, and copying the same file into the same folder again continues it. An
upload that fails is deleted from the phone; `PTPSession.resumeSend` exists, but nothing calls it yet.

Files over 4 GiB work: 4,402,341,478 bytes transferred, size reported correctly, and a read past the
4 GiB mark returned the right bytes.

## File names

| Case | What the phone does |
|---|---|
| Vietnamese NFC/NFD, emoji, leading space, trailing dot, hidden, 0 bytes, 244-byte name | Accepted unchanged |
| `: ? * " < > \| \` | Rejected, nothing left behind |
| Name of 255 bytes or more | `Invalid Parameter` |
| Exact duplicate name | Second write rejected |
| **Differing only in case** | ⚠️ **Both names appear in the listing, but they share one file on disk — the second write silently destroys the first** |
| NFC and NFD spellings of one name | Coexist as two entries that look identical |

Every name comparison therefore runs through `MTPEntry.comparisonKey`, which normalises to NFC and
lowercases. `MTPName.problem(with:among:)` applies the rest before anything is written.

MIUI exposes its own trash over MTP as `.trashed-<deadline>-<original name>`; those are hidden.

## Dates

Uploads **lose the original date** — the phone stamps its own clock, and `SetObjectProp
DateModified` returns `ObjectProp Not Supported` (`0xA80A`).

Dates are preserved in the phone → Mac direction only, where the app sets the file's modification
time itself. Do not promise otherwise.

MTP dates arrive as `20260912T134522`, occasionally with fractional seconds or a `Z` suffix.

## Thumbnails

`GetThumb` is **not** a thumbnail service. It returns the thumbnail already embedded in a file's EXIF
header and nothing else — not the phone's media library, and nothing to do with which folder the file
sits in.

Proof: a camera photo copied off the phone and back on under a new name served a thumbnail
immediately.

| Source | Result |
|---|---|
| Camera photos | 57/60, **14 ms each**, JPEG 240×320, 13–38 KB → 300 photos ≈ 4.1 s |
| Screenshots, downloaded images | No embedded thumbnail, so nothing comes back |
| Reading the first 64 KiB and extracting it ourselves | 9 ms each, found one in 17 of 20 |

The app tries `GetThumb`, then the 64 KiB route, then fetches the whole file and scales it with
`CGImageSourceCreateThumbnailAtIndex`. Roughly 15% of a real phone reaches that third route.

It runs as a second pass, after every visible tile already has something in it, and skips files over
40 MiB. Verified with JPEGs written by `NSBitmapImageRep`, which embed no EXIF thumbnail at all: the
first two routes return nothing for them and the grid still fills.

## Free space

The phone does **not** refuse a file that will not fit: it accepted a declared 13.45 GiB with 5.45 GiB
free and started taking data.

Its reported free space is exact and updates immediately — uploading 64 MiB dropped it by exactly
64.1 MiB, and deleting gave the same amount back. So checking before starting is reliable, and the
app does.

Cancelling mid-transfer leaves nothing behind.

## Odds and ends

- Photos pushed over MTP **do** appear in the MIUI gallery, from `DCIM/Camera`, `Pictures` and
  `Download` alike.
- `Android/data` is fully readable **and writable** on MIUI: all 100 app folders are listed and new
  folders can be created inside. No blocked-folder screen is needed, but it is a dangerous place and
  should be marked as one.
- The test phone has a single storage and no SD card, so **the removable-storage path is untested**.

## The icon

`Resources/icon.html` is the source, drawn in CSS because this Mac has no image tooling, and
`Scripts/make-icon.sh` photographs it with headless Chrome and builds `Resources/Porterage.icns`.
Chrome writes the screenshot and then does not exit, so the script stops it once the file appears.

The mark is the website's: three cells of a meter, the first two reached and the third not. They
rise rather than standing equal — three equal bars with two lit read as a pause button.

Redrawn 17 Sep 2026, when the site was rebuilt in macOS's own idiom. The old plate was brushed
metal behind a hard 4 px edge; this one is lit the way current macOS icons are, one soft light from
above on a cool graphite body, a hairline rim that only catches that light along the top, and the
lit cells throwing a glow back onto the plate. No texture at all — the depth is gradient and
shadow. Recoloured from amber to system blue the same evening, when the site went to a single hue
and the amber mark was the last second colour on it.

The released 0.1.1 dmg still carries the old icon. This one ships with whatever comes next; do not
rebuild and replace the published 0.1.1 asset, because its SHA-256 is recorded and was verified
against a re-download.

## libusb

One context for the whole process, created on first use and never torn down. `libusb_exit` was caught
hanging inside `darwin_exit`, waiting on the hotplug thread, at the end of a `mtpcheck selftest` run —
in the app that call sits on the session queue, so a hang there would freeze the connection for good.
Searching for a phone used to create and destroy a context every three seconds.

A build signed with `--options runtime` (hardened runtime, ad-hoc, no entitlements) runs the whole
`selftest` against the phone and exits cleanly, so notarising needs no USB entitlement.

## Shipping

The app links `libusb-1.0.a` statically, so a built `.app` has no Homebrew dependency —
`otool -L` shows only system libraries.

`Scripts/build-libusb.sh` compiles libusb from source into `Vendor/`, universal and against the same
minimum macOS the app claims. Homebrew's own archive is built for whatever macOS the build machine
runs: linking that into a binary claiming `LSMinimumSystemVersion 14.0` produces a stream of
`built for newer 'macOS' version` warnings and an app that can crash on macOS 14 and 15 — a failure
invisible on the machine that built it. Do not substitute it.

`Scripts/make-dmg.sh` refuses to package a binary that is not universal, for the same reason: an
Intel Mac downloading an arm64-only build gets a crash, not a message.

Verified on 0.1.0: `vtool -show-build` reports `minos 14.0` on both slices, `otool -L` lists only
system libraries, and the resulting disk image is 1.2 MB.

Still missing for a public release: a Developer ID certificate and notarisation. Measured against the
published 0.1.0 dmg, downloaded and given the quarantine flag a browser would set:

```
codesign -dvv  →  Signature=adhoc, TeamIdentifier=not set
spctl -a -vvv  →  rejected
stapler validate → does not have a ticket stapled to it
```

So macOS **refuses** the first launch — it does not merely warn. And since macOS 15 the Control-click
→ Open shortcut no longer overrides this, so the instruction to give users is: try to open it, let it
be blocked, then System Settings → Privacy & Security → Open Anyway, which appears there for about an
hour after the attempt. Anywhere this app or its website tells a user how to get in, it must say
that, not the old shortcut.

## Still outstanding

On the test phone (Redmi 9T):

- [ ] Pull the cable mid-copy, and close the MacBook lid mid-copy. — `mtpcheck soak`, pull whenever.
- [ ] Find why a screen lock stopped a running copy on 15 Sep but not on 12 Sep. — `mtpcheck soak`,
  lock the screen mid-cycle. This is the one that is load-bearing: the app and the website both tell
  the user to keep the phone unlocked purely because the question is open.
- [ ] Confirm Photo transfer (PTP) mode is reported as such. — switch the phone over, `mtpcheck mode`.
- [ ] An iPhone plugged in beside the phone: it must be ignored, and the phone still found.

On a phone from another maker (nothing here has ever met one):

- [ ] Connect, list, copy both ways. Samsung is the one competitors report most trouble with.
- [ ] A phone with a microSD card: the app reads only the first storage, so the card is invisible.
- [ ] A phone holding far more than 34,000 objects, for the first-listing wait.
- [ ] Whether macOS's `ptpcamerad` takes the interface first, as reported against other MTP apps.

In the app, no phone needed:

- [ ] An installed copy still cannot learn that a new version exists on its own. The menu opens the
  releases page; a check over the network would cost the app's "no network connections" claim.
