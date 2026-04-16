# DocScanner

A macOS document scanner app that communicates directly with WSD (Web Services for Devices) scanners over the local network. Built specifically to work with scanners that macOS doesn't natively support — such as the Brother MFC-J5720DW — by implementing the WSD/WS-Scan protocol in pure Dart, bypassing the need for SANE, vendor drivers, or Apple's ImageCaptureCore.

## How it works

DocScanner implements three WSD protocols from scratch:

1. **WS-Discovery** — sends multicast probes on the local network to find scanners, then fetches device metadata (model name, capabilities) via WS-Transfer
2. **WS-Scan** — communicates with the scanner to negotiate scan settings (resolution, color mode, paper size), create scan jobs, and retrieve scanned images via MTOM/XOP multipart responses
3. **PDF generation** — assembles scanned pages into multi-page PDF documents with raw JPEG embedding

No external scanning libraries, no vendor drivers, no SANE dependency. The app talks directly to the scanner over HTTP/SOAP.

## Features

- Automatic scanner discovery on the local network
- Scan settings: resolution (DPI), color mode (Color, Grayscale, B&W), source (Flatbed, ADF)
- Multi-page document scanning — scan pages one at a time, preview each, then save all as one PDF
- Save as multi-page PDF (default) or individual JPG files
- Native macOS save dialog with configurable default save folder
- Page thumbnails with reordering preview
- Open saved folder directly from the app
- Light and dark mode support

## System requirements

- macOS Tahoe (26.0) or later
- Flutter 3.41+ (for building from source)
- A WSD-compatible scanner on the same network (tested with Brother MFC-J5720DW)

## Installation

### From GitHub Releases

1. Download `DocScanner.zip` from the latest release
2. Unzip the file
3. Drag `DocScanner.app` to `/Applications`
4. On first launch, macOS will block the app (unsigned). Run this once in Terminal:
   ```
   xattr -dr com.apple.quarantine /Applications/DocScanner.app
   ```
5. Launch DocScanner from Applications

### Build from source

```bash
# Clone the repository
git clone https://github.com/arturai/DocScanner.git
cd DocScanner

# Install dependencies
flutter pub get

# Build the macOS app
flutter build macos

# The built app is at:
# build/macos/Build/Products/Release/DocScanner.app

# Copy to Applications
cp -r build/macos/Build/Products/Release/DocScanner.app /Applications/

# Remove quarantine flag
xattr -dr com.apple.quarantine /Applications/DocScanner.app
```

### Run in development mode

```bash
flutter run -d macos
```

## Usage

1. Make sure your scanner is powered on and connected to the same Wi-Fi network
2. Launch DocScanner — it automatically discovers scanners on the network
3. Select your scanner from the list
4. Adjust scan settings (DPI, color mode, source) as needed
5. Press **Scan** to scan a page
6. Press **Add Page** to scan additional pages into the same document
7. Press **Save PDF** to save all pages as a single PDF file
8. Use **Open Folder** to view saved files in Finder

## Author

Artur Pawlak ([@arturai](https://github.com/arturai))

## License

This project is open source. See LICENSE file for details.
