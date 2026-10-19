import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

ScanCrop _copy(
  ScanCrop crop, {
  String? imagePath,
  bool? rectified,
  List<ScanPoint>? corners,
  List<ScanTextLine>? lines,
  List<String>? warnings,
}) => ScanCrop(
  imagePath: imagePath ?? crop.imagePath,
  width: crop.width,
  height: crop.height,
  rectified: rectified ?? crop.rectified,
  sourceCorners: corners ?? crop.sourceCorners,
  lines: lines ?? crop.lines,
  warnings: warnings ?? crop.warnings,
);

void main() {
  test('tilted saved rules use measured glyph height for capture evidence', () {
    const ScanCrop crop = ScanCrop(
      imagePath: '/local/tilted-card.jpg',
      width: 1105,
      height: 1543,
      rectified: true,
      sourceCorners: <ScanPoint>[
        ScanPoint(.5486111, .546875),
        ScanPoint(.9236111, .5625),
        ScanPoint(1, .90234375),
        ScanPoint(.5069444, .90625),
      ],
      lines: <ScanTextLine>[
        ScanTextLine(
          text: 'Pick Your Poison',
          confidence: 1,
          bounds: ScanBounds(.072855, .025607, .377655, .032643),
        ),
        ScanTextLine(
          text: 'Sorcery',
          confidence: 1,
          bounds: ScanBounds(.052551, .516432, .172756, .048716),
          glyphHeight: .035,
        ),
        ScanTextLine(
          text: 'Each opponent sacrifices an artifact',
          confidence: 1,
          bounds: ScanBounds(.048150, .637329, .932116, .098240),
          glyphHeight: .048422,
        ),
        ScanTextLine(
          text: 'Each opponent sacrifices an',
          confidence: 1,
          bounds: ScanBounds(.042059, .724023, .746997, .091868),
          glyphHeight: .047751,
        ),
        ScanTextLine(
          text: 'Each opponent sacrifices a crea',
          confidence: 1,
          bounds: ScanBounds(.040232, .807697, .843351, .109004),
          glyphHeight: .056454,
        ),
      ],
    );
    expect(hasVerifiedSavedVisualLayout(crop), isTrue);
    expect(hasVerifiedSavedCardCapturePresence(crop), isTrue);
    expect(hasVerifiedLiveBodyLayout(crop), isFalse);
    for (final double? glyph in <double?>[null, double.nan, .08, .2]) {
      final ScanCrop invalid = _copy(
        crop,
        lines: crop.lines
            .map(
              (ScanTextLine line) => line.bounds.y < .6
                  ? line
                  : ScanTextLine(
                      text: line.text,
                      confidence: line.confidence,
                      bounds: line.bounds,
                      glyphHeight: glyph,
                    ),
            )
            .toList(),
      );
      expect(hasVerifiedSavedVisualLayout(invalid), isFalse);
      expect(hasVerifiedSavedCardCapturePresence(invalid), isFalse);
    }
    expect(
      hasVerifiedSavedCardCapturePresence(
        _copy(
          crop,
          lines: crop.lines
              .where((ScanTextLine line) => line.bounds.y < .75)
              .toList(),
        ),
      ),
      isFalse,
    );
  });

  final Map<String, Object?> fixture = jsonDecode(
    File('test/fixtures/scanner_capture_presence.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final List<Map<String, Object?>> captures =
      (fixture['captures']! as List<Object?>).cast<Map<String, Object?>>();
  final List<ScanCrop> four = captures
      .where(
        (Map<String, Object?> row) =>
            row['source'] == 'collector_four_cards.png',
      )
      .map(
        (Map<String, Object?> row) =>
            ScanCrop.fromMap(row['crop']! as Map<String, Object?>),
      )
      .toList();

  test('actual four-card saved observations establish capture presence without repairing weak OCR', () {
    expect(four, hasLength(4));
    for (final ScanCrop crop in four) {
      final List<String> warnings = List<String>.of(crop.warnings);
      final List<String> text = crop.lines
          .map((ScanTextLine line) => line.text)
          .toList();
      final List<double> confidence = crop.lines
          .map((ScanTextLine line) => line.confidence)
          .toList();
      expect(hasVerifiedSavedCardCapturePresence(crop), isTrue);
      expect(crop.warnings, warnings);
      expect(crop.lines.map((ScanTextLine line) => line.text), text);
      expect(
        crop.lines.map((ScanTextLine line) => line.confidence),
        confidence,
      );
    }
    for (final int index in <int>[1, 3]) {
      expect(
        four[index].warnings,
        containsAll(<String>['details_pending', 'incomplete_card']),
      );
      expect(ScanHints.fromCrop(four[index]).names, isEmpty);
      expect(ScanHints.fromCrop(four[index]).typeLine, isNull);
      expect(hasVerifiedSavedVisualLayout(four[index]), isFalse);
    }
  });

  test('actual desk and sky crops do not become captured cards', () {
    for (final Map<String, Object?> row in captures.where(
      (Map<String, Object?> row) =>
          row['source'] == 'collector_empty_desk.jpg' ||
          (row['source'] == 'collector_saved_failure.jpg' && row['index'] != 3),
    )) {
      expect(
        hasVerifiedSavedCardCapturePresence(
          ScanCrop.fromMap(row['crop']! as Map<String, Object?>),
        ),
        isFalse,
      );
    }
  });

  test(
    'weak historical framing requires every independent physical region',
    () {
      final ScanCrop crop = four[1];
      final Map<String, ScanCrop> rejected = <String, ScanCrop>{
        'title only': _copy(
          crop,
          lines: crop.lines
              .where((ScanTextLine line) => line.bounds.y < .15)
              .toList(),
        ),
        'body only': _copy(
          crop,
          lines: crop.lines
              .where(
                (ScanTextLine line) =>
                    line.bounds.y >= .6 && line.bounds.y < .82,
              )
              .toList(),
        ),
        'missing header': _copy(
          crop,
          lines: crop.lines
              .where((ScanTextLine line) => line.bounds.y >= .15)
              .toList(),
        ),
        'missing type region': _copy(
          crop,
          lines: crop.lines
              .where(
                (ScanTextLine line) =>
                    line.bounds.y < .35 || line.bounds.y >= .64,
              )
              .toList(),
        ),
        'missing artist': _copy(
          crop,
          lines: crop.lines
              .where((ScanTextLine line) => !line.text.startsWith('Illus.'))
              .toList(),
        ),
        'missing copyright': _copy(
          crop,
          lines: crop.lines
              .where((ScanTextLine line) => !line.text.contains('©'))
              .toList(),
        ),
        'missing gameplay': _copy(
          crop,
          lines: crop.lines
              .where(
                (ScanTextLine line) =>
                    line.bounds.y < .6 || line.bounds.y >= .82,
              )
              .toList(),
        ),
        'scene only': _copy(crop, imagePath: ''),
        'unrectified': _copy(crop, rectified: false),
        'partial': _copy(
          crop,
          warnings: <String>[...crop.warnings, 'partial_card'],
        ),
        'ownership uncertain': _copy(
          crop,
          warnings: <String>[...crop.warnings, 'capture_ownership_uncertain'],
        ),
        'conflicting titles': _copy(
          crop,
          warnings: <String>[...crop.warnings, 'lighting_title_conflict'],
        ),
        'nonconvex': _copy(
          crop,
          corners: const <ScanPoint>[
            ScanPoint(0, 0),
            ScanPoint(1, 1),
            ScanPoint(1, 0),
            ScanPoint(0, 1),
          ],
        ),
      };
      for (final MapEntry<String, ScanCrop> row in rejected.entries) {
        expect(
          hasVerifiedSavedCardCapturePresence(row.value),
          isFalse,
          reason: row.key,
        );
      }
    },
  );

  test('quoted flavor and combined or misplaced footer rows cannot substitute for independent framing', () {
    final ScanCrop crop = four[3];
    final ScanTextLine artist = crop.lines.firstWhere(
      (ScanTextLine line) => line.text.startsWith('Illus.'),
    );
    final ScanTextLine copyright = crop.lines.firstWhere(
      (ScanTextLine line) => line.text.contains('©'),
    );
    final List<ScanTextLine> noGameplay = crop.lines
        .where((ScanTextLine line) => !line.text.startsWith('Target creature'))
        .toList();
    expect(
      hasVerifiedSavedCardCapturePresence(_copy(crop, lines: noGameplay)),
      isFalse,
    );
    final List<ScanTextLine> combined =
        crop.lines
            .where((ScanTextLine line) => line != artist && line != copyright)
            .toList()
          ..add(
            ScanTextLine(
              text: '${artist.text} ${copyright.text}',
              confidence: .3,
              bounds: copyright.bounds,
            ),
          );
    expect(
      hasVerifiedSavedCardCapturePresence(_copy(crop, lines: combined)),
      isFalse,
    );
    final List<ScanTextLine> misplaced = crop.lines
        .map(
          (ScanTextLine line) => line == artist || line == copyright
              ? ScanTextLine(
                  text: line.text,
                  confidence: line.confidence,
                  bounds: ScanBounds(
                    line.bounds.x,
                    .3,
                    line.bounds.width,
                    line.bounds.height,
                  ),
                )
              : line,
        )
        .toList();
    expect(
      hasVerifiedSavedCardCapturePresence(_copy(crop, lines: misplaced)),
      isFalse,
    );
    final List<ScanTextLine> weakBody = crop.lines
        .map(
          (ScanTextLine line) => line.text.startsWith('Target creature')
              ? ScanTextLine(
                  text: line.text,
                  confidence: .84,
                  bounds: line.bounds,
                )
              : line,
        )
        .toList();
    expect(
      hasVerifiedSavedCardCapturePresence(_copy(crop, lines: weakBody)),
      isFalse,
    );
    final List<ScanTextLine> weakFooter = crop.lines
        .map(
          (ScanTextLine line) => line == copyright
              ? ScanTextLine(
                  text: line.text,
                  confidence: .29,
                  bounds: line.bounds,
                )
              : line,
        )
        .toList();
    expect(
      hasVerifiedSavedCardCapturePresence(_copy(crop, lines: weakFooter)),
      isFalse,
    );
    for (final bool Function(ScanTextLine) projected
        in <bool Function(ScanTextLine)>[
          (ScanTextLine line) => line == artist,
          (ScanTextLine line) => line == copyright,
          (ScanTextLine line) => line.text.startsWith('Target creature'),
        ]) {
      final List<ScanTextLine> guided = crop.lines
          .map(
            (ScanTextLine line) => projected(line)
                ? ScanTextLine(
                    text: line.text,
                    confidence: line.confidence,
                    bounds: line.bounds,
                    glyphHeight: line.glyphHeight,
                    alternatives: line.alternatives,
                    sceneFooterGuide: true,
                  )
                : line,
          )
          .toList();
      expect(
        hasVerifiedSavedCardCapturePresence(_copy(crop, lines: guided)),
        isFalse,
      );
    }
  });
}
