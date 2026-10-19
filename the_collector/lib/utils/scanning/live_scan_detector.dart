import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scan_recognition.dart';
import 'scan_card_lighting.dart';

@immutable
class LiveScanExcludedRegion {
  final String id;
  final List<ScanPoint> corners;

  const LiveScanExcludedRegion({required this.id, required this.corners});

  Map<String, Object> toMap() {
    if (!_validRegion(id, corners)) {
      throw const FormatException('Completed card geometry is invalid.');
    }
    return <String, Object>{
      'id': id,
      'corners': corners
          .map(
            (ScanPoint point) => <String, double>{'x': point.x, 'y': point.y},
          )
          .toList(growable: false),
    };
  }
}

@immutable
class LiveCardAppearanceSample {
  final String id;
  final List<ScanPoint> corners;
  final bool present;
  // RGB triplets, eight columns by twelve rows, from the frame's top left.
  final List<double> values;

  const LiveCardAppearanceSample({
    required this.id,
    required this.corners,
    required this.present,
    required this.values,
  });

  factory LiveCardAppearanceSample.fromMap(Map<Object?, Object?> value) {
    final Object? id = value['id'];
    final Object? points = value['corners'];
    final Object? present = value['present'];
    final Object? samples = value['values'];
    if (id is! String ||
        points is! List<Object?> ||
        present is! bool ||
        samples is! List<Object?>) {
      throw const FormatException('Completed card appearance is invalid.');
    }
    final List<ScanPoint> corners = points
        .map((Object? point) {
          if (point is! Map<Object?, Object?> ||
              point['x'] is! num ||
              point['y'] is! num) {
            throw const FormatException('Completed card geometry is invalid.');
          }
          return ScanPoint.fromMap(point);
        })
        .toList(growable: false);
    if (!_validRegion(id, corners) ||
        (samples.length != 288 && (present || samples.isNotEmpty)) ||
        samples.any(
          (Object? sample) =>
              sample is! num ||
              !sample.toDouble().isFinite ||
              sample < 0 ||
              sample > 1,
        )) {
      throw const FormatException('Completed card appearance is invalid.');
    }
    return LiveCardAppearanceSample(
      id: id,
      corners: List<ScanPoint>.unmodifiable(corners),
      present: present,
      values: List<double>.unmodifiable(
        samples.map((Object? sample) => (sample as num).toDouble()),
      ),
    );
  }
}

bool _validRegion(String id, List<ScanPoint> corners) {
  if (id.isEmpty ||
      id.length > 128 ||
      id.trim() != id ||
      id.runes.any((int rune) => rune < 32 || rune == 127) ||
      corners.length != 4) {
    return false;
  }
  double? direction;
  double twiceArea = 0;
  for (int index = 0; index < 4; index++) {
    final ScanPoint point = corners[index];
    if (!point.x.isFinite ||
        !point.y.isFinite ||
        point.x < 0 ||
        point.x > 1 ||
        point.y < 0 ||
        point.y > 1) {
      return false;
    }
    final ScanPoint next = corners[(index + 1) % 4];
    final ScanPoint after = corners[(index + 2) % 4];
    final double cross =
        (next.x - point.x) * (after.y - next.y) -
        (next.y - point.y) * (after.x - next.x);
    if (cross.abs() < 0.000001 ||
        (direction != null && cross * direction < 0)) {
      return false;
    }
    direction = cross;
    twiceArea += point.x * next.y - next.x * point.y;
  }
  return twiceArea.abs() >= 0.0002;
}

@immutable
class LiveCardDetection {
  final List<ScanPoint> corners;
  final double confidence;
  final double? sharpness;
  final ScanCardLighting? lighting;
  final List<ScanTextLine> lines;
  final List<String> warnings;

  const LiveCardDetection({
    required this.corners,
    required this.confidence,
    this.sharpness,
    this.lighting,
    this.lines = const <ScanTextLine>[],
    this.warnings = const <String>[],
  });

  factory LiveCardDetection.fromMap(Map<Object?, Object?> value) =>
      LiveCardDetection(
        corners: List<ScanPoint>.unmodifiable(
          (value['corners'] as List<Object?>).map(
            (Object? point) =>
                ScanPoint.fromMap(point as Map<Object?, Object?>),
          ),
        ),
        confidence: (value['confidence'] as num).toDouble(),
        sharpness: (value['sharpness'] as num?)?.toDouble(),
        lighting: ScanCardLighting.tryFromMap(value['lighting']),
        lines: List<ScanTextLine>.unmodifiable(
          (value['lines'] as List<Object?>? ?? const <Object?>[]).map(
            (Object? line) =>
                ScanTextLine.fromMap(line as Map<Object?, Object?>),
          ),
        ),
        warnings: List<String>.unmodifiable(
          (value['warnings'] as List<Object?>? ?? const <Object?>[])
              .cast<String>(),
        ),
      );
}

@immutable
class LiveScanFrame {
  final int width;
  final int height;
  final String orientationToken;
  final List<LiveCardDetection> cards;
  final List<LiveCardDetection> focusCandidates;
  final bool rectanglesSupported;
  final bool geometryOnly;
  final bool appearanceSamplingSupported;
  final List<LiveCardAppearanceSample> appearanceSamples;

  const LiveScanFrame({
    required this.width,
    required this.height,
    required this.orientationToken,
    required this.cards,
    this.focusCandidates = const <LiveCardDetection>[],
    required this.rectanglesSupported,
    this.geometryOnly = false,
    this.appearanceSamplingSupported = false,
    this.appearanceSamples = const <LiveCardAppearanceSample>[],
  });

  factory LiveScanFrame.fromMap(
    Map<Object?, Object?> value, {
    required String orientationToken,
  }) => LiveScanFrame(
    width: (value['width'] as num).toInt(),
    height: (value['height'] as num).toInt(),
    orientationToken: orientationToken,
    rectanglesSupported: value['rectanglesSupported'] as bool,
    geometryOnly: value['geometryOnly'] as bool? ?? false,
    appearanceSamplingSupported:
        value['appearanceSamplingSupported'] as bool? ?? false,
    appearanceSamples: _appearanceSamples(value),
    cards: List<LiveCardDetection>.unmodifiable(
      (value['cards'] as List<Object?>).map(
        (Object? card) =>
            LiveCardDetection.fromMap(card as Map<Object?, Object?>),
      ),
    ),
    focusCandidates: List<LiveCardDetection>.unmodifiable(
      (value['focusCandidates'] as List<Object?>? ?? const <Object?>[]).map(
        (Object? candidate) =>
            LiveCardDetection.fromMap(candidate as Map<Object?, Object?>),
      ),
    ),
  );

  static List<LiveCardAppearanceSample> _appearanceSamples(
    Map<Object?, Object?> value,
  ) {
    final Object? samples = value['appearanceSamples'];
    if (samples == null) return const <LiveCardAppearanceSample>[];
    if (samples is! List<Object?> || samples.length > 8) {
      throw const FormatException('Too many completed card appearances.');
    }
    final Set<String> ids = <String>{};
    return List<LiveCardAppearanceSample>.unmodifiable(
      samples.map((Object? item) {
        if (item is! Map<Object?, Object?>) {
          throw const FormatException('Completed card appearance is invalid.');
        }
        final LiveCardAppearanceSample sample =
            LiveCardAppearanceSample.fromMap(item);
        if (!ids.add(sample.id)) {
          throw const FormatException('Duplicate completed card appearance.');
        }
        return sample;
      }),
    );
  }
}

@immutable
class _FramePixelRequest {
  final int width;
  final int height;
  final Uint8List bytes;
  final int bytesPerRow;
  final int bytesPerPixel;
  final bool bgra;
  final int edge;

  const _FramePixelRequest({
    required this.width,
    required this.height,
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
    required this.bgra,
    required this.edge,
  });
}

Map<String, Object> _prepareFramePixels(_FramePixelRequest request) =>
    NativeLiveCardDetector.boundedFramePixels(
      width: request.width,
      height: request.height,
      bytes: request.bytes,
      bytesPerRow: request.bytesPerRow,
      bytesPerPixel: request.bytesPerPixel,
      bgra: request.bgra,
      edge: request.edge,
    );

class NativeLiveCardDetector {
  static const MethodChannel _channel = NativeCardRecognizer.channel;
  final Duration interval;
  final Duration geometryInterval;
  final DateTime Function() _now;
  DateTime? _lastFrame;
  DateTime? _lastTextAnalysis;
  bool _busy = false;
  int _generation = 0;

  NativeLiveCardDetector({
    this.interval = const Duration(milliseconds: 400),
    this.geometryInterval = const Duration(milliseconds: 100),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static String orientationTokenFor({
    required CameraDescription camera,
    required DeviceOrientation orientation,
  }) => '${camera.name}:${orientation.name}';

  void reset() {
    _generation++;
    _lastFrame = null;
    _lastTextAnalysis = null;
  }

  Future<LiveScanFrame?> analyze(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation orientation,
    bool includeText = false,
    List<LiveScanExcludedRegion> excludedRegions =
        const <LiveScanExcludedRegion>[],
    List<LiveScanExcludedRegion> appearanceRegions =
        const <LiveScanExcludedRegion>[],
  }) async {
    final Map<String, LiveScanExcludedRegion> combined =
        <String, LiveScanExcludedRegion>{};
    for (final List<LiveScanExcludedRegion> regions
        in <List<LiveScanExcludedRegion>>[excludedRegions, appearanceRegions]) {
      final Set<String> ids = <String>{};
      if (regions.length > 8) {
        throw const FormatException('Saved card regions are invalid.');
      }
      for (final LiveScanExcludedRegion region in regions) {
        region.toMap();
        final LiveScanExcludedRegion? existing = combined[region.id];
        bool matchingCorners = true;
        if (existing != null) {
          for (int index = 0; index < 4; index++) {
            if (existing.corners[index].x != region.corners[index].x ||
                existing.corners[index].y != region.corners[index].y) {
              matchingCorners = false;
              break;
            }
          }
        }
        if (!ids.add(region.id) || !matchingCorners) {
          throw const FormatException('Saved card regions are invalid.');
        }
        combined[region.id] = region;
      }
    }
    if (combined.length > 8) {
      throw const FormatException('Too many saved card regions.');
    }
    final List<Map<String, Object>> regions = excludedRegions
        .map((LiveScanExcludedRegion region) => region.toMap())
        .toList(growable: false);
    final List<Map<String, Object>> appearances = appearanceRegions
        .map((LiveScanExcludedRegion region) => region.toMap())
        .toList(growable: false);
    if (!NativeCardRecognizer.supported || _busy) return null;
    final DateTime now = _now();
    if ((_lastFrame != null &&
            now.difference(_lastFrame!) < geometryInterval) ||
        (includeText &&
            _lastTextAnalysis != null &&
            now.difference(_lastTextAnalysis!) < interval)) {
      return null;
    }
    if (image.planes.isEmpty) {
      throw const FormatException('Camera frame has no planes.');
    }
    final bool bgra = image.format.group == ImageFormatGroup.bgra8888;
    if (!bgra &&
        image.format.group != ImageFormatGroup.yuv420 &&
        image.format.group != ImageFormatGroup.nv21) {
      throw const FormatException('Unsupported camera stream pixel format.');
    }
    _busy = true;
    _lastFrame = now;
    if (includeText) _lastTextAnalysis = now;
    final int generation = _generation;
    final String token = orientationTokenFor(
      camera: camera,
      orientation: orientation,
    );
    try {
      final Stopwatch? preparation =
          const bool.fromEnvironment('PHYSICAL_CARD_QA')
          ? (Stopwatch()..start())
          : null;
      final Map<String, Object> pixels = await compute(
        _prepareFramePixels,
        _FramePixelRequest(
          width: image.width,
          height: image.height,
          bytes: image.planes.first.bytes,
          bytesPerRow: image.planes.first.bytesPerRow,
          bytesPerPixel: bgra ? 4 : (image.planes.first.bytesPerPixel ?? 1),
          bgra: bgra,
          edge: includeText ? 1920 : 960,
        ),
        debugLabel: 'scanner-frame-pixels',
      );
      if (preparation != null) {
        preparation.stop();
        debugPrint(
          'LIVE_FRAME_PREP_DIAGNOSTIC '
          'source=${image.width}x${image.height} '
          'bounded=${pixels['width']}x${pixels['height']} '
          'bytes=${(pixels['bytes'] as Uint8List).length} '
          'elapsedMicros=${preparation.elapsedMicroseconds}',
        );
      }
      if (generation != _generation) return null;
      final int rotation = defaultTargetPlatform == TargetPlatform.iOS
          ? 0
          : rearFrameRotation(camera.sensorOrientation, orientation);
      final Map<Object?, Object?>? response = await _channel
          .invokeMethod<Map<Object?, Object?>>('detectFrame', <String, Object>{
            ...pixels,
            'rotation': rotation,
            'cameraName': camera.name,
            'sourceWidth': image.width,
            'sourceHeight': image.height,
            'includeText': includeText,
            if (defaultTargetPlatform == TargetPlatform.iOS)
              'excludedRegions': regions,
            if (defaultTargetPlatform == TargetPlatform.iOS)
              'appearanceRegions': appearances,
          });
      if (generation != _generation) return null;
      if (response == null) {
        throw const FormatException('Live detection returned no result.');
      }
      return LiveScanFrame.fromMap(response, orientationToken: token);
    } on PlatformException catch (error) {
      if (error.code == 'scanner_busy') return null;
      rethrow;
    } finally {
      _busy = false;
    }
  }

  @visibleForTesting
  static int rearFrameRotation(
    int sensorOrientation,
    DeviceOrientation orientation,
  ) {
    final int deviceDegrees = switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    return (sensorOrientation - deviceDegrees + 360) % 360;
  }

  @visibleForTesting
  static Map<String, Object> boundedFramePixels({
    required int width,
    required int height,
    required Uint8List bytes,
    required int bytesPerRow,
    required int bytesPerPixel,
    required bool bgra,
    int edge = 960,
  }) {
    if (width <= 0 ||
        height <= 0 ||
        edge <= 0 ||
        bytesPerPixel <= 0 ||
        (bgra && bytesPerPixel < 4) ||
        bytesPerRow < width * bytesPerPixel ||
        bytes.length < (height - 1) * bytesPerRow + width * bytesPerPixel) {
      throw const FormatException(
        'Camera frame dimensions or stride are invalid.',
      );
    }
    final double scale = math.min(1, edge / math.max(width, height));
    final int targetWidth = math.max(1, (width * scale).round());
    final int targetHeight = math.max(1, (height * scale).round());
    final int channels = bgra ? 4 : 1;
    final Uint8List output = Uint8List(targetWidth * targetHeight * channels);
    for (int y = 0; y < targetHeight; y++) {
      final int sourceY = math.min(height - 1, y * height ~/ targetHeight);
      for (int x = 0; x < targetWidth; x++) {
        final int sourceX = math.min(width - 1, x * width ~/ targetWidth);
        final int source = sourceY * bytesPerRow + sourceX * bytesPerPixel;
        final int target = (y * targetWidth + x) * channels;
        for (int channel = 0; channel < channels; channel++) {
          output[target + channel] = bytes[source + channel];
        }
      }
    }
    return <String, Object>{
      'width': targetWidth,
      'height': targetHeight,
      'bytes': output,
      'bytesPerRow': targetWidth * channels,
      'format': bgra ? 'bgra8888' : 'luminance',
    };
  }
}
