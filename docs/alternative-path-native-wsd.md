# Alternative Path: Native Swift WSD Client

This document describes **Path B** — a fallback approach to be used only if
Path A (Swift GUI wrapping `sane-airscan` via Homebrew) proves unreliable or
unmaintainable.

## Context

The primary architecture (Path A) depends on the user having SANE installed
via Homebrew:

```
brew install sane-backends
```

and then driving `scanimage` with the `airscan:w0:Brother MFC-J5720DW` device.
This works because `sane-airscan` implements the WSD (Web Services for
Devices) protocol that the Brother MFC-J5720DW speaks.

Path B removes the Homebrew/SANE dependency by implementing the WSD protocol
directly in Swift inside the app bundle. The app becomes fully self-contained
— install the `.app`, nothing else required.

## Why Path A might fail

Reasons we would consider switching to Path B:

- `sane-airscan` on macOS has reliability issues with this specific device
- Homebrew dependency is too painful for the intended users
- We want to ship through channels (e.g. Mac App Store) that forbid external
  tooling dependencies
- `sane-backends` stops being maintained on macOS
- Performance issues with out-of-process `scanimage` invocation

## What Path B requires

### Protocols to implement

1. **WS-Discovery** — UDP multicast on `239.255.255.250:3702`, SOAP-formatted
   `Probe` and `ProbeMatches` messages. Finds the scanner on the LAN.
2. **WS-Transfer / WS-MetadataExchange** — `Get` requests to fetch the
   scanner's service metadata (endpoints, capabilities).
3. **WS-Scan** (the scanner-specific profile) — `GetScannerElements`,
   `CreateScanJob`, `RetrieveImage` SOAP operations over HTTP.
4. **MTOM/XOP** — binary image data is returned as a multipart MIME message
   with SOAP envelope + binary parts referenced via XOP `Include` elements.

### Swift stack needed

- `Network.framework` for UDP multicast (WS-Discovery)
- `URLSession` for SOAP over HTTP
- XML parsing: `XMLParser` (built-in, SAX-style) or a proper XML library
- SOAP envelope construction: custom (there's no Swift SOAP library worth
  using; hand-roll the envelopes)
- MTOM/XOP parser for the response containing the scanned image
- UUID generation for SOAP message IDs (`Foundation.UUID`)

### Reference implementation

The authoritative reference is **sane-airscan**:
<https://github.com/alexpevzner/sane-airscan>

Specifically the WSD code paths under `airscan-wsdd.c`, `airscan-ws.c`, and
`airscan-soap.c`. Approximately 3,000–4,000 lines of C that would need to be
understood and partially translated to Swift. You do **not** need to port
everything — only the message flows actually used by the MFC-J5720DW.

### Testing

- Wireshark capture of a working scan from Linux (via sane-airscan) is
  essential — it becomes the ground-truth reference for every SOAP request
  and response.
- A unit test harness that replays captured responses against the parser.
- An integration test that hits the real printer on the LAN.

## Rough effort estimate

- **WS-Discovery**: 1–2 days
- **Metadata exchange + capability parsing**: 2–3 days
- **ScanJob creation + image retrieval (MTOM/XOP)**: 3–5 days
- **Error handling, cancellation, reliability hardening**: 3–5 days
- **Testing against the real printer, debugging protocol quirks**: open-ended

Total: **2–4 weeks of focused work** for someone familiar with Swift and
networking, longer if either is new.

## Migration plan from Path A

When/if we move to Path B:

1. Keep Path A code on a branch in case Path B has regressions.
2. Add a `Scanner` protocol abstraction in the app so the transport (SANE vs.
   native WSD) is swappable.
3. Implement `NativeWSDScanner` conforming to that protocol.
4. Ship Path B behind a setting initially; let it prove itself before
   removing the SANE path.
5. Once stable, delete the SANE path and drop the Homebrew prerequisite from
   the README.

## Decision criteria

Don't switch to Path B unless Path A has a concrete, repeatable failure mode
that can't be fixed. Path B is **significantly more code** to own and debug,
and SOAP/WSD protocol debugging against an old device is not fun.
