import 'dart:typed_data';

/// A single scanned page.
class ScannedPage {
  final Uint8List imageBytes;
  final DateTime timestamp;

  ScannedPage({required this.imageBytes, required this.timestamp});
}

/// A multi-page document being assembled from scans.
class ScanDocument {
  final List<ScannedPage> pages = [];

  void addPage(Uint8List imageBytes) {
    pages.add(ScannedPage(imageBytes: imageBytes, timestamp: DateTime.now()));
  }

  void removePage(int index) {
    if (index >= 0 && index < pages.length) {
      pages.removeAt(index);
    }
  }

  void clear() => pages.clear();

  bool get isEmpty => pages.isEmpty;
  bool get isNotEmpty => pages.isNotEmpty;
  int get pageCount => pages.length;
}
