import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../scanner/pdf_builder.dart';
import '../scanner/scan_document.dart';
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
  bool _isDiscovering = false;
  bool _isScanning = false;
  bool _isSaving = false;
  String? _error;
  String? _statusMessage;

  // Document state
  final ScanDocument _document = ScanDocument();
  int _selectedPageIndex = -1;

  // Settings
  int _dpi = 300;
  String _colorMode = 'RGB24';
  String _inputSource = 'Platen';
  bool _saveAsPdf = true;

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
        _document.addPage(imageBytes);
        _selectedPageIndex = _document.pageCount - 1;
        _isScanning = false;
        _statusMessage =
            'Page ${_document.pageCount} scanned (${(imageBytes.length / 1024).toStringAsFixed(0)} KB) '
            '[${wsd.lastDiagnostics}]';
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _error = 'Scan failed: $e';
        _statusMessage = null;
      });
    }
  }

  Future<void> _saveDocument() async {
    if (_document.isEmpty) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      if (_saveAsPdf) {
        final pdfBytes = await PdfBuilder.buildFromImages(
          _document.pages.map((p) => p.imageBytes).toList(),
        );

        final location = await getSaveLocation(
          suggestedName: 'DocScanner_${_timestamp()}.pdf',
          acceptedTypeGroups: [
            const XTypeGroup(label: 'PDF', extensions: ['pdf']),
          ],
          initialDirectory: _defaultSaveDir(),
        );

        if (location != null) {
          await File(location.path).writeAsBytes(pdfBytes);
          setState(() {
            _statusMessage = 'Saved ${_document.pageCount} page(s) to ${location.path}';
          });
        }
      } else {
        // Save individual JPGs
        int saved = 0;
        for (int i = 0; i < _document.pageCount; i++) {
          final location = await getSaveLocation(
            suggestedName: 'DocScanner_${_timestamp()}_page${i + 1}.jpg',
            acceptedTypeGroups: [
              const XTypeGroup(label: 'JPEG', extensions: ['jpg', 'jpeg']),
            ],
            initialDirectory: _defaultSaveDir(),
          );

          if (location != null) {
            await File(location.path).writeAsBytes(_document.pages[i].imageBytes);
            saved++;
          } else {
            break; // User cancelled
          }
        }
        if (saved > 0) {
          setState(() {
            _statusMessage = 'Saved $saved image(s)';
          });
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Save failed: $e';
      });
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  String _defaultSaveDir() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/Documents';
  }

  String _timestamp() {
    return DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  }

  void _removePage(int index) {
    setState(() {
      _document.removePage(index);
      if (_document.isEmpty) {
        _selectedPageIndex = -1;
      } else if (_selectedPageIndex >= _document.pageCount) {
        _selectedPageIndex = _document.pageCount - 1;
      }
    });
  }

  void _clearDocument() {
    setState(() {
      _document.clear();
      _selectedPageIndex = -1;
      _statusMessage = null;
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
          // Right panel: preview + page thumbnails
          Expanded(
            child: _buildMainPanel(),
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
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'Resolution (DPI)', border: OutlineInputBorder()),
                  initialValue: _dpi,
                  items: _capabilities!.supportedResolutions
                      .map((r) => DropdownMenuItem(value: r, child: Text('$r DPI')))
                      .toList(),
                  onChanged: (v) => setState(() => _dpi = v ?? 300),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Color Mode', border: OutlineInputBorder()),
                  initialValue: _colorMode,
                  items: _capabilities!.supportedColorModes
                      .map((c) => DropdownMenuItem(value: c, child: Text(_colorModeLabel(c))))
                      .toList(),
                  onChanged: (v) => setState(() => _colorMode = v ?? 'RGB24'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Source', border: OutlineInputBorder()),
                  initialValue: _inputSource,
                  items: _capabilities!.supportedInputSources
                      .map((s) => DropdownMenuItem(value: s, child: Text(_sourceLabel(s))))
                      .toList(),
                  onChanged: (v) => setState(() => _inputSource = v ?? 'Platen'),
                ),
              ],
            ),
          ),

        // Output format toggle
        if (_capabilities != null) ...[
          const Divider(),
          SwitchListTile(
            title: const Text('Save as PDF'),
            subtitle: Text(_saveAsPdf ? 'Multi-page PDF document' : 'Individual JPG images'),
            value: _saveAsPdf,
            onChanged: (v) => setState(() => _saveAsPdf = v),
          ),
        ],

        const Spacer(),

        // Status / error bar
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
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.scanner),
                label: Text(_isScanning
                    ? 'Scanning...'
                    : _document.isEmpty
                        ? 'Scan'
                        : 'Add Page'),
                onPressed: _selectedScanner != null && !_isScanning ? _scan : null,
              ),
              if (_document.isNotEmpty) ...[
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: _isSaving
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save),
                  label: Text(_isSaving
                      ? 'Saving...'
                      : _saveAsPdf
                          ? 'Save PDF (${_document.pageCount} page${_document.pageCount > 1 ? 's' : ''})'
                          : 'Save JPG${_document.pageCount > 1 ? 's' : ''}'),
                  onPressed: !_isSaving ? _saveDocument : null,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear All'),
                  onPressed: _clearDocument,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMainPanel() {
    return Column(
      children: [
        // Large preview
        Expanded(
          child: _buildPreview(),
        ),
        // Page thumbnails strip
        if (_document.isNotEmpty) _buildThumbnailStrip(),
      ],
    );
  }

  Widget _buildPreview() {
    if (_isScanning) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 48, height: 48, child: CircularProgressIndicator()),
            SizedBox(height: 16),
            Text('Scanning page...', style: TextStyle(fontSize: 16)),
          ],
        ),
      );
    }

    if (_document.isNotEmpty && _selectedPageIndex >= 0 && _selectedPageIndex < _document.pageCount) {
      return InteractiveViewer(
        minScale: 0.1,
        maxScale: 5.0,
        child: Center(
          child: Image.memory(
            _document.pages[_selectedPageIndex].imageBytes,
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

  Widget _buildThumbnailStrip() {
    return Container(
      height: 100,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: _document.pageCount,
        itemBuilder: (context, index) {
          final isSelected = index == _selectedPageIndex;
          return GestureDetector(
            onTap: () => setState(() => _selectedPageIndex = index),
            child: Container(
              width: 64,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Stack(
                children: [
                  // Thumbnail image
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      _document.pages[index].imageBytes,
                      fit: BoxFit.cover,
                      width: 64,
                      height: 84,
                    ),
                  ),
                  // Page number
                  Positioned(
                    bottom: 2,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                  ),
                  // Delete button
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => _removePage(index),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                          ),
                        ),
                        child: const Icon(Icons.close, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
