import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/scanning/capture_preview_transform.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

import 'helpers/load_collector_fonts.dart';

LiveScanTrack _track(String id, double x, {bool readable = true}) =>
    LiveScanTrack(
      id: id,
      lastSeen: DateTime(2026),
      detection: LiveCardDetection(
        confidence: .95,
        lines: <ScanTextLine>[
          if (readable)
            const ScanTextLine(
              text: 'Lightning Bolt',
              confidence: .95,
              bounds: ScanBounds(.1, .04, .7, .03),
            ),
        ],
        corners: <ScanPoint>[
          ScanPoint(x, .25),
          ScanPoint(x + .3, .25),
          ScanPoint(x + .3, .65),
          ScanPoint(x, .65),
        ],
      ),
    );

LiveScanTrack _capturedTrack(double x) {
  final LiveScanTrack source = _track('source', x);
  final LiveScanTracker tracker = LiveScanTracker();
  tracker.update(<LiveCardDetection>[
    LiveCardDetection(
      confidence: source.confidence,
      corners: source.corners,
      lines: source.crop.lines,
    ),
  ]);
  final LiveScanTrack captured = tracker.tracks.single;
  tracker.markCaptured(tracker.snapshotCapture());
  tracker.dispose();
  return captured;
}

Future<(int, int, int, int)> _panePixel(WidgetTester tester) async {
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(LiveCaptureOverlay),
          matching: find.byType(RepaintBoundary),
        ),
      );
  final (int, int, int, int)? pixel = await tester
      .runAsync<(int, int, int, int)>(() async {
        final ui.Image image = await boundary.toImage();
        try {
          final ByteData bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!;
          final int offset = (250 * image.width + 200) * 4;
          return (
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
            bytes.getUint8(offset + 3),
          );
        } finally {
          image.dispose();
        }
      });
  return pixel!;
}

Future<(int, int)> _markerPixels(WidgetTester tester, Rect region) async {
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(LiveCaptureOverlay),
          matching: find.byType(RepaintBoundary),
        ),
      );
  final (int, int)? counts = await tester.runAsync<(int, int)>(() async {
    final ui.Image image = await boundary.toImage();
    try {
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      int white = 0;
      int black = 0;
      for (int y = region.top.ceil(); y < region.bottom.floor(); y++) {
        for (int x = region.left.ceil(); x < region.right.floor(); x++) {
          final int offset = (y * image.width + x) * 4;
          if (bytes.getUint8(offset + 3) < 250) continue;
          final List<int> rgb = <int>[
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          ];
          if (rgb.every((int channel) => channel >= 250)) white++;
          if (rgb.every((int channel) => channel <= 5)) black++;
        }
      }
      return (white, black);
    } finally {
      image.dispose();
    }
  });
  return counts!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCollectorFonts);
  for (final bool rawPhoto in <bool>[false, true]) {
    for (final bool reducedMotion in <bool>[false, true]) {
      testWidgets(
        'only explicit photo ACK paints a safe-to-move check; raw $rawPhoto reduced motion $reducedMotion',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final LiveScanTrack track = _capturedTrack(.1);
          LiveScanTrack visibleTrack = track;
          final List<ScanPoint> corners = rawPhoto
              ? const <ScanPoint>[
                  ScanPoint(.2, .2),
                  ScanPoint(.75, .23),
                  ScanPoint(.7, .7),
                  ScanPoint(.22, .65),
                ]
              : track.corners;
          final Offset center =
              corners
                  .map(
                    (ScanPoint point) => Offset(point.x * 320, point.y * 568),
                  )
                  .reduce((Offset a, Offset b) => a + b) /
              4;
          final Rect sample = Rect.fromCenter(
            center: center,
            width: 80,
            height: 80,
          );
          int focusTaps = 0;
          Future<void> show(bool acknowledged) => tester.pumpWidget(
            ArcaneApp(
              theme: MyThemeData.themeData(ThemeMode.dark),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 568),
                  textScaler: TextScaler.linear(2.35),
                  disableAnimations: reducedMotion,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => focusTaps++,
                  child: LiveCaptureOverlay(
                    tracks: rawPhoto
                        ? const <LiveScanTrack>[]
                        : <LiveScanTrack>[visibleTrack],
                    retainedPhotoRegions: rawPhoto
                        ? <List<ScanPoint>>[corners]
                        : const <List<ScanPoint>>[],
                    safeToMovePhotoRegions: rawPhoto && acknowledged
                        ? <List<ScanPoint>>[corners]
                        : const <List<ScanPoint>>[],
                    safeToMoveTrackIds: !rawPhoto && acknowledged
                        ? <String>{track.photoFeedbackId}
                        : const <String>{},
                    transform: CapturePreviewTransform(
                      sourceSize: const Size(320, 568),
                      viewportSize: const Size(320, 568),
                    ),
                  ),
                ),
              ),
            ),
          );
          await show(false);
          await tester.pumpAndSettle();
          expect(
            await _markerPixels(tester, sample),
            (0, 0),
            reason: 'Pending regions and captured flags alone cannot authorize moving a card',
          );
          expect(find.semantics.byLabel(RegExp(r'Wait\.')), findsOneWidget);
          expect(
            find.semantics.byLabel(RegExp(r'Saved\. Ready\.')),
            findsNothing,
          );
          await show(true);
          await tester.pumpAndSettle();
          final (int, int) marker = await _markerPixels(tester, sample);
          expect(
            marker.$1,
            greaterThan(0),
            reason: 'The saved check has an opaque white foreground',
          );
          expect(
            marker.$2,
            greaterThan(0),
            reason:
                'The check has a full opaque black backing over bright photos',
          );
          const String screenshotDirectory = String.fromEnvironment(
            'CAPTURE_FEEDBACK_SCREENSHOT_DIR',
          );
          if (screenshotDirectory.isNotEmpty) {
            final RenderRepaintBoundary boundary = tester
                .renderObject<RenderRepaintBoundary>(
                  find.descendant(
                    of: find.byType(LiveCaptureOverlay),
                    matching: find.byType(RepaintBoundary),
                  ),
                );
            await tester.runAsync<void>(() async {
              final ui.Image image = await boundary.toImage();
              try {
                final ByteData png = (await image.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!;
                await Directory(screenshotDirectory).create(recursive: true);
                await File(
                  '$screenshotDirectory/capture-feedback-raw-$rawPhoto-motion-$reducedMotion.png',
                ).writeAsBytes(
                  png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
                  flush: true,
                );
              } finally {
                image.dispose();
              }
            });
          }
          expect(
            find.semantics.byLabel(RegExp(r'Saved\. Ready\. Identifying\.')),
            findsOneWidget,
          );
          expect(find.text('Captured'), findsNothing);
          expect(find.text('1'), findsNothing);
          await tester.tapAt(center);
          await tester.pump();
          expect(
            focusTaps,
            1,
            reason: 'Check painting must not consume preview focus taps',
          );
          await show(false);
          await tester.pumpAndSettle();
          expect(await _markerPixels(tester, sample), (
            0,
            0,
          ), reason: 'Revoked or replaced receipts remove the marker');
          if (!rawPhoto) {
            visibleTrack = LiveScanTrack(
              id: track.id,
              lastSeen: DateTime(2026),
              detection: LiveCardDetection(
                confidence: .95,
                corners: corners,
                lines: track.crop.lines,
              ),
            );
            expect(visibleTrack.photoFeedbackId, isNot(track.photoFeedbackId));
            await show(true);
            await tester.pumpAndSettle();
            expect(
              await _markerPixels(tester, sample),
              (0, 0),
              reason: 'An old ACK cannot mark a new physical card that reuses a track ID and position',
            );
            expect(
              find.semantics.byLabel(RegExp(r'Saved\. Ready\.')),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  testWidgets(
    'pending durable save paints yellow without a check then ACK paints green',
    (WidgetTester tester) async {
      final LiveScanTrack track = _track('pending', .1);
      Future<void> show(int stage) => tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: LiveCaptureOverlay(
              tracks: <LiveScanTrack>[track],
              savingTrackIds: stage == 1
                  ? <String>{track.photoFeedbackId}
                  : const <String>{},
              safeToMoveTrackIds: stage == 2
                  ? <String>{track.photoFeedbackId}
                  : const <String>{},
              transform: CapturePreviewTransform(
                sourceSize: const Size(800, 600),
                viewportSize: const Size(800, 600),
              ),
            ),
          ),
        ),
      );
      await show(0);
      await tester.pumpAndSettle();
      expect((await _panePixel(tester)).$4, closeTo(66, 1));
      await show(1);
      await tester.pumpAndSettle();
      final (int, int, int, int) pending = await _panePixel(tester);
      expect(pending.$1, greaterThan(pending.$2));
      expect(pending.$2, greaterThan(pending.$3));
      expect(pending.$4, closeTo(112, 1));
      expect(
        await _markerPixels(tester, const Rect.fromLTWH(160, 230, 80, 80)),
        (0, 0),
      );
      expect(find.semantics.byLabel('Card. Saving. Wait.'), findsOneWidget);
      expect(track.captured, isFalse);
      await show(2);
      await tester.pumpAndSettle();
      final (int, int, int, int) acknowledged = await _panePixel(tester);
      expect(acknowledged.$2, greaterThan(acknowledged.$1));
      expect(acknowledged.$2, greaterThan(acknowledged.$3));
      expect(acknowledged.$4, closeTo(133, 1));
      final (int, int) check = await _markerPixels(
        tester,
        const Rect.fromLTWH(160, 230, 80, 80),
      );
      expect(check.$1, greaterThan(0));
      expect(check.$2, greaterThan(0));
      expect(
        find.semantics.byLabel(RegExp(r'Saved\. Ready\.')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'outline-only photos show white then yellow without identity or labels',
    (WidgetTester tester) async {
      final List<ScanPoint> corners = _track('raw', .1).corners;
      Future<void> show({
        required bool retained,
        bool acknowledged = false,
        bool visibleGeometry = true,
      }) => tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: LiveCaptureOverlay(
            tracks: const <LiveScanTrack>[],
            observedPhotoRegions: retained || !visibleGeometry
                ? const <List<ScanPoint>>[]
                : <List<ScanPoint>>[corners],
            retainedPhotoRegions: retained && visibleGeometry
                ? <List<ScanPoint>>[corners]
                : const <List<ScanPoint>>[],
            safeToMovePhotoRegions: acknowledged
                ? <List<ScanPoint>>[corners]
                : const <List<ScanPoint>>[],
            transform: CapturePreviewTransform(
              sourceSize: const Size(800, 600),
              viewportSize: const Size(800, 600),
            ),
          ),
        ),
      );
      await show(retained: false);
      await tester.pumpAndSettle();
      final (int, int, int, int) white = await _panePixel(tester);
      expect(white.$1, white.$2);
      expect(white.$2, white.$3);
      expect(white.$4, closeTo(66, 1));
      expect(find.semantics.byLabel('Detected.'), findsOneWidget);
      await show(retained: true);
      await tester.pumpAndSettle();
      final (int, int, int, int) yellow = await _panePixel(tester);
      expect(yellow.$1, greaterThan(yellow.$2));
      expect(yellow.$2, greaterThan(yellow.$3));
      expect(yellow.$4, closeTo(112, 1));
      expect(find.semantics.byLabel('Wait.'), findsOneWidget);
      await show(retained: true, acknowledged: true);
      await tester.pumpAndSettle();
      final (int, int, int, int) green = await _panePixel(tester);
      expect(green.$2, greaterThan(green.$1));
      expect(green.$2, greaterThan(green.$3));
      expect(green.$4, closeTo(133, 1));
      final (int, int) check = await _markerPixels(
        tester,
        const Rect.fromLTWH(160, 230, 80, 80),
      );
      expect(check.$1, greaterThan(0));
      expect(check.$2, greaterThan(0));
      expect(
        find.semantics.byLabel(RegExp(r'Saved\. Ready\.')),
        findsOneWidget,
      );
      await show(retained: false, acknowledged: true, visibleGeometry: false);
      await tester.pumpAndSettle();
      final (int, int, int, int) receiptOnly = await _panePixel(tester);
      expect(receiptOnly.$2, greaterThan(receiptOnly.$1));
      expect(receiptOnly.$2, greaterThan(receiptOnly.$3));
      expect(receiptOnly.$4, closeTo(133, 1));
      expect(
        find.semantics.byLabel(RegExp(r'Saved\. Ready\.')),
        findsOneWidget,
      );
      expect(find.text('CAPTURED'), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final bool reducedMotion in <bool>[false, true]) {
    testWidgets(
      'only durable ACK controls green panes even after identification; reduced motion $reducedMotion',
      (WidgetTester tester) async {
        final DateTime now = DateTime.utc(2026);
        final LiveScanTracker tracker = LiveScanTracker(clock: () => now);
        try {
          final LiveScanTrack source = _track('source', .1);
          tracker.update(<LiveCardDetection>[
            LiveCardDetection(
              confidence: source.confidence,
              corners: source.corners,
              lines: source.crop.lines,
            ),
          ]);
          final LiveScanTrack track = tracker.tracks.single;
          final Map<String, Object?> json = jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<String, Object?>;
          final sf.MtgCard card = sf.MtgCard.fromJson(<String, Object?>{
            ...json,
            'name': 'Lightning Bolt',
          });
          final ScanResolution saved = ScanResolution(
            candidates: <ScanCandidate>[
              ScanCandidate(card, <ScanEvidence>{ScanEvidence.nameMatch}),
            ],
            hints: const ScanHints(names: <String>['Lightning Bolt']),
            status: ScanResolutionStatus.needsReview,
          );
          track.resolution = saved;
          Future<void> show({bool acknowledged = false}) => tester.pumpWidget(
            ArcaneApp(
              theme: MyThemeData.themeData(ThemeMode.dark),
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: LiveCaptureOverlay(
                  tracks: <LiveScanTrack>[track],
                  safeToMoveTrackIds: acknowledged
                      ? <String>{track.photoFeedbackId}
                      : const <String>{},
                  transform: CapturePreviewTransform(
                    sourceSize: const Size(800, 600),
                    viewportSize: const Size(800, 600),
                  ),
                ),
              ),
            ),
          );
          await show();
          await tester.pumpAndSettle();
          final (int, int, int, int) white = await _panePixel(tester);
          expect(white.$1, white.$2);
          expect(white.$2, white.$3);
          expect(white.$4, closeTo(66, 1));
          tracker.markCaptured(tracker.snapshotCapture());
          expect(track.captured, isTrue);
          expect(
            track.capturedIdentified,
            isFalse,
            reason: 'A live catalog match cannot identify the saved photo',
          );
          await show();
          if (reducedMotion) {
            final (int, int, int, int) immediate = await _panePixel(tester);
            expect(immediate.$1, greaterThan(immediate.$2));
            expect(immediate.$2, greaterThan(immediate.$3));
          }
          if (!reducedMotion) {
            await tester.pump(const Duration(milliseconds: 130));
            final (int, int, int, int) halfway = await _panePixel(tester);
            expect(halfway.$3, lessThan(white.$3));
            expect(halfway.$3, greaterThan(92));
            expect(halfway.$4, greaterThan(white.$4));
            expect(halfway.$4, lessThan(112));
          }
          await tester.pump(const Duration(milliseconds: 300));
          final (int, int, int, int) yellow = await _panePixel(tester);
          expect(yellow.$1, greaterThan(yellow.$2));
          expect(yellow.$2, greaterThan(yellow.$3));
          expect(yellow.$4, closeTo(112, 1));
          expect(
            find.semantics.byLabel('Card. Wait.').evaluate(),
            hasLength(1),
          );
          expect(find.text('Captured'), findsNothing);
          expect(find.textContaining('Lightning Bolt'), findsNothing);
          await show(acknowledged: true);
          if (reducedMotion) {
            final (int, int, int, int) immediate = await _panePixel(tester);
            expect(immediate.$2, greaterThan(immediate.$1));
            expect(immediate.$2, greaterThan(immediate.$3));
          }
          if (!reducedMotion) {
            await tester.pump(const Duration(milliseconds: 130));
            final (int, int, int, int) halfway = await _panePixel(tester);
            expect(halfway.$1, lessThan(yellow.$1));
            expect(halfway.$1, greaterThan(117));
            expect(halfway.$4, greaterThan(yellow.$4));
            expect(halfway.$4, lessThan(133));
          }
          await tester.pumpAndSettle();
          final (int, int, int, int) green = await _panePixel(tester);
          expect(green.$2, greaterThan(green.$1));
          expect(green.$2, greaterThan(green.$3));
          expect(green.$4, closeTo(133, 1));
          final (int, int) savedMarker = await _markerPixels(
            tester,
            const Rect.fromLTWH(160, 230, 80, 80),
          );
          expect(savedMarker.$1, greaterThan(0));
          expect(savedMarker.$2, greaterThan(0));
          expect(find.textContaining('Lightning Bolt'), findsNothing);
          expect(
            find.semantics
                .byLabel('Card. Saved. Ready. Identifying.')
                .evaluate(),
            hasLength(1),
          );
          await show();
          final (int, int, int, int) revoked = await _panePixel(tester);
          expect(revoked.$1, greaterThan(revoked.$2));
          expect(revoked.$2, greaterThan(revoked.$3));
          expect(revoked.$4, closeTo(112, 1));
          expect(tracker.identifyCaptured(source.crop, saved), 1);
          await show();
          await tester.pumpAndSettle();
          final (int, int, int, int) identifiedWithoutAck = await _panePixel(
            tester,
          );
          expect(identifiedWithoutAck.$1, greaterThan(identifiedWithoutAck.$2));
          expect(identifiedWithoutAck.$2, greaterThan(identifiedWithoutAck.$3));
          expect(identifiedWithoutAck.$4, closeTo(112, 1));
          expect(
            await _markerPixels(tester, const Rect.fromLTWH(160, 230, 80, 80)),
            (0, 0),
          );
          expect(
            find.semantics.byLabel(
              'Lightning Bolt. Identified. Printing review required. Wait.',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          tracker.dispose();
        }
      },
    );
  }
  testWidgets(
    'pane follows the perspective quad with a uniform translucent fill and no edge stroke',
    (WidgetTester tester) async {
      final LiveScanTrack source = _track('source', .1);
      final LiveScanTrack track = LiveScanTrack(
        id: 'perspective',
        lastSeen: DateTime(2026),
        detection: LiveCardDetection(
          confidence: .95,
          lines: source.crop.lines,
          corners: const <ScanPoint>[
            ScanPoint(.125, .25),
            ScanPoint(.375, 17 / 60),
            ScanPoint(.4125, .65),
            ScanPoint(.1, .6),
          ],
        ),
      );
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: LiveCaptureOverlay(
              tracks: <LiveScanTrack>[track],
              transform: CapturePreviewTransform(
                sourceSize: const Size(800, 600),
                viewportSize: const Size(800, 600),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(
            find.descendant(
              of: find.byType(LiveCaptureOverlay),
              matching: find.byType(RepaintBoundary),
            ),
          );
      final List<(int, int, int, int)>? pixels = await tester
          .runAsync<List<(int, int, int, int)>>(() async {
            final ui.Image image = await boundary.toImage();
            try {
              final ByteData bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawStraightRgba,
              ))!;
              return <(int, int, int, int)>[
                for (final (int x, int y) in const <(int, int)>[
                  (200, 250),
                  (94, 250),
                  (315, 370),
                  (85, 160),
                  (89, 250),
                ])
                  (
                    bytes.getUint8((y * image.width + x) * 4),
                    bytes.getUint8((y * image.width + x) * 4 + 1),
                    bytes.getUint8((y * image.width + x) * 4 + 2),
                    bytes.getUint8((y * image.width + x) * 4 + 3),
                  ),
              ];
            } finally {
              image.dispose();
            }
          });
      expect(pixels!.take(3), everyElement((255, 255, 255, 66)));
      expect(
        pixels.skip(3).map(((int, int, int, int) pixel) => pixel.$4),
        everyElement(0),
      );
      expect(
        find.semantics.byLabel('Card. Reading…').evaluate().single.rect,
        const Rect.fromLTRB(80, 150, 330, 390),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'three cards retain identity semantics without text covering the preview',
    (WidgetTester tester) async {
      final sf.MtgCard card = sf.MtgCard.fromJson(
        jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<String, Object?>,
      );
      final List<LiveScanTrack> tracks = <LiveScanTrack>[
        for (final double x in <double>[.02, .35, .67])
          _track('card-$x', x)
            ..resolution = ScanResolution(
              candidates: <ScanCandidate>[
                ScanCandidate(card, <ScanEvidence>{ScanEvidence.nameMatch}),
              ],
              hints: const ScanHints(names: <String>[]),
              status: ScanResolutionStatus.needsReview,
            ),
      ];
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(375, 667),
              disableAnimations: true,
            ),
            child: LiveCaptureOverlay(
              tracks: tracks,
              transform: CapturePreviewTransform(
                sourceSize: const Size(375, 667),
                viewportSize: const Size(375, 667),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsNothing);
      expect(find.textContaining(card.name), findsNothing);
      expect(
        find.descendant(
          of: find.byType(LiveCaptureOverlay),
          matching: find.byType(Text),
        ),
        findsNothing,
        reason:
            'Names and statuses remain semantic instead of covering card art',
      );
      expect(find.textContaining('Review printing'), findsNothing);
      expect(
        find.semantics.byLabel('${card.name}. Name matched · Review printing'),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desk proposals do not draw labels or counts; readable unconfirmed cards remain Reading',
    (WidgetTester tester) async {
      final List<LiveScanTrack> desk = <LiveScanTrack>[
        for (int index = 0; index < 5; index++)
          _track('desk-$index', .05 + index * .1, readable: false),
      ];
      Future<void> show(List<LiveScanTrack> tracks) => tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: LiveCaptureOverlay(
              tracks: tracks,
              transform: CapturePreviewTransform(
                sourceSize: const Size(800, 600),
                viewportSize: const Size(800, 600),
              ),
            ),
          ),
        ),
      );
      await show(desk);
      await tester.pumpAndSettle();
      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(
            find.descendant(
              of: find.byType(LiveCaptureOverlay),
              matching: find.byType(RepaintBoundary),
            ),
          );
      final bool? blankIsClear = await tester.runAsync<bool>(() async {
        final ui.Image blank = await boundary.toImage();
        try {
          final ByteData pixels = (await blank.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return !pixels.buffer.asUint8List().any((int value) => value != 0);
        } finally {
          blank.dispose();
        }
      });
      expect(
        blankIsClear,
        isTrue,
        reason: 'Blank desk proposals must not paint any outline or label',
      );
      expect(find.textContaining('cards'), findsNothing);
      await show(<LiveScanTrack>[...desk, _track('readable', .1)]);
      await tester.pumpAndSettle();
      expect(find.semantics.byLabel('Card. Reading…'), findsOneWidget);
      expect(find.text('Card detected'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final bool weakOcr in <bool>[false, true]) {
    testWidgets(
      'printing labels require clean geometry and confident OCR: $weakOcr',
      (WidgetTester tester) async {
        final sf.MtgCard card = sf.MtgCard.fromJson(
          jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<String, dynamic>,
        );
        final List<LiveScanTrack> tracks = <LiveScanTrack>[
          for (int index = 0; index < 3; index++)
            LiveScanTrack(
                id: '$index',
                lastSeen: DateTime(2026),
                detection: LiveCardDetection(
                  confidence: !weakOcr && index == 2 ? 0 : .95,
                  warnings: !weakOcr && index == 1
                      ? const <String>['incomplete_card']
                      : const <String>[],
                  lines: <ScanTextLine>[
                    ScanTextLine(
                      text: card.name,
                      confidence: weakOcr && index == 2 ? .5 : .95,
                      bounds: const ScanBounds(.1, .03, .7, .04),
                    ),
                    ScanTextLine(
                      text:
                          '${card.collectorNumber} ${card.set.toUpperCase()} EN',
                      confidence: weakOcr && index == 1 ? .5 : .95,
                      bounds: const ScanBounds(.1, .9, .7, .04),
                    ),
                  ],
                  corners: <ScanPoint>[
                    ScanPoint(.1, .05 + index * .3),
                    ScanPoint(.9, .05 + index * .3),
                    ScanPoint(.9, .25 + index * .3),
                    ScanPoint(.1, .25 + index * .3),
                  ],
                ),
              )
              ..resolution = ScanResolution(
                candidates: <ScanCandidate>[
                  ScanCandidate(card, <ScanEvidence>{
                    ScanEvidence.footerMatch,
                    ScanEvidence.nameMatch,
                  }),
                ],
                hints: const ScanHints(names: <String>[]),
                status: ScanResolutionStatus.exactPrinting,
              ),
        ];
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: LiveCaptureOverlay(
                tracks: tracks,
                transform: CapturePreviewTransform(
                  sourceSize: const Size(800, 600),
                  viewportSize: const Size(800, 600),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Printing matched'), findsNothing);
        expect(find.text('Name matched · Review printing'), findsNothing);
        expect(
          find.semantics.byLabel(RegExp('Printing matched')),
          findsOneWidget,
        );
        expect(
          find.semantics.byLabel(RegExp('Name matched · Review printing')),
          findsNWidgets(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  test('cover maps upright card corners and focus through the same crop', () {
    final CapturePreviewTransform transform = CapturePreviewTransform(
      sourceSize: const Size(400, 800),
      viewportSize: const Size(400, 400),
    );
    expect(transform.project(const Offset(.25, .25)), const Offset(100, 0));
    expect(transform.project(const Offset(.75, .75)), const Offset(300, 400));
    expect(
      transform.normalizedTap(const Offset(100, 0)),
      const Offset(.25, .25),
    );
    expect(
      transform.normalizedTap(const Offset(300, 400)),
      const Offset(.75, .75),
    );
  });

  test('landscape cover preserves preview geometry rather than stretching', () {
    final CapturePreviewTransform transform = CapturePreviewTransform(
      sourceSize: const Size(800, 400),
      viewportSize: const Size(400, 400),
    );
    expect(transform.project(const Offset(.25, .25)), const Offset(0, 100));
    expect(
      transform.normalizedTap(const Offset(400, 300)),
      const Offset(.75, .75),
    );
  });

  for (final int count in <int>[4, 8]) {
    testWidgets(
      '$count card identities remain accessible and every preview corner passes focus taps at 320px/2.35',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final Map<String, Object?> printing = jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final List<LiveScanTrack> tracks = <LiveScanTrack>[
          for (int index = 0; index < count; index++)
            _track('$index', .05 + (index % 2) * .3)
              ..resolution = ScanResolution(
                status: ScanResolutionStatus.needsReview,
                hints: const ScanHints(names: <String>[]),
                candidates: <ScanCandidate>[
                  ScanCandidate(
                    sf.MtgCard.fromJson(<String, Object?>{
                      ...printing,
                      'name': 'Printing number ${index + 1}',
                    }),
                    <ScanEvidence>{ScanEvidence.nameMatch},
                  ),
                ],
              ),
        ];
        int focusTaps = 0;
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 667),
                textScaler: TextScaler.linear(2.35),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => focusTaps++,
              child: LiveCaptureOverlay(
                tracks: tracks,
                transform: CapturePreviewTransform(
                  sourceSize: const Size(320, 667),
                  viewportSize: const Size(320, 667),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (int index = 0; index < count; index++) {
          expect(
            find.semantics.byLabel(
              'Printing number ${index + 1}. Name matched · Review printing',
            ),
            findsOneWidget,
          );
        }
        for (final Offset point in const <Offset>[
          Offset(8, 8),
          Offset(160, 320),
          Offset(8, 650),
          Offset(310, 650),
        ]) {
          await tester.tapAt(point);
          await tester.pump();
        }
        expect(focusTaps, 4);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final double scale in <double>[1, 1.8]) {
    testWidgets(
      'eight cards expose invisible statuses without floating panels at scale $scale',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 440);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final List<LiveScanTrack> tracks = <LiveScanTrack>[
          for (int index = 0; index < 8; index++)
            LiveScanTrack(
              id: '$index',
              lastSeen: DateTime(2026),
              detection: LiveCardDetection(
                confidence: .9,
                lines: const <ScanTextLine>[
                  ScanTextLine(
                    text: 'Lightning Bolt',
                    confidence: .95,
                    bounds: ScanBounds(.1, .04, .7, .03),
                  ),
                ],
                corners: <ScanPoint>[
                  ScanPoint(.04 + (index % 2) * .5, .03 + (index ~/ 2) * .24),
                  ScanPoint(.45 + (index % 2) * .5, .03 + (index ~/ 2) * .24),
                  ScanPoint(.45 + (index % 2) * .5, .23 + (index ~/ 2) * .24),
                  ScanPoint(.04 + (index % 2) * .5, .23 + (index ~/ 2) * .24),
                ],
              ),
            ),
        ];
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 440),
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
              ),
              child: LiveCaptureOverlay(
                tracks: tracks,
                transform: CapturePreviewTransform(
                  sourceSize: const Size(320, 440),
                  viewportSize: const Size(320, 440),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (int index = 1; index <= 8; index++) {
          expect(find.text('$index'), findsNothing);
        }
        expect(
          find.semantics.byLabel('Card. Reading…').evaluate(),
          hasLength(8),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets(
      'semantic states distinguish provisional printing and unacknowledged capture at text scale $scale',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final sf.MtgCard card = sf.MtgCard.fromJson(
          jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<String, dynamic>,
        );
        final LiveScanTrack name = _track('name', .05);
        name.resolution = ScanResolution(
          candidates: <ScanCandidate>[
            ScanCandidate(card, <ScanEvidence>{ScanEvidence.nameMatch}),
          ],
          hints: const ScanHints(names: <String>[]),
          status: ScanResolutionStatus.needsReview,
        );
        final LiveScanTrack captured = _capturedTrack(.6);
        captured.resolution = ScanResolution(
          candidates: <ScanCandidate>[
            ScanCandidate(card, <ScanEvidence>{ScanEvidence.footerMatch}),
          ],
          hints: const ScanHints(names: <String>[]),
          status: ScanResolutionStatus.exactPrinting,
        );
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 667),
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
              ),
              child: SizedBox.expand(
                child: LiveCaptureOverlay(
                  tracks: <LiveScanTrack>[name, captured],
                  transform: CapturePreviewTransform(
                    sourceSize: const Size(400, 800),
                    viewportSize: const Size(320, 667),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.semantics.byLabel(
            '${card.name}. Name matched · Review printing',
          ),
          findsOneWidget,
        );
        expect(find.semantics.byLabel('Card. Wait.'), findsOneWidget);
        expect(
          find.semantics.byLabel(RegExp(r'Saved\. Ready\.')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
