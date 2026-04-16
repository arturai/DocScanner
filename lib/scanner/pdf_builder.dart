import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// An ImageProvider that embeds raw JPEG bytes directly into the PDF
/// using PdfImage.jpeg, bypassing the `image` package decoder which
/// can't handle certain JPEG variants (e.g. B&W scans from Brother).
class _DirectJpegProvider extends pw.ImageProvider {
  _DirectJpegProvider(this.bytes)
      : super(
          PdfJpegInfo(bytes).width,
          PdfJpegInfo(bytes).height,
          PdfJpegInfo(bytes).orientation,
          null,
        );

  final Uint8List bytes;

  @override
  PdfImage buildImage(pw.Context context, {int? width, int? height}) {
    return PdfImage.jpeg(context.document, image: bytes);
  }
}

class PdfBuilder {
  /// Creates a PDF document from a list of JPEG image bytes (one image per page).
  /// Each page is A4, with the image centered and scaled to fit.
  static Future<Uint8List> buildFromImages(List<Uint8List> pages) async {
    final doc = pw.Document();

    for (final imageBytes in pages) {
      final image = _imageProvider(imageBytes);
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

  /// Create an image provider: use direct JPEG embedding for JPEG data
  /// (avoids the `image` package decoder), fall back to MemoryImage for other formats.
  static pw.ImageProvider _imageProvider(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return _DirectJpegProvider(bytes);
    }
    return pw.MemoryImage(bytes);
  }
}
