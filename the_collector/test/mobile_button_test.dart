import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/theme.dart';

Future<void> _showButtons(
  WidgetTester tester, {
  required Size size,
  required VoidCallback onPressed,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.light),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          child: Center(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                IconButton(
                  key: const Key('touch-icon'),
                  icon: const Icon(Icons.plus),
                  onPressed: onPressed,
                ),
                SecondaryButton(
                  key: const Key('touch-text'),
                  onPressed: onPressed,
                  child: const Text('Use selected finish'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'small phone buttons receive taps throughout the minimum area',
    (WidgetTester tester) async {
      int calls = 0;
      await _showButtons(
        tester,
        size: const Size(375, 667),
        onPressed: () => calls++,
      );
      for (final String key in <String>['touch-icon', 'touch-text']) {
        final Rect area = tester.getRect(find.byKey(Key(key)));
        expect(area.height, greaterThanOrEqualTo(44));
        expect(area.width, greaterThanOrEqualTo(44));
        await tester.tapAt(area.topLeft + const Offset(2, 2));
        await tester.pumpAndSettle();
      }
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{TargetPlatform.iOS}),
  );

  testWidgets(
    'mobile landscape and large text retain usable controls',
    (WidgetTester tester) async {
      await _showButtons(
        tester,
        size: const Size(667, 375),
        textScale: 1.8,
        onPressed: () {},
      );
      expect(
        tester.getSize(find.byKey(const Key('touch-icon'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getSize(find.byKey(const Key('touch-text'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{TargetPlatform.iOS}),
  );

  testWidgets(
    'desktop buttons retain compact density',
    (WidgetTester tester) async {
      await _showButtons(tester, size: const Size(1280, 900), onPressed: () {});
      expect(
        tester.getSize(find.byKey(const Key('touch-icon'))).height,
        lessThan(44),
      );
      expect(
        tester.getSize(find.byKey(const Key('touch-text'))).height,
        lessThan(44),
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.linux,
    }),
  );
}
