import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/dock/hub_settings.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/cloud_scan_consent.dart';
import 'package:the_collector/utils/scanning/cloud_card_hints_service.dart';

import 'helpers/load_collector_fonts.dart';

Future<void> _show(
  WidgetTester tester,
  CloudScanConsentStore store, {
  bool enabled = true,
  ThemeMode mode = ThemeMode.dark,
  double scale = 1,
  CloudCardHintsService? hints,
}) async {
  final CloudCardHintsService service =
      hints ??
      CloudCardHintsService(
        enabled: enabled,
        statusCallable: () async => <String, Object?>{
          'configured': true,
          'mode': 'text-transcription',
          'model': 'fixture-model',
        },
      );
  if (hints == null) addTearDown(service.dispose);
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 568),
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: Provider<AppUser?>.value(
        value: AppUser(),
        child: HubSettings(
          cloudRecognitionEnabled: enabled,
          cloudConsent: store,
          cloudHints: service,
          userId: 'alice',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (enabled) {
    await tester.tap(find.text('Scanning'));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(loadCollectorFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('disabled build keeps cloud controls absent', (
    WidgetTester tester,
  ) async {
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => 'alice',
    );
    addTearDown(store.dispose);
    await _show(tester, store, enabled: false);
    expect(find.text('Cloud text assistance'), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('loading consent keeps the switch off and disabled', (
    WidgetTester tester,
  ) async {
    final Completer<SharedPreferences> loading = Completer<SharedPreferences>();
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => 'alice',
      preferences: () => loading.future,
    );
    addTearDown(store.dispose);
    await _show(tester, store);
    final Switch toggle = tester.widget<Switch>(
      find.byKey(const ValueKey<String>('cloud-recognition-consent')),
    );
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
    loading.complete(await SharedPreferences.getInstance());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey<String>('cloud-recognition-consent')),
          )
          .onChanged,
      isNotNull,
    );
  });

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'unconfigured cloud at AX2.35 cannot be enabled and Check status recovers in ${mode.name}',
      (WidgetTester tester) async {
        bool configured = false;
        int checks = 0;
        final CloudScanConsentStore store = CloudScanConsentStore(
          currentUserId: () => 'alice',
        );
        final CloudCardHintsService service = CloudCardHintsService(
          enabled: true,
          statusCallable: () async {
            checks++;
            return <String, Object?>{
              'configured': configured,
              'mode': 'text-transcription',
              'model': configured ? 'fixture-model' : null,
            };
          },
        );
        addTearDown(store.dispose);
        addTearDown(service.dispose);
        await _show(tester, store, hints: service, mode: mode, scale: 2.35);
        final Finder toggle = find.byKey(
          const ValueKey<String>('cloud-recognition-consent'),
        );
        expect(tester.widget<Switch>(toggle).onChanged, isNull);
        expect(tester.widget<Switch>(toggle).value, isFalse);
        expect(await store.isGranted('alice'), isFalse);
        expect(find.text('Cloud service not configured'), findsOneWidget);
        final Finder check = find.byKey(
          const ValueKey<String>('cloud-assistance-check'),
        );
        await tester.ensureVisible(check);
        await tester.pumpAndSettle();
        expect(check.hitTestable(), findsOneWidget);
        configured = true;
        await tester.tap(check);
        await tester.pumpAndSettle();
        expect(checks, 2);
        expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
        expect(await store.isGranted('alice'), isFalse);
        expect(find.text('Text assistance configured'), findsOneWidget);
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(await store.isGranted('alice'), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'undeployed endpoint is visible and an existing consent can always be switched off',
    (WidgetTester tester) async {
      final CloudScanConsentStore store = CloudScanConsentStore(
        currentUserId: () => 'alice',
      );
      await store.setGranted('alice', true);
      final CloudCardHintsService service = CloudCardHintsService(
        enabled: true,
        statusCallable: () async => throw FirebaseFunctionsException(
          code: 'not-found',
          message: 'Function absent',
        ),
      );
      addTearDown(store.dispose);
      addTearDown(service.dispose);
      await _show(tester, store, hints: service);
      expect(find.text('Cloud service not deployed'), findsOneWidget);
      final Finder toggle = find.byKey(
        const ValueKey<String>('cloud-recognition-consent'),
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(await store.isGranted('alice'), isFalse);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(tester.widget<Switch>(toggle).onChanged, isNull);
      expect(find.text('Cloud service not deployed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2]) {
      testWidgets(
        'explicit cloud consent toggle ${mode.name} at $scale fits and persists',
        (WidgetTester tester) async {
          final CloudScanConsentStore store = CloudScanConsentStore(
            currentUserId: () => 'alice',
          );
          addTearDown(store.dispose);
          await _show(tester, store, mode: mode, scale: scale);
          final Finder toggle = find.byKey(
            const ValueKey<String>('cloud-recognition-consent'),
          );
          expect(tester.widget<Switch>(toggle).value, isFalse);
          expect(
            find.textContaining('Saved crops go to Google Cloud'),
            findsOneWidget,
          );
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(await store.isGranted('alice'), isTrue);
          expect(tester.widget<Switch>(toggle).value, isTrue);
          final CloudScanPermission lease = (await store.acquire('alice'))!;
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(lease.isValid, isFalse);
          expect(await store.isGranted('alice'), isFalse);
          await tester.ensureVisible(
            find.byKey(const ValueKey<String>('settings-topics')),
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('settings-topics')),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Sign Out'));
          await tester.pumpAndSettle();
          expect(find.text('Sign Out').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
