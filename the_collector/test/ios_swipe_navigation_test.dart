import 'package:arcane/arcane.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart' show FadeForwardsPageTransitionsBuilder;
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

class _Destination extends StatelessWidget {
  const _Destination({this.canPop, this.showRouteData = false});

  final ValueListenable<bool>? canPop;
  final bool showRouteData;

  Widget _page(BuildContext context) => Scaffold(
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('Destination'),
          if (showRouteData) Text(context.pylon<String>()),
          PrimaryButton(
            onPressed: () => Navigator.of(context).pop(7),
            child: const Text('Complete'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ValueListenable<bool>? allowed = canPop;
    if (allowed == null) return _page(context);
    return ValueListenableBuilder<bool>(
      valueListenable: allowed,
      builder: (BuildContext context, bool value, Widget? child) =>
          PopScope<int>(canPop: value, child: _page(context)),
    );
  }
}

Future<void> _open(
  WidgetTester tester, {
  bool named = false,
  ValueListenable<bool>? canPop,
  required ValueChanged<Object?> onReturned,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      routes: <String, WidgetBuilder>{
        '/destination': (BuildContext context) => _Destination(canPop: canPop),
      },
      home: Pylon<String>(
        value: 'Inherited route data',
        builder: (BuildContext context) => Scaffold(
          child: Center(
            child: PrimaryButton(
              onPressed: () async {
                final Object? result = named
                    ? await Navigator.of(context)
                          .pushNamed<Object?>('/destination')
                    : await Arcane.push<int>(
                        context,
                        _Destination(canPop: canPop, showRouteData: true),
                      );
                onReturned(result);
              },
              child: const Text('Open destination'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open destination'));
  await tester.pumpAndSettle();
  expect(find.text('Destination'), findsOneWidget);
}

Future<void> _swipeBack(WidgetTester tester) async {
  await tester.dragFrom(const Offset(1, 400), const Offset(330, 0));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('only iOS uses the Cupertino transition builder', () {
    final ArcaneTheme theme = MyThemeData.themeData(ThemeMode.dark);
    for (final TargetPlatform platform in TargetPlatform.values) {
      final Object? builder =
          theme.materialThemeData.pageTransitionsTheme.builders[platform];
      expect(
        builder,
        platform == TargetPlatform.iOS
            ? isA<CupertinoPageTransitionsBuilder>()
            : isA<FadeForwardsPageTransitionsBuilder>(),
      );
    }
  });

  for (final bool named in <bool>[false, true]) {
    testWidgets(
      '${named ? 'named' : 'Arcane'} route returns null after an iOS edge swipe',
      (WidgetTester tester) async {
        bool returned = false;
        Object? result;
        await _open(
          tester,
          named: named,
          onReturned: (Object? value) {
            returned = true;
            result = value;
          },
        );
        if (!named) expect(find.text('Inherited route data'), findsOneWidget);
        await _swipeBack(tester);
        expect(returned, isTrue);
        expect(result, isNull);
        expect(find.text('Destination'), findsNothing);
        expect(find.text('Open destination').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('Arcane routes retain their explicit return value', (
    WidgetTester tester,
  ) async {
    Object? result;
    await _open(tester, onReturned: (Object? value) => result = value);
    await tester.tap(find.text('Complete'));
    await tester.pumpAndSettle();
    expect(result, 7);
    expect(find.text('Destination'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('PopScope blocks the edge swipe until saving permits departure', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> canPop = ValueNotifier<bool>(false);
    addTearDown(canPop.dispose);
    bool returned = false;
    await _open(
      tester,
      canPop: canPop,
      onReturned: (Object? value) => returned = true,
    );
    await _swipeBack(tester);
    expect(returned, isFalse);
    expect(find.text('Destination'), findsOneWidget);
    canPop.value = true;
    await tester.pump();
    await _swipeBack(tester);
    expect(returned, isTrue);
    expect(find.text('Destination'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
