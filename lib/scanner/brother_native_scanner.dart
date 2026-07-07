import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'wsd_scanner.dart' show kLogWsdProtocol;

/// Scans via Brother's proprietary protocol on TCP 54921.
///
/// This is the protocol Brother's own Windows driver/ControlCenter uses, and —
/// unlike WSD — it can trigger the ADF's two-sided (duplex) hardware on the
/// MFC-J5720DW. It is used ONLY for the Document Feeder + 2-Sided path; flatbed
/// and 1-sided ADF continue to use WSD.
///
/// Flow (reverse-engineered from a ControlCenter capture):
///   1. TCP connect to host:54921
///   2. Send  ESC 'I' + "R=dpi,dpi / M=mode / D=source" lines + 0x80    (init)
///   3. Read  "+OK 200\r\n"
///   4. Send  ESC 'X' + full params + 0x80                              (start scan)
///   5. Read  data stream until the device closes the connection.
/// The data stream is JPEG page data wrapped in Brother's block framing.
class BrotherNativeScanner {
  final String host;
  static const int port = 54921;

  BrotherNativeScanner(this.host);

  static const int _esc = 0x1b;
  static const int _terminator = 0x80; // ends a command; also end-of-document in data

  /// Scan two-sided from the ADF and return every page image (JPEG bytes).
  Future<List<Uint8List>> scanDuplex({
    int dpi = 300,
    String mode = 'CGRAY', // color; matches what ControlCenter sends
  }) {
    return _scan(source: 'DUP', dpi: dpi, mode: mode);
  }

  Future<List<Uint8List>> _scan({
    required String source, // DUP (duplex), ADF (simplex), FB (flatbed)
    required int dpi,
    required String mode,
  }) async {
    // Mirror the scan area ControlCenter sends for the ADF (A=35,0,2499,3484 at
    // 300 dpi), scaled to the requested resolution — rather than computing our own.
    final ax1 = (35 * dpi / 300).round();
    final ax2 = (2499 * dpi / 300).round();
    final ay2 = (3484 * dpi / 300).round();
    final area = 'A=$ax1,0,$ax2,$ay2';

    final socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 10));

    // Accumulate in a growable list so we can parse framing incrementally in
    // O(n) without recopying. The device keeps the connection open after
    // sending everything, so completion is detected from the 0x80
    // end-of-document marker (with an idle-timeout fallback), NOT socket close.
    final buf = <int>[];
    final done = Completer<void>();
    Timer? idle;
    var scanStarted = false;

    void finish() { if (!done.isCompleted) done.complete(); }
    void armIdle() {
      idle?.cancel();
      // Completion is normally the 0x80 end-of-document marker. This idle timer
      // is only a fallback — keep it generous so mechanical feed pauses between
      // duplex sheets don't cut the stream short (which truncates page images).
      idle = Timer(const Duration(seconds: 30), () {
        if (scanStarted && buf.length > 1024) finish();
      });
    }

    // Incremental framing walk to spot the end-of-document marker promptly.
    var pos = 0;
    var okSeen = false;
    var paramSkipped = false;
    void tryDetectEnd() {
      if (!okSeen) {
        final nl = buf.indexOf(0x0a, pos);
        if (nl < 0) return;
        pos = nl + 1;
        okSeen = true;
      }
      if (!paramSkipped) {
        if (pos + 3 > buf.length) return;
        if (buf[pos] == 0x00 && buf[pos + 2] == 0x00) {
          final len = buf[pos + 1];
          final total = 3 + (len - 1) + 1;
          if (pos + total > buf.length) return;
          pos += total;
        }
        paramSkipped = true;
      }
      while (pos < buf.length) {
        final b0 = buf[pos];
        if (b0 == 0x64) {
          if (pos + 12 > buf.length) return;
          final len = buf[pos + 10] | (buf[pos + 11] << 8);
          if (pos + 12 + len > buf.length) return;
          pos += 12 + len;
        } else if (b0 == 0x82) {
          if (pos + 10 > buf.length) return;
          pos += 10;
        } else if (b0 == 0x80) {
          finish();
          return;
        } else {
          return; // unexpected — let idle/close handle it
        }
      }
    }

    socket.listen(
      (d) {
        buf.addAll(d);
        if (scanStarted) tryDetectEnd();
        armIdle();
      },
      onDone: finish,
      onError: (e) { if (!done.isCompleted) done.completeError(e); },
      cancelOnError: true,
    );

    try {
      // Step 1: init (ESC 'I')
      socket.add(_command('I', ['R=$dpi,$dpi', 'M=$mode', 'D=$source']));
      await socket.flush();

      // Step 2: wait for the "+OK 200" acknowledgement.
      await _waitUntil(
          () => done.isCompleted || latin1.decode(buf.take(32).toList()).contains('+OK'),
          timeout: const Duration(seconds: 15));
      if (!latin1.decode(buf.take(32).toList()).contains('+OK')) {
        throw BrotherScanException('Scanner did not acknowledge the scan request.');
      }

      // Step 3: start scan (ESC 'X'). Mirror ControlCenter's exact parameter set
      // — note it does NOT repeat M= here (the mode was set in ESC 'I').
      scanStarted = true;
      socket.add(_command('X', [
        'R=$dpi,$dpi',
        'C=JPEG',
        'J=MIN',
        'B=50',
        'N=50',
        area,
        'D=$source',
        'E=0',
        'G=0',
      ]));
      await socket.flush();
      armIdle();

      // Step 4: the device streams every page, then we detect the end marker.
      await done.future.timeout(const Duration(seconds: 180));
    } finally {
      idle?.cancel();
      socket.destroy();
    }

    final raw = Uint8List.fromList(buf);
    _dumpRaw(raw);
    final pages = _extractPages(raw);
    if (pages.isEmpty) {
      throw BrotherScanException('No pages received (${raw.length} bytes). '
          'Make sure paper is loaded in the document feeder.');
    }
    return pages;
  }

  /// Build an ESC command: 0x1b, letter, \n, then each param line + \n, then 0x80.
  Uint8List _command(String letter, List<String> params) {
    final b = BytesBuilder();
    b.addByte(_esc);
    b.add(ascii.encode(letter));
    b.addByte(0x0a);
    for (final p in params) {
      b.add(ascii.encode(p));
      b.addByte(0x0a);
    }
    b.addByte(_terminator);
    return b.toBytes();
  }

  Future<void> _waitUntil(bool Function() cond,
      {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        throw BrotherScanException('Timed out waiting for the scanner to respond.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// De-frame the Brother data stream into individual JPEG page images.
  ///
  /// Stream layout: "+OK 200\r\n", a param header (0x00 len 0x00 csv 0x00),
  /// then data blocks — 0x64 + 12-byte header + payload. 0x82 and 0x80 are
  /// page/document markers.
  ///
  /// The KEY to duplex: the device scans a sheet's front and back simultaneously
  /// and streams both **interleaved**, tagging every block with a side/image ID
  /// in header byte 3 (offset +3). Each ID's blocks, concatenated on their own,
  /// form one complete self-contained JPEG (its own SOI…EOI). Naively gluing all
  /// blocks in arrival order mixes two images' entropy and produces DC-drift
  /// colour banding — so we must DEMUX by that ID. (Reverse-engineered by
  /// diffing our stream against a known-good Windows ControlCenter capture;
  /// every de-multiplexed side then decodes cleanly in libjpeg.)
  ///
  /// Block header (12 bytes): `0x64 07 00 <ID> 00 84 <row u16> 00 00 <len u16>`
  /// — payload length is little-endian at header[10..12] (0xFFF4 for full
  /// blocks). Payload follows.
  List<Uint8List> _extractPages(Uint8List buf) {
    int pos = 0;
    final n = buf.length;

    // Skip the "+OK 200\r\n" status line if present.
    final okEnd = _indexOf(buf, ascii.encode('\r\n'), 0);
    if (okEnd >= 0 && okEnd < 16) pos = okEnd + 2;

    // Optional param header: 0x00 <len> 0x00 <ascii> 0x00
    if (pos + 3 < n && buf[pos] == 0x00 && buf[pos + 2] == 0x00) {
      final len = buf[pos + 1];
      pos += 3 + (len - 1) + 1;
    }

    // Demux block payloads by side/image ID (header byte 3), preserving the
    // order IDs first appear so we can pair fronts with backs afterwards.
    final groups = <int, BytesBuilder>{};
    final firstSeen = <int>[];
    while (pos < n) {
      final b0 = buf[pos];
      if (b0 == 0x64 && pos + 12 <= n) {
        final id = buf[pos + 3];
        final len = buf[pos + 10] | (buf[pos + 11] << 8);
        final end = (pos + 12 + len).clamp(0, n);
        final g = groups.putIfAbsent(id, () {
          firstSeen.add(id);
          return BytesBuilder();
        });
        g.add(buf.sublist(pos + 12, end));
        pos = pos + 12 + len;
      } else if (b0 == 0x82) {
        pos += 10; // page marker (10 bytes) — not a side boundary
      } else if (b0 == 0x80) {
        break; // end of document
      } else {
        break; // unexpected — stop cleanly with what we have
      }
    }

    final data = <int, Uint8List>{
      for (final e in groups.entries) e.key: e.value.toBytes()
    };

    // Reading order: a duplex sheet occupies a consecutive pair of IDs. Sort IDs
    // ascending, walk them in pairs, and within each pair put the larger stream
    // first — the content-bearing FRONT is far larger than a (often blank) BACK.
    final ids = data.keys.toList()..sort();
    final ordered = <int>[];
    for (var i = 0; i < ids.length; i += 2) {
      if (i + 1 < ids.length) {
        final a = ids[i], b = ids[i + 1];
        if (data[b]!.length > data[a]!.length) {
          ordered..add(b)..add(a);
        } else {
          ordered..add(a)..add(b);
        }
      } else {
        ordered.add(ids[i]);
      }
    }

    // Build a standalone JPEG per side. Each side is normally a complete JPEG
    // (SOI…EOI). As a safety net, a side that arrives header-less reuses the
    // most recent full side's header/tables (Brother's abbreviated-JPEG trick).
    Uint8List? lastHeader;
    final pages = <Uint8List>[];
    for (final id in ordered) {
      final seg = data[id]!;
      if (seg.length < 4) continue;
      final hasSoi = seg[0] == 0xFF && seg[1] == 0xD8;
      Uint8List jpeg;
      if (hasSoi) {
        lastHeader = _jpegHeader(seg);
        jpeg = _trimToEoi(seg);
      } else if (lastHeader != null) {
        final b = BytesBuilder()..add(lastHeader)..add(seg);
        jpeg = _trimToEoi(b.toBytes());
      } else {
        continue; // header-less before any header seen — skip
      }
      if (jpeg.length > 1024) pages.add(jpeg);
    }
    return pages;
  }

  /// The reusable header of a full JPEG: SOI up to and including the MAIN image's
  /// SOS header. Walks JPEG markers (skipping APP/DQT/DHT/SOF segments by their
  /// length) so an embedded EXIF thumbnail's SOS is skipped — a naive search for
  /// FF DA can false-match inside table data.
  Uint8List _jpegHeader(Uint8List j) {
    var p = 2; // after SOI (FF D8)
    while (p + 4 <= j.length) {
      if (j[p] != 0xFF) break;
      final marker = j[p + 1];
      if (marker == 0xDA) {
        final segLen = (j[p + 2] << 8) | j[p + 3];
        return j.sublist(0, (p + 2 + segLen).clamp(0, j.length));
      }
      // Standalone markers carry no length payload.
      if (marker == 0x01 || marker == 0xD8 || marker == 0xD9 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        p += 2;
        continue;
      }
      final segLen = (j[p + 2] << 8) | j[p + 3];
      p += 2 + segLen;
    }
    return j; // fallback
  }

  Uint8List _trimToEoi(Uint8List jpeg) {
    for (int i = jpeg.length - 2; i >= 0; i--) {
      if (jpeg[i] == 0xFF && jpeg[i + 1] == 0xD9) {
        return jpeg.sublist(0, i + 2);
      }
    }
    return jpeg;
  }

  int _indexOf(Uint8List hay, List<int> needle, int from) {
    outer:
    for (int i = from; i <= hay.length - needle.length; i++) {
      for (int j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// Dump the raw stream for offline analysis when protocol logging is on.
  void _dumpRaw(Uint8List raw) {
    if (!kLogWsdProtocol) return;
    try {
      final f = File('${Directory.systemTemp.path}/brother_native_last.bin');
      f.writeAsBytesSync(raw, flush: true);
    } catch (_) {}
  }
}

class BrotherScanException implements Exception {
  final String message;
  BrotherScanException(this.message);
  @override
  String toString() => 'BrotherScanException: $message';
}
