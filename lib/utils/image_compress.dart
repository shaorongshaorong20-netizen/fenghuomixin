// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

class PreparedImageUploadData {
  final Uint8List bytes;
  final String mimeType;
  final bool compressed;

  const PreparedImageUploadData({
    required this.bytes,
    required this.mimeType,
    required this.compressed,
  });

  String get dataUrl => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

enum _SourceImageKind {
  jpeg,
  heic,
  png,
  gif,
  other,
}

Future<PreparedImageUploadData?> prepareMobileImageUploadData(
  XFile file, {
  int skipCompressionBytes = 2 * 1024 * 1024,
  int targetUploadBytes = 5 * 1024 * 1024,
  int maxUploadBytes = 6 * 1024 * 1024,
}) async {
  try {
    final Uint8List originalBytes = await file.readAsBytes();
    if (originalBytes.isEmpty) return null;

    final String originalName = file.name.isNotEmpty ? file.name : file.path;
    final String originalMime = _mimeTypeFromName(originalName);
    final _SourceImageKind kind = _sourceImageKindFromName(originalName);

    if (originalBytes.length <= skipCompressionBytes ||
        originalBytes.length <= targetUploadBytes) {
      return PreparedImageUploadData(
        bytes: originalBytes,
        mimeType: originalMime,
        compressed: false,
      );
    }

    final img.Image? decoded = await _decodeImageForCompression(originalBytes);
    if (decoded == null) {
      return PreparedImageUploadData(
        bytes: originalBytes,
        mimeType: originalMime,
        compressed: false,
      );
    }

    final bool hasTransparentPixels = _hasTransparentPixels(decoded);

    final PreparedImageUploadData? prepared = switch (kind) {
      _SourceImageKind.jpeg => _compressAsJpegLike(
          decoded,
          targetUploadBytes: targetUploadBytes,
          maxUploadBytes: maxUploadBytes,
          outputMimeType: 'image/jpeg',
        ),
      _SourceImageKind.heic => _compressAsJpegLike(
          decoded,
          targetUploadBytes: targetUploadBytes,
          maxUploadBytes: maxUploadBytes,
          outputMimeType: 'image/jpeg',
        ),
      _SourceImageKind.png => _compressPngLike(
          decoded,
          targetUploadBytes: targetUploadBytes,
          maxUploadBytes: maxUploadBytes,
          hasTransparentPixels: hasTransparentPixels,
        ),
      _SourceImageKind.gif => _compressGifLike(
          decoded,
          targetUploadBytes: targetUploadBytes,
          maxUploadBytes: maxUploadBytes,
          hasTransparentPixels: hasTransparentPixels,
        ),
      _SourceImageKind.other => _compressOtherLike(
          decoded,
          targetUploadBytes: targetUploadBytes,
          maxUploadBytes: maxUploadBytes,
          hasTransparentPixels: hasTransparentPixels,
        ),
    };

    if (prepared == null || prepared.bytes.isEmpty) {
      return PreparedImageUploadData(
        bytes: originalBytes,
        mimeType: originalMime,
        compressed: false,
      );
    }

    if (prepared.bytes.length <= maxUploadBytes &&
        (originalBytes.length > maxUploadBytes ||
            prepared.bytes.length < originalBytes.length)) {
      return prepared;
    }

    return PreparedImageUploadData(
      bytes: originalBytes,
      mimeType: originalMime,
      compressed: false,
    );
  } catch (_) {
    return null;
  }
}

_SourceImageKind _sourceImageKindFromName(String name) {
  final String ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => _SourceImageKind.jpeg,
    'heic' => _SourceImageKind.heic,
    'png' => _SourceImageKind.png,
    'gif' => _SourceImageKind.gif,
    _ => _SourceImageKind.other,
  };
}

String _mimeTypeFromName(String name) {
  final String ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'jpeg' => 'image/jpeg',
    'jpg' => 'image/jpeg',
    _ => 'image/jpeg',
  };
}

Future<img.Image?> _decodeImageForCompression(Uint8List bytes) async {
  ui.Codec? codec;
  ui.Image? frameImage;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    frameImage = frame.image;
    final ByteData? rgba = await frameImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    return img.Image.fromBytes(
      width: frameImage.width,
      height: frameImage.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  } catch (_) {
    return null;
  } finally {
    frameImage?.dispose();
    codec?.dispose();
  }
}

bool _hasTransparentPixels(img.Image image) {
  if (!image.hasAlpha) return false;
  final num maxAlpha = image.maxChannelValue;
  for (final img.Pixel pixel in image) {
    if (pixel.a < maxAlpha) return true;
  }
  return false;
}

PreparedImageUploadData? _compressAsJpegLike(
  img.Image source, {
  required int targetUploadBytes,
  required int maxUploadBytes,
  required String outputMimeType,
}) {
  const List<double> scales = <double>[
    1.00,
    0.92,
    0.84,
    0.76,
    0.68,
    0.60,
    0.52,
    0.44,
    0.36,
    0.28,
    0.20,
  ];
  const List<int> qualities = <int>[90, 82, 74, 66, 58, 50, 42, 36];

  PreparedImageUploadData? bestUnderHard;
  PreparedImageUploadData? smallest;

  for (final double scale in scales) {
    final img.Image resized = _resizeImage(source, scale);
    for (final int quality in qualities) {
      final Uint8List bytes = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      final PreparedImageUploadData candidate = PreparedImageUploadData(
        bytes: bytes,
        mimeType: outputMimeType,
        compressed: true,
      );
      smallest = _pickSmaller(smallest, candidate);
      if (bytes.length <= targetUploadBytes) return candidate;
      if (bytes.length <= maxUploadBytes) {
        bestUnderHard ??= candidate;
      }
    }
  }

  return bestUnderHard ?? smallest;
}

PreparedImageUploadData? _compressPngLike(
  img.Image source, {
  required int targetUploadBytes,
  required int maxUploadBytes,
  required bool hasTransparentPixels,
}) {
  const List<double> scales = <double>[
    1.00,
    0.92,
    0.84,
    0.76,
    0.68,
    0.60,
    0.52,
    0.44,
    0.36,
    0.28,
    0.20,
    0.14,
  ];

  PreparedImageUploadData? bestPngUnderHard;
  PreparedImageUploadData? smallestPng;

  for (final double scale in scales) {
    final img.Image resized = _resizeImage(source, scale);
    final Uint8List bytes = Uint8List.fromList(img.encodePng(resized, level: 9));
    final PreparedImageUploadData candidate = PreparedImageUploadData(
      bytes: bytes,
      mimeType: 'image/png',
      compressed: true,
    );
    smallestPng = _pickSmaller(smallestPng, candidate);
    if (bytes.length <= targetUploadBytes) return candidate;
    if (bytes.length <= maxUploadBytes) {
      bestPngUnderHard ??= candidate;
    }
  }

  if (!hasTransparentPixels) {
    final PreparedImageUploadData? jpegCandidate = _compressAsJpegLike(
      source,
      targetUploadBytes: targetUploadBytes,
      maxUploadBytes: maxUploadBytes,
      outputMimeType: 'image/jpeg',
    );
    if (jpegCandidate != null && jpegCandidate.bytes.length <= maxUploadBytes) {
      return jpegCandidate;
    }
  }

  return bestPngUnderHard ?? smallestPng;
}

PreparedImageUploadData? _compressGifLike(
  img.Image source, {
  required int targetUploadBytes,
  required int maxUploadBytes,
  required bool hasTransparentPixels,
}) {
  return _compressPngLike(
    source,
    targetUploadBytes: targetUploadBytes,
    maxUploadBytes: maxUploadBytes,
    hasTransparentPixels: hasTransparentPixels,
  );
}

PreparedImageUploadData? _compressOtherLike(
  img.Image source, {
  required int targetUploadBytes,
  required int maxUploadBytes,
  required bool hasTransparentPixels,
}) {
  if (hasTransparentPixels) {
    return _compressPngLike(
      source,
      targetUploadBytes: targetUploadBytes,
      maxUploadBytes: maxUploadBytes,
      hasTransparentPixels: true,
    );
  }

  return _compressAsJpegLike(
    source,
    targetUploadBytes: targetUploadBytes,
    maxUploadBytes: maxUploadBytes,
    outputMimeType: 'image/jpeg',
  );
}

img.Image _resizeImage(img.Image source, double scale) {
  if (scale >= 0.999) {
    return img.Image.from(source, noAnimation: true);
  }

  final int width = math.max(320, (source.width * scale).round());
  final int height = math.max(320, (source.height * scale).round());
  if (width == source.width && height == source.height) {
    return img.Image.from(source, noAnimation: true);
  }

  return img.copyResize(
    source,
    width: math.min(width, source.width),
    height: math.min(height, source.height),
    interpolation: img.Interpolation.average,
  );
}

PreparedImageUploadData? _pickSmaller(
  PreparedImageUploadData? current,
  PreparedImageUploadData next,
) {
  if (current == null) return next;
  return next.bytes.length < current.bytes.length ? next : current;
}
