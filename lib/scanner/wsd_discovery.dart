import 'dart:async';
import 'dart:io';
import 'dart:convert';

/// Discovers WSD (Web Services for Devices) scanners on the local network
/// using WS-Discovery multicast probes.
class WsdDiscovery {
  static const _multicastAddress = '239.255.255.250';
  static const _multicastPort = 3702;

  /// Sends a WS-Discovery Probe and collects scanner responses.
  /// Returns a list of [DiscoveredScanner] within [timeout].
  static Future<List<DiscoveredScanner>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final scanners = <DiscoveredScanner>[];
    final messageId = 'urn:uuid:${_generateUuid()}';

    final probe = _buildProbeMessage(messageId);

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );

      socket.broadcastEnabled = true;
      socket.multicastHops = 4;

      // Send the probe
      socket.send(
        utf8.encode(probe),
        InternetAddress(_multicastAddress),
        _multicastPort,
      );

      final completer = Completer<List<DiscoveredScanner>>();

      // Listen for responses
      final subscription = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket!.receive();
          if (datagram != null) {
            final response = utf8.decode(datagram.data);
            final scanner = _parseProbeMatch(response, datagram.address);
            if (scanner != null && !scanners.any((s) => s.address == scanner.address)) {
              scanners.add(scanner);
            }
          }
        }
      });

      // Wait for timeout then return results
      Timer(timeout, () {
        subscription.cancel();
        if (!completer.isCompleted) {
          completer.complete(scanners);
        }
      });

      return completer.future;
    } catch (e) {
      socket?.close();
      rethrow;
    }
  }

  static String _buildProbeMessage(String messageId) {
    return '''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope
  xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
  xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
  xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
  <soap:Header>
    <wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>
    <wsa:MessageID>$messageId</wsa:MessageID>
  </soap:Header>
  <soap:Body>
    <wsd:Probe>
      <wsd:Types>wscn:ScanDeviceType</wsd:Types>
    </wsd:Probe>
  </soap:Body>
</soap:Envelope>''';
  }

  static DiscoveredScanner? _parseProbeMatch(String xml, InternetAddress source) {
    // Extract device name from ProbeMatch response
    // Look for <wsd:XAddrs> which contains the device's HTTP endpoint
    final xAddrsMatch = RegExp(r'<[^>]*XAddrs[^>]*>(.*?)</[^>]*XAddrs>', dotAll: true).firstMatch(xml);
    final typesMatch = RegExp(r'<[^>]*Types[^>]*>(.*?)</[^>]*Types>', dotAll: true).firstMatch(xml);

    final xAddrs = xAddrsMatch?.group(1)?.trim();
    final types = typesMatch?.group(1)?.trim() ?? '';

    // Only accept devices that advertise scan capability
    if (!types.contains('ScanDeviceType') && !types.contains('scan')) {
      return null;
    }

    return DiscoveredScanner(
      address: source.address,
      xAddrs: xAddrs ?? 'http://${source.address}:8017',
      name: 'Scanner at ${source.address}',
      rawResponse: xml,
    );
  }

  static String _generateUuid() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return '${random.toRadixString(16)}-0000-0000-0000-000000000000';
  }
}

/// A scanner found via WS-Discovery.
class DiscoveredScanner {
  final String address;
  final String xAddrs;
  final String name;
  final String rawResponse;

  DiscoveredScanner({
    required this.address,
    required this.xAddrs,
    required this.name,
    required this.rawResponse,
  });

  @override
  String toString() => '$name ($address)';
}
