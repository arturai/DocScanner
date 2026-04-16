import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class PdfBuilder {
  /// Creates a PDF document from a list of JPEG image bytes (one image per page).
  /// Each page is A4, with the image centered and scaled to fit.
  static Future<Uint8List> buildFromImages(List<Uint8List> pages) async {
    final doc = pw.Document();

    for (final imageBytes in pages) {
      final image = pw.MemoryImage(imageBytes);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Center(
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
        ),
      );
    }

    return doc.save();
  }
}
