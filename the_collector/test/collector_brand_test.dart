import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 640),
          disableAnimations: reduceMotion,
        ),
        child: Scaffold(child: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadCollectorFonts);
  testWidgets(
    'branded loading exposes its purpose and remains static with reduced motion',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _show(
        tester,
        const CollectorLoading(label: 'Loading your collection...'),
        reduceMotion: true,
      );
      expect(find.byType(CollectorBrandMark), findsOneWidget);
      expect(
        find.bySemanticsLabel('Loading your collection...'),
        findsOneWidget,
      );
      expect(find.text('Loading your collection...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
  testWidgets('typewriter exposes complete text and finishes on tap', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _show(tester, const CollectorTypewriter('Collect Everything.'));
    expect(find.bySemanticsLabel('Collect Everything.'), findsOneWidget);
    expect(find.text('Collect Everything.'), findsNothing);
    await tester.tap(find.byType(CollectorTypewriter));
    await tester.pump();
    expect(find.text('Collect Everything.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'reduced motion shows the brand text and activates without a spin',
    (WidgetTester tester) async {
      int activations = 0;
      await _show(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CollectorBrandMark(onActivated: () => activations++),
            const CollectorTypewriter('Collect Everything.'),
          ],
        ),
        reduceMotion: true,
      );
      expect(find.text('Collect Everything.'), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(activations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('triangle navigation fires once after the full original spin', (
    WidgetTester tester,
  ) async {
    int activations = 0;
    await _show(tester, CollectorBrandMark(onActivated: () => activations++));
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(activations, 0);
    await tester.tap(find.byType(IconButton));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(activations, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'triangle stays within its circular sweep throughout a full turn',
    (WidgetTester tester) async {
      const Key boundaryKey = ValueKey<String>('triangle-sweep');
      await _show(
        tester,
        RepaintBoundary(
          key: boundaryKey,
          child: CollectorBrandMark(onActivated: () {}),
        ),
      );
      await tester.pumpAndSettle();
      final RenderRepaintBoundary boundary = tester.renderObject(
        find.byKey(boundaryKey),
      );
      final double radius = 200 * 648 / 578 / 2;
      int? initialInk;
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      for (int frame = 0; frame < 16; frame++) {
        if (frame > 0) {
          await tester.pump(const Duration(microseconds: 62500));
        }
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage();
          final ByteData pixels = (await image.toByteData())!;
          int ink = 0;
          for (int y = 0; y < image.height; y++) {
            for (int x = 0; x < image.width; x++) {
              final int offset = (y * image.width + x) * 4;
              if (pixels.getUint8(offset) < 220 ||
                  pixels.getUint8(offset + 1) < 220 ||
                  pixels.getUint8(offset + 2) < 220 ||
                  pixels.getUint8(offset + 3) < 220) {
                continue;
              }
              ink++;
              final Offset fromCenter = Offset(
                x + 0.5 - boundary.size.width / 2,
                y + 0.5 - boundary.size.height / 2,
              );
              expect(
                fromCenter.distance,
                lessThanOrEqualTo(radius),
                reason:
                    'Triangle paint escaped its circular sweep at frame $frame.',
              );
            }
          }
          image.dispose();
          expect(ink, greaterThan(1000));
          initialInk ??= ink;
          expect(
            ink,
            closeTo(initialInk!, initialInk! * 0.02),
            reason: 'Triangle paint was clipped at frame $frame.',
          );
        });
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'four native navigation labels fit a narrow screen and select Dice',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      int selected = 0;
      await _show(
        tester,
        ButtonBar(
          selectedIndex: 0,
          buttons: <IconTab>[
            IconTab(
              icon: Icons.cards,
              label: 'Collection',
              onPressed: () => selected = 0,
            ),
            IconTab(
              icon: Icons.dice_six,
              label: 'Dice',
              onPressed: () => selected = 1,
            ),
            IconTab(
              icon: Icons.book_open,
              label: 'Rules',
              onPressed: () => selected = 2,
            ),
            IconTab(
              icon: Icons.gear,
              label: 'Settings',
              onPressed: () => selected = 3,
            ),
          ],
        ),
      );
      for (final String label in <String>[
        'Collection',
        'Dice',
        'Rules',
        'Settings',
      ]) {
        expect(find.text(label), findsOneWidget);
        expect(find.bySemanticsLabel(label), findsOneWidget);
        expect(tester.getSize(find.text(label)).width, lessThan(80));
      }
      await tester.tap(find.text('Dice'));
      await tester.pump();
      expect(selected, 1);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
