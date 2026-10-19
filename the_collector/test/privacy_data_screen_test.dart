import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/account/privacy_data_screen.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

Future<void> _show(
  WidgetTester tester, {
  bool deletion = false,
  ThemeMode mode = ThemeMode.light,
  double scale = 1,
  String privacyPolicyUrl = '',
  Future<void> Function(Uri)? openLink,
  bool cloudRecognitionEnabled = false,
}) async {
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
      home: PrivacyDataScreen(
        accountDeletionEnabled: deletion,
        privacyPolicyUrl: privacyPolicyUrl,
        openLink: openLink,
        cloudRecognitionEnabled: cloudRecognitionEnabled,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _openTopic(WidgetTester tester, String title) async {
  await _reveal(tester, find.text(title));
  await tester.tap(find.text(title).hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _closeTopic(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('privacy-topics')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets(
    'privacy describes local defaults and opt-in third-party crops truthfully',
    (WidgetTester tester) async {
      await _show(tester);
      await _openTopic(tester, 'Camera and recognition');
      expect(
        find.textContaining('does not upload your photos'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cloud recognition is off by default'),
        findsNothing,
      );
      await _closeTopic(tester);
      await _show(tester, cloudRecognitionEnabled: true);
      await _openTopic(tester, 'Camera and recognition');
      expect(find.textContaining('does not upload your photos'), findsNothing);
      expect(
        find.textContaining('Cloud recognition is off by default'),
        findsOneWidget,
      );
      expect(
        find.textContaining('sent through Firebase to Google Cloud'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Photos already sent cannot be recalled'),
        findsOneWidget,
      );
      await _closeTopic(tester);
      await _reveal(tester, find.text('Google Cloud data handling'));
      expect(
        find.text('Google Cloud data handling').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('privacy policy link is hidden without publisher configuration', (
    WidgetTester tester,
  ) async {
    await _show(tester);
    await _reveal(tester, find.text('Provider information'));
    expect(find.text('Privacy policy'), findsNothing);
    expect(find.text('Firebase privacy'), findsOneWidget);
    expect(find.text('Scryfall API documentation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'configured privacy policy launches its exact HTTPS destination',
    (WidgetTester tester) async {
      final List<Uri> opened = <Uri>[];
      const String policyUrl = 'https://example.test/privacy?version=2#data';
      await _show(
        tester,
        privacyPolicyUrl: policyUrl,
        openLink: (Uri uri) async => opened.add(uri),
      );
      await tester.tap(find.text('Privacy policy').hitTestable());
      await tester.pumpAndSettle();
      expect(opened, <Uri>[Uri.parse(policyUrl)]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final MapEntry<String, String> invalid in <String, String>{
    'HTTP': 'http://example.test/privacy',
    'JavaScript': 'javascript:alert(1)',
    'file': 'file:///privacy',
    'opaque HTTPS': 'https:privacy',
    'missing host': 'https:///privacy',
    'password': 'https://name:private-secret@example.test/privacy',
    'username': 'https://name@example.test/privacy',
    'malformed host': 'https://[invalid/privacy',
  }.entries) {
    testWidgets('rejects invalid policy URL with ${invalid.key}', (
      WidgetTester tester,
    ) async {
      await _show(tester, privacyPolicyUrl: invalid.value);
      final Object? error = tester.takeException();
      expect(error, isA<ArgumentError>());
      expect(
        error.toString(),
        contains(
          'Privacy policy URL must use HTTPS with a host and no credentials.',
        ),
      );
      expect(error.toString(), isNot(contains('private-secret')));
      expect(error.toString(), isNot(contains(invalid.value)));
    });
  }

  testWidgets('policy configuration updates replace and hide its destination', (
    WidgetTester tester,
  ) async {
    final List<Uri> opened = <Uri>[];
    Future<void> openLink(Uri uri) async => opened.add(uri);
    await _show(
      tester,
      privacyPolicyUrl: 'https://example.test/first',
      openLink: openLink,
    );
    await _show(
      tester,
      privacyPolicyUrl: 'https://example.test/second',
      openLink: openLink,
    );
    await tester.tap(find.text('Privacy policy').hitTestable());
    await tester.pumpAndSettle();
    expect(opened, <Uri>[Uri.parse('https://example.test/second')]);
    await _show(tester, openLink: openLink);
    expect(find.text('Privacy policy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'privacy policy failure is readable, blocks duplicates, and permits retry',
    (WidgetTester tester) async {
      final Completer<void> pending = Completer<void>();
      int calls = 0;
      await _show(
        tester,
        privacyPolicyUrl: 'https://example.test/privacy',
        openLink: (Uri uri) {
          calls++;
          return calls == 1 ? pending.future : Future<void>.value();
        },
      );
      await tester.tap(find.text('Privacy policy').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Privacy policy').hitTestable());
      expect(calls, 1);
      pending.completeError(StateError('private launch detail'));
      await tester.pumpAndSettle();
      await _reveal(tester, find.text('Could not open the link. Try again.'));
      expect(find.textContaining('private launch detail'), findsNothing);
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        expect(
          tester
              .getSemantics(find.text('Could not open the link. Try again.'))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
      } finally {
        semantics.dispose();
      }
      await tester.scrollUntilVisible(
        find.text('Privacy policy'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Privacy policy').hitTestable());
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Could not open the link. Try again.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('const privacy policy constructor reads the compile define', (
    WidgetTester tester,
  ) async {
    const PrivacyDataScreen defaultScreen = PrivacyDataScreen();
    const String configured = String.fromEnvironment('PRIVACY_POLICY_URL');
    expect(defaultScreen.privacyPolicyUrl, configured);
    final List<Uri> opened = <Uri>[];
    await _show(
      tester,
      privacyPolicyUrl: defaultScreen.privacyPolicyUrl,
      openLink: (Uri uri) async => opened.add(uri),
    );
    if (configured.isEmpty) {
      expect(find.text('Privacy policy'), findsNothing);
    } else {
      await tester.tap(find.text('Privacy policy').hitTestable());
      await tester.pumpAndSettle();
      expect(opened, <Uri>[Uri.parse(configured)]);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'deletion documentation defaults off and enables only with rollout flag',
    (WidgetTester tester) async {
      await _show(tester);
      await _reveal(tester, find.text('Provider information'));
      expect(find.text('Delete your account'), findsNothing);
      await _show(tester, deletion: true);
      await _openTopic(tester, 'Delete your account');
      expect(find.text('Delete your account'), findsOneWidget);
      await _reveal(tester, find.textContaining('Delete account in Settings'));
      expect(
        find.textContaining('Gallery originals are not deleted.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('privacy index opens one topic without a disclosure wall', (
    WidgetTester tester,
  ) async {
    await _show(tester);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text('Camera and recognition').hitTestable(), findsOneWidget);
    await _openTopic(tester, 'Camera and recognition');
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('does not upload your photos'), findsOneWidget);
    expect(find.text('Photos and local drafts').hitTestable(), findsNothing);
    await _closeTopic(tester);
    await _openTopic(tester, 'Photos and local drafts');
    expect(find.textContaining('managed local draft storage'), findsOneWidget);
    expect(find.textContaining('does not upload your photos'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'external buttons open primary provider destinations through injected helper',
    (WidgetTester tester) async {
      final List<Uri> opened = <Uri>[];
      await _show(
        tester,
        openLink: (Uri uri) async {
          opened.add(uri);
        },
      );
      for (final String label in <String>[
        'Firebase privacy',
        'Scryfall API documentation',
      ]) {
        await _reveal(tester, find.text(label));
        await tester.tap(find.text(label).hitTestable());
        await tester.pumpAndSettle();
      }
      expect(opened, <Uri>[
        Uri.parse('https://firebase.google.com/support/privacy'),
        Uri.parse('https://scryfall.com/docs/api'),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed provider link is readable and can retry without duplicate opens',
    (WidgetTester tester) async {
      int calls = 0;
      final Completer<void> pending = Completer<void>();
      await _show(
        tester,
        openLink: (Uri uri) {
          calls++;
          return calls == 1 ? pending.future : Future<void>.value();
        },
      );
      await _reveal(tester, find.text('Firebase privacy'));
      await tester.tap(find.text('Firebase privacy').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Firebase privacy').hitTestable());
      expect(calls, 1);
      pending.completeError(StateError('private detail'));
      await tester.pumpAndSettle();
      await _reveal(tester, find.text('Could not open the link. Try again.'));
      expect(find.textContaining('private detail'), findsNothing);
      await _reveal(tester, find.text('Firebase privacy'));
      await tester.tap(find.text('Firebase privacy').hitTestable());
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Could not open the link. Try again.'), findsNothing);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'all privacy sections and links fit 320px AX large ${mode.name}',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        try {
          await _show(
            tester,
            mode: mode,
            scale: 2.35,
            deletion: true,
            privacyPolicyUrl: 'https://example.test/privacy',
          );
          for (final String label in <String>[
            'Privacy policy',
            'Camera and recognition',
            'Photos and local drafts',
            'Account and cloud data',
            'Shared games',
            'Card lookups and other services',
            'Advertising and analytics',
            'Delete your account',
            'Provider information',
            'Firebase privacy',
            'Scryfall API documentation',
          ]) {
            await _reveal(tester, find.text(label));
            final Rect bounds = tester.getRect(find.text(label));
            expect(bounds.left, greaterThanOrEqualTo(0), reason: label);
            expect(bounds.right, lessThanOrEqualTo(320), reason: label);
            expect(
              find.text(label).hitTestable(),
              findsOneWidget,
              reason: label,
            );
            expect(tester.takeException(), isNull, reason: label);
            if (label == 'Privacy policy') {
              expect(
                tester
                    .getSemantics(find.bySemanticsLabel(label).first)
                    .getSemanticsData()
                    .flagsCollection
                    .isButton,
                isTrue,
              );
            }
          }
          expect(
            tester
                .getSemantics(find.bySemanticsLabel('Firebase privacy').first)
                .getSemanticsData()
                .flagsCollection
                .isButton,
            isTrue,
          );
          expect(
            tester
                .getSemantics(
                  find.bySemanticsLabel('Scryfall API documentation').first,
                )
                .getSemanticsData()
                .flagsCollection
                .isButton,
            isTrue,
          );
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'closing page during external launch does not update disposed state',
    (WidgetTester tester) async {
      final Completer<void> pending = Completer<void>();
      await _show(tester, openLink: (Uri uri) => pending.future);
      await _reveal(tester, find.text('Firebase privacy'));
      await tester.tap(find.text('Firebase privacy').hitTestable());
      await tester.pumpWidget(const SizedBox.shrink());
      pending.completeError(StateError('failed launch'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
