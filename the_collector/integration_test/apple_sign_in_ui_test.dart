import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:the_collector/pages/account/collector_sign_in_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

class _ProviderFixture extends Fake implements CollectorAuth {
  final Completer<void> authorization = Completer<void>();
  int appleRequests = 0;

  @override
  bool get supportsGoogleSignIn => true;

  @override
  bool get supportsAppleSignIn => true;

  @override
  Future<DeletionVerification> reauthenticateForDeletion({
    String? password,
  }) async => DeletionVerification.verified;

  @override
  Future<void> signInWithApple() {
    appleRequests++;
    return authorization.future;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native sign-in reaches Apple and recovers from cancellation', (
    WidgetTester tester,
  ) async {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      final _ProviderFixture auth = _ProviderFixture();
      await tester.pumpWidget(
        ArcaneApp(
          key: ValueKey<ThemeMode>(mode),
          theme: MyThemeData.themeData(mode),
          home: MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: const TextScaler.linear(2.35)),
            child: CollectorSignInScreen(auth: auth),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder apple = find.byKey(const Key('auth-apple'));
      final Finder google = find.byKey(const Key('auth-google'));
      await tester.ensureVisible(apple);
      await tester.pump(const Duration(milliseconds: 700));
      expect(apple.hitTestable(), findsOneWidget);
      expect(tester.getSize(apple).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('APP_UI_SCREENSHOTS')) {
        debugPrint('APPLE_UI_READY:${mode.name}');
        await Future<void>.delayed(const Duration(seconds: 4));
      }
      await tester.tap(apple);
      await tester.pumpAndSettle();
      expect(auth.appleRequests, 1);
      expect(tester.widget<SecondaryButton>(apple).onPressed, isNull);
      expect(tester.widget<SecondaryButton>(google).onPressed, isNull);
      auth.authorization.completeError(FirebaseAuthException(code: 'canceled'));
      await tester.pumpAndSettle();
      expect(tester.widget<SecondaryButton>(apple).onPressed, isNotNull);
      expect(tester.widget<SecondaryButton>(google).onPressed, isNotNull);
      expect(find.textContaining('Could not'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
