import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'wsd_discovery.dart';

/// When true, the full WSD protocol exchange (requests, responses, faults) is
/// logged to stderr and to a file in the temp dir for inspection. Diagnostic aid
/// for aligning our ScanTicket with what the device's DefaultScanTicket expects;
/// flip to true when debugging scanner communication.
const bool kLogWsdProtocol = false;

void _logWsd(String label, String content) {
  if (!kLogWsdProtocol) return;
  final block = '\n===== WSD $label =====\n$content\n===== end $label =====\n';
  stderr.writeln(block);
  // The macOS app is sandboxed and its stderr isn't easily captured, so also
  // append to a file inside the sandbox container's temp dir for inspection.
  try {
    final f = File('${Directory.systemTemp.path}/docscanner_wsd_debug.log');
    f.writeAsStringSync(block, mode: FileMode.append, flush: true);
  } catch (_) {
    // best-effort diagnostics only
  }
}

class _SoapRawResponse {
  final Uint8List bodyBytes;
  final String? contentType;
  _SoapRawResponse(this.bodyBytes, this.contentType);
}

/// Performs scanning operations via WS-Scan (WSD) protocol.
///
/// Flow:
/// 1. Connect to a [DiscoveredScanner]
/// 2. Fetch scanner capabilities via GetScannerElements
/// 3. Create a scan job via CreateScanJob
/// 4. Retrieve the scanned image via RetrieveImage
class WsdScanner {
  final DiscoveredScanner device;
  late final Uri _serviceUrl;

  WsdScanner(this.device) {
    _serviceUrl = Uri.parse(device.xAddrs);
  }

  /// Fetch scanner capabilities (color modes, resolutions, paper sizes).
  Future<ScannerCapabilities> getCapabilities() async {
    final response = await _soapRequest(
      action: 'http://schemas.microsoft.com/windows/2006/08/wdp/scan/GetScannerElements',
      body: '''
    <wscn:GetScannerElementsRequest xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
      <wscn:RequestedElements>
        <wscn:Name>wscn:ScannerConfiguration</wscn:Name>
        <wscn:Name>wscn:ScannerStatus</wscn:Name>
        <wscn:Name>wscn:DefaultScanTicket</wscn:Name>
      </wscn:RequestedElements>
    </wscn:GetScannerElementsRequest>''',
    );

    _logWsd('GetScannerElements RESPONSE (ScannerConfiguration + DefaultScanTicket)', response.toString());

    return ScannerCapabilities.fromSoapResponse(response);
  }

  /// Start a scan and return the scanned page images (JPEG bytes).
  ///
  /// For the flatbed (Platen) this returns a single page. For the automatic
  /// document feeder (ADF) it scans one sheet per job and repeats until the
  /// feeder is empty, returning every sheet.
  ///
  /// The Brother firmware rejects `ImagesToTransfer=0` ("scan all") outright, so
  /// the ADF job requests a large per-job image cap and pages are pulled with
  /// repeated RetrieveImage calls until the feeder reports it is exhausted.
  Future<List<Uint8List>> scan({
    ScanSettings settings = const ScanSettings(),
  }) async {
    // BlackAndWhite1 with exif format produces G3FAX data (not real JPEG).
    // Use Grayscale8 instead — the scanner produces a standard JPEG.
    final effectiveColorMode = settings.colorMode == 'BlackAndWhite1'
        ? 'Grayscale8'
        : settings.colorMode;

    final isAdf = settings.inputSource == 'ADF';
    // Two-sided ADF is a distinct InputSource value (ADFDuplex), NOT ADF plus a
    // MediaBack block. See WS-Scan spec: InputSource ∈ {Platen, ADF, ADFDuplex}.
    final effectiveSource = isAdf && settings.duplex ? 'ADFDuplex' : settings.inputSource;

    // ImagesToTransfer is a hard per-job image cap on this Brother firmware.
    // 0 ("all") is rejected outright, and 1 caps the job at a single page. The
    // ADF feeds the whole stack under one job, so request a large count and stop
    // when the feeder is exhausted (JobIdNotFound / NoImagesAvailable). Platen
    // scans exactly one page.
    final imagesToTransfer = isAdf ? 999 : 1;

    final ticket = '''
    <wscn:CreateScanJobRequest xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
      <wscn:ScanTicket>
        <wscn:JobDescription>
          <wscn:JobName>DocScanner Scan</wscn:JobName>
          <wscn:JobOriginatingUserName>DocScanner</wscn:JobOriginatingUserName>
          <wscn:JobInformation>Scan from DocScanner</wscn:JobInformation>
        </wscn:JobDescription>
        <wscn:DocumentParameters>
          <wscn:Format>${settings.format}</wscn:Format>
          <wscn:CompressionQualityFactor>100</wscn:CompressionQualityFactor>
          <wscn:ImagesToTransfer>$imagesToTransfer</wscn:ImagesToTransfer>
          <wscn:InputSource>$effectiveSource</wscn:InputSource>
          <wscn:ContentType>Auto</wscn:ContentType>
          <wscn:InputSize>
            <wscn:InputMediaSize>
              <wscn:Width>${settings.widthInThousandths}</wscn:Width>
              <wscn:Height>${settings.heightInThousandths}</wscn:Height>
            </wscn:InputMediaSize>
          </wscn:InputSize>
          <wscn:Exposure>
            <wscn:ExposureSettings>
              <wscn:Contrast>0</wscn:Contrast>
              <wscn:Brightness>0</wscn:Brightness>
              <wscn:Sharpness>0</wscn:Sharpness>
            </wscn:ExposureSettings>
          </wscn:Exposure>
          <wscn:Scaling>
            <wscn:ScalingWidth>100</wscn:ScalingWidth>
            <wscn:ScalingHeight>100</wscn:ScalingHeight>
          </wscn:Scaling>
          <wscn:Rotation>0</wscn:Rotation>
          <wscn:MediaSides>
            <wscn:MediaFront>
              <wscn:ScanRegion>
                <wscn:ScanRegionXOffset>0</wscn:ScanRegionXOffset>
                <wscn:ScanRegionYOffset>0</wscn:ScanRegionYOffset>
                <wscn:ScanRegionWidth>${settings.widthInThousandths}</wscn:ScanRegionWidth>
                <wscn:ScanRegionHeight>${settings.heightInThousandths}</wscn:ScanRegionHeight>
              </wscn:ScanRegion>
              <wscn:ColorProcessing>$effectiveColorMode</wscn:ColorProcessing>
              <wscn:Resolution>
                <wscn:Width>${settings.dpi}</wscn:Width>
                <wscn:Height>${settings.dpi}</wscn:Height>
              </wscn:Resolution>
            </wscn:MediaFront>
          </wscn:MediaSides>
        </wscn:DocumentParameters>
      </wscn:ScanTicket>
    </wscn:CreateScanJobRequest>''';

    // One CreateScanJob covers the whole batch: the device scans the entire ADF
    // stack into a single job and holds each page for a separate RetrieveImage.
    // We retrieve until the feeder is exhausted. (Creating a second job while the
    // first is still delivering pages is what the Brother rejects.)
    final createResponse = await _soapRequest(
      action: 'http://schemas.microsoft.com/windows/2006/08/wdp/scan/CreateScanJob',
      body: ticket,
    );

    final jobId = _extractTag(createResponse, 'JobId');
    if (jobId == null) {
      final preview = createResponse.toString();
      final truncated = preview.length > 500 ? '${preview.substring(0, 500)}...' : preview;
      throw ScanException('No JobId in response. Raw:\n$truncated');
    }
    final jobToken = _extractTag(createResponse, 'JobToken') ?? '';

    const maxPages = 200; // safety cap against a misbehaving device
    final pages = <Uint8List>[];

    while (pages.length < maxPages) {
      try {
        pages.add(await _retrieveImage(jobId, jobToken));
      } on ScanException catch (e) {
        // Once we have pages, an "empty feeder" fault means the ADF is exhausted
        // — normal completion. On the very first page it's a real error.
        if (pages.isNotEmpty && _isFeederExhausted(e)) break;
        rethrow;
      }
      if (!isAdf) break; // platen: single page
    }

    if (pages.isEmpty) {
      throw ScanException('Scan produced no images.');
    }

    return pages;
  }

  /// Retrieve one page image from an active scan job.
  Future<Uint8List> _retrieveImage(String jobId, String jobToken) async {
    final imageResponse = await _soapRequest(
      action: 'http://schemas.microsoft.com/windows/2006/08/wdp/scan/RetrieveImage',
      body: '''
    <wscn:RetrieveImageRequest xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
      <wscn:JobId>$jobId</wscn:JobId>
      <wscn:JobToken>$jobToken</wscn:JobToken>
      <wscn:DocumentDescription>
        <wscn:DocumentName>scan.jpg</wscn:DocumentName>
      </wscn:DocumentDescription>
    </wscn:RetrieveImageRequest>''',
      returnRawBytes: true,
    );

    // The response is MTOM/XOP — extract binary image from multipart MIME
    return _extractMtomBinary(imageResponse as _SoapRawResponse);
  }

  /// Whether a RetrieveImage fault means the batch is finished. After the last
  /// fed sheet this Brother closes the job, so the next RetrieveImage returns
  /// ClientErrorJobIdNotFound; the spec's ClientErrorNoImagesAvailable is the
  /// empty-feeder signal. Either one means "no more pages", not a failure.
  bool _isFeederExhausted(ScanException e) {
    final haystack = '${e.faultSubcode ?? ''} ${e.message}'.toLowerCase();
    return haystack.contains('noimagesavailable') ||
        haystack.contains('jobidnotfound') ||
        haystack.contains('nomoredocuments') ||
        haystack.contains('endofdocuments');
  }

  /// Send a SOAP request and return the response body.
  Future<dynamic> _soapRequest({
    required String action,
    required String body,
    bool returnRawBytes = false,
  }) async {
    final messageId = 'urn:uuid:${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';

    final envelope = '''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope
  xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">
  <soap:Header>
    <wsa:To>${_serviceUrl.toString()}</wsa:To>
    <wsa:Action>$action</wsa:Action>
    <wsa:MessageID>$messageId</wsa:MessageID>
    <wsa:ReplyTo>
      <wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address>
    </wsa:ReplyTo>
  </soap:Header>
  <soap:Body>
$body
  </soap:Body>
</soap:Envelope>''';

    final actionName = action.split('/').last;
    _logWsd('$actionName REQUEST → ${_serviceUrl.toString()}', envelope);

    final client = HttpClient();
    try {
      final request = await client.postUrl(_serviceUrl);
      request.headers.set('Content-Type', 'application/soap+xml; charset=utf-8; action="$action"');
      request.write(envelope);
      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorBody = await response.transform(const SystemEncoding().decoder).join();
        _logWsd('$actionName FAULT (HTTP ${response.statusCode})', errorBody);
        final subcode = _extractFaultSubcode(errorBody);
        final reason = _extractTag(errorBody, 'Text') ?? _extractTag(errorBody, 'Reason');
        // Prefer the parsed SOAP fault reason; fall back to the raw body so the
        // scanner's actual complaint is visible instead of just the XML preamble.
        final detail = reason ??
            (errorBody.length > 1500 ? '${errorBody.substring(0, 1500)}...' : errorBody);
        throw ScanException(
          'HTTP ${response.statusCode}: ${subcode != null ? '[$subcode] ' : ''}$detail',
          faultSubcode: subcode,
          statusCode: response.statusCode,
        );
      }

      if (returnRawBytes) {
        final contentType = response.headers.value('content-type');
        final bytes = await response.fold<List<int>>(
          [],
          (previous, element) => previous..addAll(element),
        );
        final result = Uint8List.fromList(bytes);
        _lastDiag = 'HTTP ${response.statusCode}, '
            'Content-Type: ${contentType ?? "null"}, '
            '${result.length} bytes';
        return _SoapRawResponse(result, contentType);
      } else {
        return await response.transform(const SystemEncoding().decoder).join();
      }
    } finally {
      client.close();
    }
  }

  /// Diagnostic info from the last raw request, exposed for UI debugging.
  String _lastDiag = '';
  String get lastDiagnostics => _lastDiag;

  /// Parse the MIME boundary string from a Content-Type header.
  String? _parseBoundary(String? contentType) {
    if (contentType == null) return null;
    final match = RegExp(r'boundary="?([^";]+)"?').firstMatch(contentType);
    return match?.group(1);
  }

  /// Extract image bytes from an MTOM/XOP multipart MIME response.
  /// The Brother returns multipart/related with a SOAP XML part followed
  /// by a binary image part. We find the JPEG header (FF D8 FF) and extract
  /// everything up to the closing MIME boundary.
  Uint8List _extractMtomBinary(_SoapRawResponse response) {
    final bytes = response.bodyBytes;
    final contentType = response.contentType ?? '';

    // Verify this is actually a multipart MTOM response
    if (!contentType.toLowerCase().contains('multipart')) {
      // Not multipart — likely a SOAP fault (e.g. the ADF feeder is now empty).
      final text = utf8.decode(bytes, allowMalformed: true);
      final subcode = _extractFaultSubcode(text);
      final fault = _extractTag(text, 'Text') ?? _extractTag(text, 'Reason') ?? _extractTag(text, 'Fault');
      throw ScanException(
        'Scanner returned non-multipart response '
        '(Content-Type: $contentType, ${bytes.length} bytes). '
        '${subcode != null ? "[$subcode] " : ""}'
        '${fault != null ? "Fault: $fault" : "Raw: ${text.substring(0, text.length.clamp(0, 300))}"}',
        faultSubcode: subcode,
      );
    }

    final boundary = _parseBoundary(contentType);
    Uint8List? boundaryBytes;
    if (boundary != null) {
      boundaryBytes = utf8.encode('\r\n--$boundary');
    }

    // Find JPEG/EXIF header (FF D8 FF) or TIFF header
    int imageOffset = -1;
    for (int i = 0; i < bytes.length - 4; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
        imageOffset = i;
        break;
      }
      if (bytes[i] == 0x49 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x2A && bytes[i + 3] == 0x00) {
        imageOffset = i;
        break;
      }
      if (bytes[i] == 0x4D && bytes[i + 1] == 0x4D && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x2A) {
        imageOffset = i;
        break;
      }
    }

    if (imageOffset < 0) {
      throw ScanException(
        'No image header found in MTOM response '
        '(${bytes.length} bytes, boundary: $boundary)',
      );
    }

    final extracted = _extractUntilBoundary(bytes, imageOffset, boundaryBytes: boundaryBytes);

    // Update diagnostics
    _lastDiag += ', boundary: ${boundary ?? "none"}, '
        'image@$imageOffset, extracted: ${extracted.length} bytes';

    // Validate: extracted data must start with a known image header
    if (extracted.length < 1024) {
      throw ScanException(
        'Extracted image too small (${extracted.length} bytes). '
        'Response was ${bytes.length} bytes. $_lastDiag',
      );
    }
    if (extracted[0] != 0xFF || extracted[1] != 0xD8) {
      final header = extracted.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      throw ScanException(
        'Extracted data does not start with valid image header: $header. '
        '$_lastDiag',
      );
    }

    return extracted;
  }

  /// Extract bytes from [start] to the next MIME boundary.
  /// Returns a COPY (not a view) to avoid memory lifecycle issues.
  Uint8List _extractUntilBoundary(Uint8List bytes, int start, {Uint8List? boundaryBytes}) {
    // If we have the real boundary from Content-Type, search for it exactly
    if (boundaryBytes != null) {
      for (int i = start; i <= bytes.length - boundaryBytes.length; i++) {
        bool match = true;
        for (int j = 0; j < boundaryBytes.length; j++) {
          if (bytes[i + j] != boundaryBytes[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          return bytes.sublist(start, i);
        }
      }
    }

    // Fallback: scan backwards from the end for \r\n--
    for (int i = bytes.length - 1; i > start + 4; i--) {
      if (bytes[i] == 0x2D && bytes[i - 1] == 0x2D &&
          bytes[i - 2] == 0x0A && bytes[i - 3] == 0x0D) {
        return bytes.sublist(start, i - 3);
      }
    }

    // No boundary found — return everything from image header to end
    return bytes.sublist(start);
  }

  String? _extractTag(String xml, String tagName) {
    final match = RegExp('<[^>]*$tagName[^>]*>(.*?)</[^>]*$tagName>', dotAll: true).firstMatch(xml);
    return match?.group(1)?.trim();
  }

  /// Extract the SOAP fault Subcode value (e.g. `wscn:ClientErrorNoImagesAvailable`)
  /// from a fault envelope. The subcode lives in `Subcode > Value`.
  String? _extractFaultSubcode(String xml) {
    final match = RegExp(r'Subcode>\s*<[^>]*Value[^>]*>(.*?)</', dotAll: true).firstMatch(xml);
    return match?.group(1)?.trim();
  }
}

/// Scan settings for a WSD scan job.
class ScanSettings {
  final int dpi;
  final String colorMode; // RGB24, Grayscale8, BlackAndWhite1
  final String inputSource; // Platen (flatbed), ADF (auto document feeder)
  final String format; // exif (JPEG), tiff-single-g4 (TIFF G4)
  final bool duplex; // two-sided scanning (ADF only)
  final int widthInThousandths; // in 1/1000 inch
  final int heightInThousandths; // in 1/1000 inch

  const ScanSettings({
    this.dpi = 300,
    this.colorMode = 'RGB24',
    this.inputSource = 'Platen',
    this.format = 'exif',
    this.duplex = false,
    this.widthInThousandths = 8500, // 8.5 inches (Letter/A4)
    this.heightInThousandths = 11700, // 11.7 inches (A4)
  });

  ScanSettings copyWith({
    int? dpi,
    String? colorMode,
    String? inputSource,
    String? format,
    bool? duplex,
    int? widthInThousandths,
    int? heightInThousandths,
  }) {
    return ScanSettings(
      dpi: dpi ?? this.dpi,
      colorMode: colorMode ?? this.colorMode,
      inputSource: inputSource ?? this.inputSource,
      format: format ?? this.format,
      duplex: duplex ?? this.duplex,
      widthInThousandths: widthInThousandths ?? this.widthInThousandths,
      heightInThousandths: heightInThousandths ?? this.heightInThousandths,
    );
  }
}

/// Parsed scanner capabilities.
class ScannerCapabilities {
  final List<int> supportedResolutions;
  final List<String> supportedColorModes;
  final List<String> supportedFormats;
  final List<String> supportedInputSources;
  final bool supportsDuplex;
  final String statusText;

  ScannerCapabilities({
    this.supportedResolutions = const [100, 200, 300],
    this.supportedColorModes = const ['RGB24', 'Grayscale8', 'BlackAndWhite1'],
    this.supportedFormats = const ['exif'],
    this.supportedInputSources = const ['Platen'],
    this.supportsDuplex = false,
    this.statusText = 'Unknown',
  });

  factory ScannerCapabilities.fromSoapResponse(String xml) {
    // Parse resolutions from PlatenResolutions or ADFResolutions
    final resolutions = <int>[];
    final resMatches = RegExp(r'<wscn:Width>(\d+)</wscn:Width>').allMatches(xml);
    for (final m in resMatches) {
      final val = int.tryParse(m.group(1) ?? '');
      // Filter to plausible scan resolutions (not pixel counts like 8500)
      if (val != null && val >= 50 && val <= 1200 && !resolutions.contains(val)) {
        resolutions.add(val);
      }
    }
    resolutions.sort();

    // Parse color modes
    final colorModes = <String>[];
    final colorMatches = RegExp(r'<wscn:ColorEntry>(.*?)</wscn:ColorEntry>').allMatches(xml);
    for (final m in colorMatches) {
      final val = m.group(1)?.trim();
      if (val != null && !colorModes.contains(val)) {
        colorModes.add(val);
      }
    }

    // Parse formats
    final formats = <String>[];
    final formatMatches = RegExp(r'<wscn:FormatValue>(.*?)</wscn:FormatValue>').allMatches(xml);
    for (final m in formatMatches) {
      final val = m.group(1)?.trim();
      if (val != null && !formats.contains(val)) {
        formats.add(val);
      }
    }

    // Parse input sources
    final sources = <String>[];
    if (xml.contains('<wscn:Platen>')) sources.add('Platen');
    if (xml.contains('<wscn:ADF>')) sources.add('ADF');

    // Duplex support is advertised by the VALUE of ADFSupportsDuplex (0/1) —
    // the element (and an ADFBack config block) is present even on simplex ADFs.
    final duplexMatch =
        RegExp(r'<wscn:ADFSupportsDuplex>\s*(\d)\s*</wscn:ADFSupportsDuplex>').firstMatch(xml);
    final supportsDuplex = duplexMatch?.group(1) == '1';

    // Parse status
    final status = RegExp(r'<wscn:ScannerState>(.*?)</wscn:ScannerState>').firstMatch(xml)?.group(1) ?? 'Unknown';

    return ScannerCapabilities(
      supportedResolutions: resolutions.isEmpty ? [100, 200, 300] : resolutions,
      supportedColorModes: colorModes.isEmpty ? ['RGB24', 'Grayscale8'] : colorModes,
      supportedFormats: formats.isEmpty ? ['exif'] : formats,
      supportedInputSources: sources.isEmpty ? ['Platen'] : sources,
      supportsDuplex: supportsDuplex,
      statusText: status,
    );
  }
}

class ScanException implements Exception {
  final String message;

  /// SOAP fault subcode (e.g. `wscn:ClientErrorNoImagesAvailable`), when present.
  final String? faultSubcode;

  /// HTTP status code that produced this fault, when applicable.
  final int? statusCode;

  ScanException(this.message, {this.faultSubcode, this.statusCode});

  @override
  String toString() => 'ScanException: $message';
}
