import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/user/app_user_restricted.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/pages/dock/hub_settings.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

import 'helpers/load_collector_fonts.dart';

class _Auth extends Fake implements CollectorAuth {
  int signOuts = 0;
  @override
  Future<void> signOut() async {
    signOuts++;
  }
}

void main() {
  setUpAll(loadCollectorFonts);
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'compact settings ${mode.name} at $scale keeps account and preference controls reachable',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final SemanticsHandle semantics = tester.ensureSemantics();
          try {
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
                  value: AppUser().copyWith(showCommander: true),
                  child: const HubSettings(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(AppBar), findsNothing);
            expect(find.text('Appearance'), findsOneWidget);
            expect(
              find.text('Show the Commander health counter in Dice.'),
              findsNothing,
            );
            expect(find.byType(Switch), findsNothing);
            expect(find.text('Account'), findsOneWidget);
            expect(find.text('Administration'), findsNothing);
            for (final String action in <String>[
              'Appearance',
              'Tabletop',
              'Privacy & data',
              'Sign Out',
            ]) {
              await tester.ensureVisible(find.text(action));
              await tester.pumpAndSettle();
              expect(find.text(action).hitTestable(), findsOneWidget);
            }
            if (scale == 1) {
              expect(
                tester
                    .state<ScrollableState>(find.byType(Scrollable).first)
                    .position
                    .maxScrollExtent,
                0,
              );
            }
            await tester.ensureVisible(find.text('Appearance'));
            await tester.tap(find.text('Appearance'));
            await tester.pumpAndSettle();
            expect(find.text('Light theme').hitTestable(), findsOneWidget);
            expect(find.byType(Switch), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey<String>('settings-topics')),
            );
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('Tabletop'));
            await tester.tap(find.text('Tabletop'));
            await tester.pumpAndSettle();
            expect(find.text('Commander').hitTestable(), findsOneWidget);
            expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
  for (final bool administrator in <bool>[false, true]) {
    testWidgets(
      'administration is discoverable only for an administrator=$administrator',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: Provider<AppUserRestricted?>.value(
              value: AppUserRestricted(admin: administrator),
              child: Provider<AppUser?>.value(
                value: AppUser(),
                child: const HubSettings(cloudRecognitionEnabled: false),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Administration'),
          administrator ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a failed preference write stays in its editor and preserves saved value',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: Provider<AppUser?>.value(
            value: AppUser(),
            child: const HubSettings(cloudRecognitionEnabled: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save your preference. Try again.'),
        findsOneWidget,
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      expect(find.text('Light theme').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sign out acts directly without a second confirmation', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: Provider<AppUser?>.value(
          value: AppUser(),
          child: HubSettings(auth: auth, cloudRecognitionEnabled: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();
    expect(auth.signOuts, 1);
    expect(find.byType(ArcaneDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
