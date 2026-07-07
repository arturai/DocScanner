# Brother MFC‑J5720DW — network scan protocols

This documents how the scanner is driven over the network, based on live packet
captures of Windows **ControlCenter** (`logs/Brotherwireshark*.pcapng`) and of our
own app. The device speaks **two** unrelated scan protocols; DocScanner uses both.

| Need | Protocol | Port | Notes |
|------|----------|------|-------|
| Flatbed, 1‑sided ADF | **WSD / WS‑Scan** (SOAP + MTOM) | 80 | Works well; see `lib/scanner/wsd_scanner.dart`. |
| **2‑sided (duplex) ADF** | **Brother proprietary** | **54921** | The only way to trigger duplex; `lib/scanner/brother_native_scanner.dart`. |

Why two: the device's WSD firmware reports `ADFSupportsDuplex=0` and **silently
ignores `InputSource=ADFDuplex`, falling back to the flatbed**. Duplex is only
reachable through Brother's proprietary port‑54921 protocol (the one the Windows
driver uses for all scanner/fax features).

---

## 1. Proprietary protocol (TCP 54921)

Plain TCP, no TLS. The client connects, sends a few **ESC commands**, the device
replies `+OK 200`, then streams image data and **keeps the socket open** (the
client decides when it's done — see framing below).

### Command syntax
Each command is:

```
0x1B  <letter>  0x0A   (ESC + letter + newline)
KEY=VALUE 0x0A         (zero or more parameter lines)
...
0x80                   (terminator)
```

Observed commands, in order:

| Cmd | Bytes | Purpose |
|-----|-------|---------|
| `ESC‑K` | `1B 4B 0A 80` | Reset/prepare session (sent before 1‑sided & flatbed scans; the 2‑sided capture omitted it). |
| `ESC‑I` | `1B 49 0A` + params + `80` | Init: announce resolution/mode/source; device replies `+OK 200`. |
| `ESC‑X` | `1B 58 0A` + params + `80` | Start scan with the full parameter set. |

### Parameters (on ESC‑I / ESC‑X)

| Key | Meaning | Example |
|-----|---------|---------|
| `R=` | Resolution, x,y dpi | `R=300,300` |
| `M=` | Color mode | `M=CGRAY` (colour) |
| `C=` | Compression | `C=JPEG` |
| `J=` | JPEG quality preset | `J=MIN` |
| `B=` | Brightness | `B=50` |
| `N=` | Contrast | `N=50` |
| `A=` | Scan area `x1,y1,x2,y2` in pixels @ resolution | `A=35,0,2499,3484` |
| `D=` | **Source / sides** — see below | `D=DUP` |
| `E=`,`G=` | Reserved (0) | `E=0 G=0` |

### `D=` is the source/duplex switch (the key finding)

| `D=` | Meaning |
|------|---------|
| `DUP` | **ADF, two‑sided (duplex)** |
| `SIN` | Single‑sided — used for **both** 1‑sided ADF and flatbed |

For `D=SIN` the device auto‑selects ADF vs flatbed by **paper presence** (paper in
the feeder → ADF multi‑page; otherwise → flatbed single page). ControlCenter still
varies the `A=` origin per intended source (ADF `A=35,0,2499,3484`, flatbed
`A=0,0,2464,3484`), but the source distinction is the device's, not `D`'s.

---

## 2. The three scans compared (from `Brotherwireshark2.pcapng`)

### 2‑sided (`D=DUP`) — stream 1, 3 double‑sided sheets → 6 sides
```
ESC-I: R=300,300  M=CGRAY  D=DUP
ESC-X: R=300,300  M=CGRAY  C=JPEG  J=MIN  B=50  N=50  A=35,0,2499,3484  D=DUP  E=0  G=0
```
Server: `+OK 200\r\n`, a param header, then JPEG data in blocks, ending with
`0x80`. **The device scans a sheet's front and back simultaneously and streams
both interleaved**, tagging every block with a per-side ID (block header byte 3).
Each side ID's blocks, gathered on their own, form one complete standalone JPEG.
See §3 — this de-interleaving is the crux of getting duplex right.

### 1‑sided (`D=SIN`) — stream 2, multi‑page ADF
```
ESC-K
ESC-I: R=300,300  M=CGRAY  D=SIN
ESC-X: R=300,300  M=CGRAY  C=JPEG  J=MIN  B=50  N=50  A=35,0,2499,3484  D=SIN  E=0  G=0
```
Server: `+OK 200\r\n`, then per page a `0xD0` page‑start marker + param header +
`0x64` data blocks; pages separated by `0x82`, ending `0x80`.

### Flatbed (`D=SIN`) — stream 7, single page
```
ESC-K
ESC-I: R=300,300  M=CGRAY  D=SIN
ESC-X: R=300,300  M=CGRAY  C=JPEG  J=MIN  B=50  N=50  A=0,0,2464,3484  D=SIN  E=0  G=0
```
Server: same framing as 1‑sided but a single page.

> Note: 1‑sided and flatbed are **already handled by the WSD path** in the app.
> They are documented here only for completeness / future unification.

---

## 3. Data‑stream framing (printer → client)

```
"+OK 200\r\n"
0x00 <len> 0x00 <ascii csv> 0x00         param header, e.g. "300,300,1,213,2527,0,0,"
{ data block } ...                       image blocks, tagged per side (see below)
0x82 <9 bytes>                           periodic flush marker (10 bytes total)
0x80                                     end-of-document
```

> **`0x82` is NOT a page boundary.** In duplex the two sides are interleaved, so a
> `0x82` can fall in the middle of either side's data. It's a periodic flush and
> should be skipped — the real page split comes from the per-side ID (below), not
> from `0x82`.

**Data block** (carries the JPEG bytes):
```
0x64  0x07 0x00  <ID>  0x00 0x84  <row: u16 LE>  0x00 0x00  <len: u16 LE>   then <len> payload bytes
 │                └ byte 3 = side / image ID (see §3.1)                      └ 0xFFF4 (65524) for full blocks
 └ 12-byte header total
```
The client knows the transfer is finished when it reaches the top‑level `0x80`
(the device does **not** close the socket; an idle timeout is a safety fallback).

### 3.1 Side‑ID de‑interleaving — the key to duplex (verified on real scans)

The duplex ADF has two CIS sensors and scans a sheet's **front and back at the
same time**, streaming both **interleaved** block‑by‑block. **Header byte 3 is a
per‑side image ID.** Every block for a given side carries the same ID; a run of
IDs in a 3‑sheet duplex capture looks like:

```
2:2 1:3 2:1 1:2 … |0x82| 1:… |0x82| 4:… 3:… |0x82| 3:… |0x82| 6:… 5:… |0x82| 5:… |0x82|
      ↑ ID 2 (back of sheet 1) and ID 1 (front of sheet 1) interleaved in one run
```

**Reconstruction algorithm (what the app does):**
1. Skip `+OK…\r\n` and the param header.
2. Walk blocks; **group each block's payload by header byte 3 (the ID)**, keeping
   first‑seen order. Skip `0x82` (10 bytes); stop at `0x80`.
3. Each ID's concatenated payload is **one complete self‑contained JPEG**
   (its own SOI…EOI). No header borrowing needed.
4. **Order the sides for reading:** each physical sheet uses a consecutive pair of
   IDs. Sort IDs ascending, take them in pairs, and within a pair put the
   **larger** stream first — the content‑bearing FRONT is far larger than a
   (often blank) BACK. This yields the natural order
   `front1, back1, front2, back2, …`.

**Why the naive approach failed:** gluing all blocks in arrival order concatenates
two different images' entropy under one JPEG header. libjpeg still decodes it —
luma (text) stays readable — but the DC predictor drifts across the spliced‑in
foreign data, producing **grey / magenta colour bands** across the page. Grouping
by ID first makes every side decode cleanly.

### Image format
- **JPEG** (`C=JPEG`), colour (`M=CGRAY`, 3 components), JFIF, 2550×3510 px for
  Letter @300 dpi (2464×3484 for A4).
- Each side is a normal complete baseline JPEG once de‑interleaved. (An earlier
  theory about "abbreviated JPEG backs reusing the front's header" was a
  side‑effect of mis‑attributing interleaved blocks; with correct ID grouping
  every side carries its own SOI…SOS header. The app keeps a header‑reuse
  fallback only for defensiveness against a truncated stream.)

---

## 4. Implementation status (this app)

- `BrotherNativeScanner` (`lib/scanner/brother_native_scanner.dart`) connects to
  54921, sends `ESC‑I`/`ESC‑X` with `D=DUP` (mirroring ControlCenter exactly —
  note `ESC‑X` does **not** repeat `M=`), detects completion at the `0x80` marker
  (30 s idle fallback so a feed pause between sheets can't truncate a page),
  de‑frames the `0x64` blocks, and **de‑interleaves pages by side ID** (§3.1).
- Routing: only **Document Feeder + 2‑Sided** uses this transport; flatbed and
  1‑sided ADF stay on WSD.
- Diagnostics: with `kLogWsdProtocol=true`, the raw 54921 stream is dumped to
  `…/Containers/com.github.arturai.docScanner/Data/tmp/brother_native_last.bin`
  for offline analysis.
- **Status: working.** Verified end‑to‑end — a live 3‑sheet 2‑sided scan produces
  all 6 sides, correct order, no colour banding, decoding cleanly in Skia and in
  strict libjpeg (`djpeg`).
