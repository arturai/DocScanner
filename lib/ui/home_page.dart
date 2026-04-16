import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../scanner/wsd_discovery.dart';
import '../scanner/wsd_scanner.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<DiscoveredScanner> _scanners = [];
  DiscoveredScanner? _selectedScanner;
  ScannerCapabilities? _capabilities;
  Uint8List? _scannedImage;
  bool _isDiscovering = false;
  bool _isScanning = false;
  String? _error;
  String? _statusMessage;

  // Settings
  int _dpi = 300;
  String _colorMode = 'RGB24';
  String _inputSource = 'Platen';

  @override
  void initState() {
    super.initState();
    _discoverScanners();
  }

  Future<void> _discoverScanners() async {
    setState(() {
      _isDiscovering = true;
      _error = null;
      _statusMessage = 'Searching for scanners...';
    });

    try {
      final scanners = await WsdDiscovery.discover();
      setState(() {
        _scanners = scanners;
        _isDiscovering = false;
        _statusMessage = scanners.isEmpty
            ? 'No scanners found. Make sure your scanner is on and connected to the same network.'
            : 'Found ${scanners.length} scanner(s)';
      });
    } catch (e) {
      setState(() {
        _isDiscovering = false;
        _error = 'Discovery failed: $e';
        _statusMessage = null;
      });
    }
  }

  Future<void> _selectScanner(DiscoveredScanner scanner) async {
    setState(() {
      _selectedScanner = scanner;
      _statusMessage = 'Fetching scanner capabilities...';
    });

    try {
      final wsd = WsdScanner(scanner);
      final caps = await wsd.getCapabilities();
      setState(() {
        _capabilities = caps;
        _dpi = caps.supportedResolutions.contains(300) ? 300 : caps.supportedResolutions.first;
        _colorMode = caps.supportedColorModes.first;
        _inputSource = caps.supportedInputSources.first;
        _statusMessage = 'Scanner ready (${caps.statusText})';
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to get capabilities: $e';
        _statusMessage = null;
      });
    }
  }

  Future<void> _scan() async {
    if (_selectedScanner == null) return;

    setState(() {
      _isScanning = true;
      _error = null;
      _statusMessage = 'Scanning...';
    });

    try {
      final wsd = WsdScanner(_selectedScanner!);
      final imageBytes = await wsd.scan(
        settings: ScanSettings(
          dpi: _dpi,
          colorMode: _colorMode,
          inputSource: _inputSource,
        ),
      );

      setState(() {
        _scannedImage = imageBytes;
        _isScanning = false;
        _statusMessage = 'Scan complete (${(imageBytes.length / 1024).toStringAsFixed(0)} KB)';
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _error = 'Scan failed: $e';
        _statusMessage = null;
      });
    }
  }

  Future<void> _saveImage() async {
    if (_scannedImage == null) return;

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final home = Platform.environment['HOME'] ?? '/tmp';
    final path = '$home/Documents/DocScanner_$timestamp.jpg';

    await File(path).writeAsBytes(_scannedImage!);
    setState(() {
      _statusMessage = 'Saved to $path';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Left panel: scanner selection + settings
          SizedBox(
            width: 300,
            child: _buildSidePanel(),
          ),
          const VerticalDivider(width: 1),
          // Right panel: scan preview
          Expanded(
            child: _buildPreviewPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildSidePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Scanner selection
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Scanners', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: _isDiscovering
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    onPressed: _isDiscovering ? null : _discoverScanners,
                    tooltip: 'Refresh',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_scanners.isEmpty && !_isDiscovering)
                const Text('No scanners found', style: TextStyle(color: Colors.grey)),
              ..._scanners.map((s) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.scanner),
                    title: Text(s.name),
                    subtitle: Text(s.address),
                    selected: _selectedScanner == s,
                    onTap: () => _selectScanner(s),
                  )),
            ],
          ),
        ),
        const Divider(),

        // Scan settings
        if (_capabilities != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                // Resolution
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'Resolution (DPI)', border: OutlineInputBorder()),
                  value: _dpi,
                  items: _capabilities!.supportedResolutions
                      .map((r) => DropdownMenuItem(value: r, child: Text('$r DPI')))
                      .toList(),
                  onChanged: (v) => setState(() => _dpi = v ?? 300),
                ),
                const SizedBox(height: 12),
                // Color mode
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Color Mode', border: OutlineInputBorder()),
                  value: _colorMode,
                  items: _capabilities!.supportedColorModes
                      .map((c) => DropdownMenuItem(value: c, child: Text(_colorModeLabel(c))))
                      .toList(),
                  onChanged: (v) => setState(() => _colorMode = v ?? 'RGB24'),
                ),
                const SizedBox(height: 12),
                // Input source
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Source', border: OutlineInputBorder()),
                  value: _inputSource,
                  items: _capabilities!.supportedInputSources
                      .map((s) => DropdownMenuItem(value: s, child: Text(_sourceLabel(s))))
                      .toList(),
                  onChanged: (v) => setState(() => _inputSource = v ?? 'Platen'),
                ),
              ],
            ),
          ),

        const Spacer(),

        // Status bar
        if (_error != null)
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.errorContainer,
              child: SingleChildScrollView(
                child: SelectableText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 11),
                ),
              ),
            ),
          ),
        if (_statusMessage != null && _error == null)
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              _statusMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          ),

        // Action buttons
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                icon: _isScanning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.scanner),
                label: Text(_isScanning ? 'Scanning...' : 'Scan'),
                onPressed: _selectedScanner != null && !_isScanning ? _scan : null,
              ),
              if (_scannedImage != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  onPressed: _saveImage,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewPanel() {
    if (_scannedImage != null) {
      return InteractiveViewer(
        minScale: 0.1,
        maxScale: 5.0,
        child: Center(
          child: Image.memory(
            _scannedImage!,
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.document_scanner_outlined, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'Select a scanner and press Scan',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  String _colorModeLabel(String mode) {
    return switch (mode) {
      'RGB24' => 'Color',
      'Grayscale8' => 'Grayscale',
      'BlackAndWhite1' => 'Black & White',
      _ => mode,
    };
  }

  String _sourceLabel(String source) {
    return switch (source) {
      'Platen' => 'Flatbed',
      'ADF' => 'Document Feeder',
      _ => source,
    };
  }
}
