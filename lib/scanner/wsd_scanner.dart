import 'dart:io';
import 'dart:typed_data';

import 'wsd_discovery.dart';

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

    return ScannerCapabilities.fromSoapResponse(response);
  }

  /// Start a scan job and return the scanned image bytes (JPEG).
  Future<Uint8List> scan({
    ScanSettings settings = const ScanSettings(),
  }) async {
    // Step 1: CreateScanJob — must match the Brother's expected ScanTicket format
    final createResponse = await _soapRequest(
      action: 'http://schemas.microsoft.com/windows/2006/08/wdp/scan/CreateScanJob',
      body: '''
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
          <wscn:ImagesToTransfer>1</wscn:ImagesToTransfer>
          <wscn:InputSource>${settings.inputSource}</wscn:InputSource>
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
              <wscn:ColorProcessing>${settings.colorMode}</wscn:ColorProcessing>
              <wscn:Resolution>
                <wscn:Width>${settings.dpi}</wscn:Width>
                <wscn:Height>${settings.dpi}</wscn:Height>
              </wscn:Resolution>
            </wscn:MediaFront>
          </wscn:MediaSides>
        </wscn:DocumentParameters>
      </wscn:ScanTicket>
    </wscn:CreateScanJobRequest>''',
    );

    // Extract JobId from response
    final jobId = _extractTag(createResponse, 'JobId');
    if (jobId == null) {
      final preview = createResponse.toString();
      final truncated = preview.length > 500 ? '${preview.substring(0, 500)}...' : preview;
      throw ScanException('No JobId in response. Raw:\n$truncated');
    }

    final jobToken = _extractTag(createResponse, 'JobToken') ?? '';

    // Step 2: RetrieveImage
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
    return _extractMtomBinary(imageResponse);
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

    final client = HttpClient();
    try {
      final request = await client.postUrl(_serviceUrl);
      request.headers.set('Content-Type', 'application/soap+xml; charset=utf-8; action="$action"');
      request.write(envelope);
      final response = await request.close();

      if (returnRawBytes) {
        final bytes = await response.fold<List<int>>(
          [],
          (previous, element) => previous..addAll(element),
        );
        return Uint8List.fromList(bytes);
      } else {
        return await response.transform(const SystemEncoding().decoder).join();
      }
    } finally {
      client.close();
    }
  }

  /// Extract image bytes from an MTOM/XOP multipart MIME response.
  /// The Brother returns multipart/related with a SOAP XML part followed
  /// by a binary image part. We find the JPEG header (FF D8 FF) and extract
  /// everything up to the closing MIME boundary.
  Uint8List _extractMtomBinary(dynamic responseBytes) {
    if (responseBytes is! Uint8List) {
      throw ScanException('Expected raw bytes for MTOM response');
    }

    final bytes = responseBytes;

    // Find JPEG/EXIF header (FF D8 FF) or TIFF header
    for (int i = 0; i < bytes.length - 4; i++) {
      // JPEG magic: FF D8 FF
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
        return _extractUntilBoundary(bytes, i);
      }
      // TIFF LE: 49 49 2A 00
      if (bytes[i] == 0x49 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x2A && bytes[i + 3] == 0x00) {
        return _extractUntilBoundary(bytes, i);
      }
      // TIFF BE: 4D 4D 00 2A
      if (bytes[i] == 0x4D && bytes[i + 1] == 0x4D && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x2A) {
        return _extractUntilBoundary(bytes, i);
      }
    }

    throw ScanException('Could not find image data in MTOM response (${bytes.length} bytes)');
  }

  Uint8List _extractUntilBoundary(Uint8List bytes, int start) {
    // Find the closing MIME boundary: \r\n--<boundary>--
    // Scan backwards from the end for \r\n--
    for (int i = bytes.length - 1; i > start + 4; i--) {
      if (bytes[i] == 0x2D && bytes[i - 1] == 0x2D &&
          bytes[i - 2] == 0x0A && bytes[i - 3] == 0x0D) {
        // Found \r\n--, walk back to the \r\n before the boundary
        int end = i - 3;
        return Uint8List.sublistView(bytes, start, end);
      }
    }
    // No boundary found — return everything from image header to end
    return Uint8List.sublistView(bytes, start);
  }

  String? _extractTag(String xml, String tagName) {
    final match = RegExp('<[^>]*$tagName[^>]*>(.*?)</[^>]*$tagName>', dotAll: true).firstMatch(xml);
    return match?.group(1)?.trim();
  }
}

/// Scan settings for a WSD scan job.
class ScanSettings {
  final int dpi;
  final String colorMode; // RGB24, Grayscale8, BlackAndWhite1
  final String inputSource; // Platen (flatbed), ADF (auto document feeder)
  final String format; // exif (JPEG), tiff-single-g4 (TIFF G4)
  final int widthInThousandths; // in 1/1000 inch
  final int heightInThousandths; // in 1/1000 inch

  const ScanSettings({
    this.dpi = 300,
    this.colorMode = 'RGB24',
    this.inputSource = 'Platen',
    this.format = 'exif',
    this.widthInThousandths = 8500, // 8.5 inches (Letter/A4)
    this.heightInThousandths = 11700, // 11.7 inches (A4)
  });

  ScanSettings copyWith({
    int? dpi,
    String? colorMode,
    String? inputSource,
    String? format,
  }) {
    return ScanSettings(
      dpi: dpi ?? this.dpi,
      colorMode: colorMode ?? this.colorMode,
      inputSource: inputSource ?? this.inputSource,
      format: format ?? this.format,
    );
  }
}

/// Parsed scanner capabilities.
class ScannerCapabilities {
  final List<int> supportedResolutions;
  final List<String> supportedColorModes;
  final List<String> supportedFormats;
  final List<String> supportedInputSources;
  final String statusText;

  ScannerCapabilities({
    this.supportedResolutions = const [100, 200, 300],
    this.supportedColorModes = const ['RGB24', 'Grayscale8', 'BlackAndWhite1'],
    this.supportedFormats = const ['exif'],
    this.supportedInputSources = const ['Platen'],
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

    // Parse status
    final status = RegExp(r'<wscn:ScannerState>(.*?)</wscn:ScannerState>').firstMatch(xml)?.group(1) ?? 'Unknown';

    return ScannerCapabilities(
      supportedResolutions: resolutions.isEmpty ? [100, 200, 300] : resolutions,
      supportedColorModes: colorModes.isEmpty ? ['RGB24', 'Grayscale8'] : colorModes,
      supportedFormats: formats.isEmpty ? ['exif'] : formats,
      supportedInputSources: sources.isEmpty ? ['Platen'] : sources,
      statusText: status,
    );
  }
}

class ScanException implements Exception {
  final String message;
  ScanException(this.message);

  @override
  String toString() => 'ScanException: $message';
}
