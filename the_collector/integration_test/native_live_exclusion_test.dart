import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

Future<LiveScanFrame> _detect(
  Uint8List pixels, {
  required int width,
  required int height,
  required bool includeText,
  List<LiveScanExcludedRegion> excluded = const <LiveScanExcludedRegion>[],
  List<LiveScanExcludedRegion> appearance = const <LiveScanExcludedRegion>[],
}) async {
  final Map<Object?, Object?>? response = await NativeCardRecognizer.channel
      .invokeMethod<Map<Object?, Object?>>('detectFrame', <String, Object>{
        'bytes': pixels,
        'format': 'bgra8888',
        'width': width,
        'height': height,
        'bytesPerRow': width * 4,
        'rotation': 0,
        'cameraName': 'native-exclusion-fixture',
        'sourceWidth': width,
        'sourceHeight': height,
        'includeText': includeText,
        'excludedRegions': excluded
            .map((LiveScanExcludedRegion region) => region.toMap())
            .toList(growable: false),
        'appearanceRegions': appearance
            .map((LiveScanExcludedRegion region) => region.toMap())
            .toList(growable: false),
      });
  expect(response, isNotNull);
  return LiveScanFrame.fromMap(
    response!,
    orientationToken: 'native-exclusion-fixture:portraitUp',
  );
}

Uint8List _quadrants() {
  const int width = 256;
  const int height = 384;
  final Uint8List pixels = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int offset = (y * width + x) * 4;
      final bool inside = x >= 32 && x < 224 && y >= 48 && y < 336;
      final bool right = x >= width ~/ 2;
      final bool bottom = y >= height ~/ 2;
      final int red = !inside
          ? 0
          : (!right && !bottom || right && bottom ? 255 : 0);
      final int green = !inside ? 255 : (right ? 255 : 0);
      final int blue = !inside ? 255 : (!right && bottom ? 255 : 0);
      pixels[offset] = blue;
      pixels[offset + 1] = green;
      pixels[offset + 2] = red;
      pixels[offset + 3] = 255;
    }
  }
  return pixels;
}

void _expectRGB(
  LiveCardAppearanceSample sample,
  int column,
  int row,
  List<double> expected,
) {
  final int offset = (row * 8 + column) * 3;
  for (int channel = 0; channel < 3; channel++) {
    expect(
      sample.values[offset + channel],
      closeTo(expected[channel], .08),
      reason:
          'RGB channel $channel at column $column, row $row; '
          'actual RGB ${sample.values.sublist(offset, offset + 3)}',
    );
  }
}

Future<Uint8List> _cardFrame({bool inflatedBorder = false}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff777777), ui.BlendMode.src);
  if (inflatedBorder) {
    canvas.drawRect(
      const ui.Rect.fromLTWH(30, 30, 635, 1220),
      ui.Paint()..color = const ui.Color(0xffd0c5b0),
    );
    canvas.drawRect(
      const ui.Rect.fromLTWH(30, 30, 635, 1220),
      ui.Paint()
        ..color = const ui.Color(0xff111111)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 8,
    );
  }
  canvas.drawRect(
    const ui.Rect.fromLTWH(100, 100, 540, 756),
    ui.Paint()..color = const ui.Color(0xffeee2cd),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(100, 100, 540, 756),
    ui.Paint()
      ..color = const ui.Color(0xff111111)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 8,
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(125, 205, 490, 265),
    ui.Paint()..color = const ui.Color(0xff47536a),
  );
  canvas.drawCircle(
    const ui.Offset(475, 290),
    62,
    ui.Paint()..color = const ui.Color(0xffdba76a),
  );
  void text(
    String value,
    double y, {
    double size = 28,
    double x = 125,
    double width = 490,
  }) {
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontFamily: 'Arial', fontSize: size),
          )
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xff111111)))
          ..addText(value);
    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    canvas.drawParagraph(paragraph, ui.Offset(x, y));
    paragraph.dispose();
  }

  text('Mirkwood Bats', 132, size: 36);
  text('Creature — Bat', 493);
  text('Flying', 555);
  text('Whenever you create or sacrifice a', 603, size: 24);
  text('token, each opponent loses 1 life.', 641, size: 24);
  text('2/3', 782);
  canvas.drawRect(
    const ui.Rect.fromLTWH(690, 110, 240, 336),
    ui.Paint()..color = const ui.Color(0xfff7edda),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(690, 110, 240, 336),
    ui.Paint()
      ..color = const ui.Color(0xff111111)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 4,
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(706, 174, 208, 89),
    ui.Paint()..color = const ui.Color(0xff626c7c),
  );
  text('Nevermore', 127, x: 703, width: 214, size: 21);
  text('Enchantment', 279, x: 703, width: 214, size: 15);
  text(
    'As Nevermore enters the battlefield,',
    314,
    x: 703,
    width: 214,
    size: 12,
  );
  text('name a nonland card.', 338, x: 703, width: 214, size: 12);
  text("The named card can't be cast.", 365, x: 703, width: 214, size: 12);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(960, 1280);
  try {
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final Uint8List rgba = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final Uint8List bgra = Uint8List(rgba.length);
    for (int offset = 0; offset < rgba.length; offset += 4) {
      bgra[offset] = rgba[offset + 2];
      bgra[offset + 1] = rgba[offset + 1];
      bgra[offset + 2] = rgba[offset];
      bgra[offset + 3] = rgba[offset + 3];
    }
    return bgra;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _footerCardPng() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffeee2cd), ui.BlendMode.src);
  canvas.drawRect(
    const ui.Rect.fromLTWH(3, 3, 624, 874),
    ui.Paint()
      ..color = const ui.Color(0xff111111)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 6,
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(28, 110, 574, 310),
    ui.Paint()..color = const ui.Color(0xff47536a),
  );
  void text(String value, double x, double y, double size, double width) {
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontFamily: 'Arial', fontSize: size),
          )
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xff111111)))
          ..addText(value);
    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    canvas.drawParagraph(paragraph, ui.Offset(x, y));
    paragraph.dispose();
  }

  text('Mirkwood Bats', 28, 35, 36, 574);
  text('Creature — Bat', 28, 448, 28, 574);
  text('Flying', 28, 505, 24, 574);
  text('Whenever you create or sacrifice a token,', 28, 558, 24, 574);
  text('each opponent loses 1 life.', 28, 597, 24, 574);
  text('2/3', 520, 728, 24, 75);
  text('0123 U', 28, 784, 20, 190);
  text('LTR EN', 28, 824, 20, 190);
  text('0285 C', 442, 784, 20, 160);
  text('LTR EN', 442, 824, 20, 160);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(630, 880);
  try {
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _foreshortenedCardPng({
  bool titleVisible = false,
  String typeText = 'Enchantment',
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff777777), ui.BlendMode.src);
  canvas.translate(140, 140);
  canvas.scale(2.6, 1.5);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 630, 880),
    ui.Paint()..color = const ui.Color(0xffeee2cd),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(3, 3, 624, 874),
    ui.Paint()
      ..color = const ui.Color(0xff111111)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 6,
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(
      28,
      titleVisible ? 110 : 28,
      574,
      titleVisible ? 338 : 420,
    ),
    ui.Paint()..color = const ui.Color(0xff47536a),
  );
  void text(String value, double y, double size) {
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontFamily: 'Arial', fontSize: size),
          )
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xff111111)))
          ..addText(value);
    final ui.Paragraph paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 574));
    canvas.drawParagraph(paragraph, ui.Offset(28, y));
    paragraph.dispose();
  }

  if (titleVisible) {
    canvas.save();
    canvas.translate(0, 34);
    canvas.scale(1, .5);
    text('Silent Ward', 0, 28);
    canvas.restore();
  }
  text(typeText, 490, 28);
  text('Prevent all damage from a source.', 550, 25);
  text('Draw a card, then discard a card.', 600, 25);
  text('Counter that source of damage.', 650, 25);
  text('© 2025 Wizards of the Coast', 820, 16);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(1920, 1680);
  try {
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

bool _centerInside(LiveCardDetection card, LiveScanExcludedRegion region) {
  if (card.corners.length != 4) return false;
  final double x =
      card.corners.fold(0.0, (double sum, ScanPoint point) => sum + point.x) /
      4;
  final double y =
      card.corners.fold(0.0, (double sum, ScanPoint point) => sum + point.y) /
      4;
  double? direction;
  for (int index = 0; index < 4; index++) {
    final ScanPoint first = region.corners[index];
    final ScanPoint next = region.corners[(index + 1) % 4];
    final double cross =
        (next.x - first.x) * (y - first.y) - (next.y - first.y) * (x - first.x);
    if (direction != null && cross * direction < 0) return false;
    if (cross != 0) direction = cross;
  }
  return true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'truncated long type anchors recover body without inventing a title',
    (WidgetTester tester) async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector-truncated-type-fixture-',
      );
      ScanRecognition? recognition;
      try {
        final File source = File('${directory.path}/truncated-type.png');
        await source.writeAsBytes(
          await _foreshortenedCardPng(typeText: 'Enchantmen'),
        );
        final Map<Object?, Object?>? raw = await NativeCardRecognizer.channel
            .invokeMethod<Map<Object?, Object?>>('recognize', <String, Object>{
              'path': source.path,
              'multipleCards': true,
              'includePartialDiagnostics': true,
            });
        debugPrint('TRUNCATED_TYPE_NATIVE_REPORT ${jsonEncode(raw)}');
        expect(raw, isNotNull);
        recognition = ScanRecognition.fromMap(raw!);
        final ScanCrop recovered = recognition.crops.firstWhere(
          (ScanCrop crop) => crop.lines.any(
            (ScanTextLine line) =>
                line.text.contains('Prevent all damage') &&
                line.bounds.width > line.bounds.height,
          ),
        );
        expect(recovered.width / recovered.height, closeTo(63 / 88, .03));
        expect(recovered.warnings, contains('orientation_ensemble'));
        expect(
          recovered.lines.any((ScanTextLine line) => line.text == 'Enchantmen'),
          isTrue,
        );
        expect(
          ScanHints.fromCrop(recovered).typeLine,
          isNull,
          reason:
              'The fixture omits the last glyph; orientation cannot add it.',
        );
        expect(
          recovered.lines
              .where(
                (ScanTextLine line) =>
                    line.confidence >= .85 &&
                    line.bounds.y > .6 &&
                    line.bounds.y < .85 &&
                    line.bounds.width > line.bounds.height &&
                    (line.text.contains('Prevent all damage') ||
                        line.text.contains('Draw a card') ||
                        line.text.contains('Counter that source')),
              )
              .length,
          greaterThanOrEqualTo(3),
        );
        expect(
          recovered.lines.where(
            (ScanTextLine line) =>
                line.bounds.y < .1 &&
                line.text.replaceAll(RegExp(r'[^A-Za-z]'), '').length >= 3,
          ),
          isEmpty,
        );
      } finally {
        for (final ScanCrop crop in recognition?.crops ?? const <ScanCrop>[]) {
          final File file = File(crop.imagePath);
          if (await file.exists()) await file.delete();
        }
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'foreshortened cards recover upright rules when the title is covered',
    (WidgetTester tester) async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector-body-orientation-fixture-',
      );
      ScanRecognition? recognition;
      try {
        final File source = File('${directory.path}/foreshortened.png');
        await source.writeAsBytes(await _foreshortenedCardPng());
        recognition = await NativeCardRecognizer().recognize(source.path);
        final ScanCrop recovered = recognition.crops.firstWhere(
          (ScanCrop crop) =>
              crop.lines.any((ScanTextLine line) => line.text == 'Enchantment'),
        );
        expect(recovered.rectified, isTrue);
        expect(recovered.width / recovered.height, closeTo(63 / 88, .03));
        expect(recovered.warnings, contains('orientation_ensemble'));
        expect(recovered.warnings, contains('geometry_adjusted'));
        expect(recovered.width, lessThanOrEqualTo(4096));
        expect(recovered.height, lessThanOrEqualTo(4096));
        expect(
          recovered.lines.where(
            (ScanTextLine line) =>
                line.bounds.y < .1 &&
                line.text.replaceAll(RegExp(r'[^A-Za-z]'), '').length >= 3,
          ),
          isEmpty,
          reason:
              'A fully covered title must not be invented by the enhancement.',
        );
        final List<ScanTextLine> rules = recovered.lines
            .where(
              (ScanTextLine line) =>
                  line.confidence >= .85 &&
                  line.bounds.y > .6 &&
                  line.bounds.y < .85 &&
                  line.bounds.width > line.bounds.height &&
                  (line.text.contains('Prevent all damage') ||
                      line.text.contains('Draw a card') ||
                      line.text.contains('Counter that source')),
            )
            .toList(growable: false);
        expect(rules.length, greaterThanOrEqualTo(2));
      } finally {
        for (final ScanCrop crop in recognition?.crops ?? const <ScanCrop>[]) {
          final File file = File(crop.imagePath);
          if (await file.exists()) await file.delete();
        }
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'foreshortened cards retain titles supported by compressed source pixels',
    (WidgetTester tester) async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector-compressed-title-fixture-',
      );
      ScanRecognition? recognition;
      try {
        final File source = File('${directory.path}/compressed-title.png');
        await source.writeAsBytes(
          await _foreshortenedCardPng(titleVisible: true),
        );
        recognition = await NativeCardRecognizer().recognize(source.path);
        final ScanCrop recovered = recognition.crops.firstWhere(
          (ScanCrop crop) => crop.lines.any(
            (ScanTextLine line) =>
                line.text == 'Silent Ward' &&
                line.bounds.y < .1 &&
                line.confidence >= .5,
          ),
        );
        expect(recovered.width / recovered.height, closeTo(63 / 88, .03));
        expect(recovered.warnings, isNot(contains('incomplete_card')));
        expect(
          recovered.lines.any(
            (ScanTextLine line) => line.text == 'Enchantment',
          ),
          isTrue,
        );
        expect(recovered.width, lessThanOrEqualTo(4096));
        expect(recovered.height, lessThanOrEqualTo(4096));
      } finally {
        for (final ScanCrop crop in recognition?.crops ?? const <ScanCrop>[]) {
          final File file = File(crop.imagePath);
          if (await file.exists()) await file.delete();
        }
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isIOS,
  );

  testWidgets('native photo OCR retains collector codes on both footer sides', (
    WidgetTester tester,
  ) async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'collector-footer-fixture-',
    );
    ScanRecognition? recognition;
    try {
      final File source = File('${directory.path}/footer.png');
      await source.writeAsBytes(await _footerCardPng());
      recognition = await NativeCardRecognizer().recognize(source.path);
      final Iterable<ScanTextLine> lines = recognition.crops.expand(
        (ScanCrop crop) => crop.lines,
      );
      final List<ScanTextLine> footer = lines
          .where((ScanTextLine line) => line.bounds.y >= .84)
          .toList(growable: false);
      expect(
        footer.any(
          (ScanTextLine line) =>
              line.bounds.x < .3 && line.text.contains('0123'),
        ),
        isTrue,
        reason: 'The established left footer pass must retain its number.',
      );
      expect(
        footer.any(
          (ScanTextLine line) =>
              line.bounds.x >= .65 && line.text.contains('0285'),
        ),
        isTrue,
        reason: 'Right footer codes must preserve top-left crop coordinates.',
      );
      expect(
        footer.any(
          (ScanTextLine line) =>
              line.bounds.x >= .65 &&
              line.text.contains('LTR') &&
              line.text.contains('EN') &&
              line.confidence >= .75,
        ),
        isTrue,
        reason:
            'A readable right set/language line corroborates the code pass.',
      );
    } finally {
      for (final ScanCrop crop in recognition?.crops ?? const <ScanCrop>[]) {
        final File file = File(crop.imagePath);
        if (await file.exists()) await file.delete();
      }
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isIOS);

  testWidgets('native appearances preserve top-left RGB quadrant order', (
    WidgetTester tester,
  ) async {
    const LiveScanExcludedRegion region = LiveScanExcludedRegion(
      id: 'quadrants',
      corners: <ScanPoint>[
        ScanPoint(.125, .125),
        ScanPoint(.875, .125),
        ScanPoint(.875, .875),
        ScanPoint(.125, .875),
      ],
    );
    final LiveScanFrame frame = await _detect(
      _quadrants(),
      width: 256,
      height: 384,
      includeText: false,
      appearance: const <LiveScanExcludedRegion>[region],
    );
    expect(frame.appearanceSamplingSupported, isTrue);
    final LiveCardAppearanceSample sample = frame.appearanceSamples.single;
    expect(sample.id, region.id);
    expect(sample.values, hasLength(288));
    for (int index = 0; index < 4; index++) {
      expect(
        sample.corners[index].x,
        closeTo(region.corners[index].x, .000001),
      );
      expect(
        sample.corners[index].y,
        closeTo(region.corners[index].y, .000001),
      );
    }
    _expectRGB(sample, 1, 2, <double>[1, 0, 0]);
    _expectRGB(sample, 6, 2, <double>[0, 1, 0]);
    _expectRGB(sample, 1, 9, <double>[0, 0, 1]);
    _expectRGB(sample, 6, 9, <double>[1, 1, 0]);
    expect(frame.cards.expand((LiveCardDetection card) => card.lines), isEmpty);
  }, skip: !Platform.isIOS);

  testWidgets(
    'inflated live rectangles cannot reread an enclosed completed card',
    (WidgetTester tester) async {
      const LiveScanExcludedRegion region = LiveScanExcludedRegion(
        id: 'completed-inner-card',
        corners: <ScanPoint>[
          ScanPoint(100 / 960, 100 / 1280),
          ScanPoint(640 / 960, 100 / 1280),
          ScanPoint(640 / 960, 856 / 1280),
          ScanPoint(100 / 960, 856 / 1280),
        ],
      );
      final Uint8List pixels = await _cardFrame(inflatedBorder: true);
      final LiveScanFrame readable = await _detect(
        pixels,
        width: 960,
        height: 1280,
        includeText: true,
        appearance: const <LiveScanExcludedRegion>[region],
      );
      final LiveCardDetection inflated = readable.cards.firstWhere(
        (LiveCardDetection card) => card.lines.any(
          (ScanTextLine line) => line.text.contains('Mirkwood'),
        ),
      );
      double area(List<ScanPoint> corners) {
        double twiceArea = 0;
        for (int index = 0; index < corners.length; index++) {
          final ScanPoint first = corners[index];
          final ScanPoint next = corners[(index + 1) % corners.length];
          twiceArea += first.x * next.y - next.x * first.y;
        }
        return twiceArea.abs() / 2;
      }

      expect(
        area(inflated.corners) / area(region.corners),
        greaterThan(1.8),
        reason:
            'The enclosing rectangle must exceed the completed geometry match '
            'limit while still reading the enclosed card.',
      );
      final LiveScanFrame excluded = await _detect(
        pixels,
        width: 960,
        height: 1280,
        includeText: true,
        excluded: const <LiveScanExcludedRegion>[region],
        appearance: const <LiveScanExcludedRegion>[region],
      );
      final List<String> text = excluded.cards
          .expand((LiveCardDetection card) => card.lines)
          .map((ScanTextLine line) => line.text)
          .toList(growable: false);
      expect(
        text.any((String line) => line.contains('Mirkwood')),
        isFalse,
        reason: 'Completed pixels must stay masked inside oversized OCR crops.',
      );
      expect(
        text.any((String line) => line.contains('Nevermore')),
        isTrue,
        reason: 'The independent neighboring card must retain its OCR.',
      );
      expect(
        excluded.appearanceSamples.single.values,
        orderedEquals(readable.appearanceSamples.single.values),
        reason: 'Completion sampling must still use the original frame.',
      );
      expect(
        excluded.cards.any(
          (LiveCardDetection card) =>
              area(card.corners) / area(region.corners) > 1.8,
        ),
        isTrue,
        reason: 'OCR masking must preserve original enclosing geometry.',
      );
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'completed native card keeps geometry and unmasked appearance without OCR',
    (WidgetTester tester) async {
      final Uint8List pixels = await _cardFrame();
      final LiveScanFrame readable = await _detect(
        pixels,
        width: 960,
        height: 1280,
        includeText: true,
      );
      expect(
        readable.cards
            .expand((LiveCardDetection card) => card.lines)
            .any((ScanTextLine line) => line.text.contains('Mirkwood')),
        isTrue,
        reason:
            'The synthetic card must actually be readable before exclusion.',
      );
      final LiveCardDetection card = readable.cards.firstWhere(
        (LiveCardDetection card) => card.lines.any(
          (ScanTextLine line) => line.text.contains('Mirkwood'),
        ),
      );
      final LiveScanExcludedRegion region = LiveScanExcludedRegion(
        id: 'completed-bats',
        corners: card.corners,
      );
      final LiveScanFrame savedReading = await _detect(
        pixels,
        width: 960,
        height: 1280,
        includeText: true,
        appearance: <LiveScanExcludedRegion>[region],
      );
      expect(
        savedReading.cards
            .expand((LiveCardDetection card) => card.lines)
            .any((ScanTextLine line) => line.text.contains('Mirkwood')),
        isTrue,
        reason:
            'Sampling a saved, still-reading card must not suppress its OCR.',
      );
      expect(savedReading.appearanceSamples.single.present, isTrue);
      expect(savedReading.appearanceSamples.single.values, hasLength(288));
      final LiveScanFrame excluded = await _detect(
        pixels,
        width: 960,
        height: 1280,
        includeText: true,
        excluded: <LiveScanExcludedRegion>[region],
        appearance: <LiveScanExcludedRegion>[region],
      );
      expect(excluded.cards, isNotEmpty);
      expect(excluded.focusCandidates, isNotEmpty);
      expect(
        excluded.cards
            .where((LiveCardDetection card) => _centerInside(card, region))
            .expand((LiveCardDetection card) => card.lines),
        isEmpty,
        reason:
            'Both rectangle OCR and global partial OCR must exclude the completed card; '
            'returned lines ${excluded.cards.map((LiveCardDetection card) => card.lines.map((ScanTextLine line) => line.text).toList()).toList()}',
      );
      expect(
        excluded.cards.where(
          (LiveCardDetection card) => _centerInside(card, region),
        ),
        isNotEmpty,
      );
      expect(
        excluded.cards
            .where((LiveCardDetection card) => !_centerInside(card, region))
            .expand((LiveCardDetection card) => card.lines)
            .any((ScanTextLine line) => line.text.contains('Nevermore')),
        isTrue,
        reason: 'The neighboring card outside the completed polygon must retain OCR.',
      );
      final LiveCardAppearanceSample sample = excluded.appearanceSamples.single;
      expect(
        sample.values,
        orderedEquals(savedReading.appearanceSamples.single.values),
      );
      expect(sample.present, isTrue);
      expect(sample.values, hasLength(288));
      expect(
        sample.values.reduce((double a, double b) => a > b ? a : b),
        greaterThan(.7),
      );
      expect(
        sample.values.reduce((double a, double b) => a < b ? a : b),
        lessThan(.5),
      );
      final LiveScanFrame geometry = await _detect(
        pixels,
        width: 960,
        height: 1280,
        includeText: false,
        excluded: <LiveScanExcludedRegion>[region],
      );
      expect(
        geometry.appearanceSamples.single.values,
        orderedEquals(sample.values),
      );
    },
    skip: !Platform.isIOS,
  );
}
