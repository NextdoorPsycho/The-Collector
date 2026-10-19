import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:the_collector/pages/account/collector_sign_in_screen.dart';
import 'package:the_collector/pages/dock/hub_settings.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

class _Auth extends Fake implements CollectorAuth {
  bool appleEnabled = false;
  final Completer<void> apple = Completer<void>();
  int appleCalls = 0;
  final Completer<void> google = Completer<void>();
  final Completer<void> reset = Completer<void>();
  final Completer<void> logout = Completer<void>();
  int googleCalls = 0;
  int resetCalls = 0;
  int logoutCalls = 0;
  int registerCalls = 0;
  String? registeredEmail;
  String? registeredPassword;

  @override
  Future<void> registerWithEmail(String email, String password) async {
    registerCalls++;
    registeredEmail = email;
    registeredPassword = password;
  }

  @override
  bool get deletionRequiresPassword => true;

  @override
  Future<DeletionVerification> reauthenticateForDeletion({
    String? password,
  }) async => DeletionVerification.verified;

  @override
  bool get supportsGoogleSignIn => true;

  @override
  bool get supportsAppleSignIn => appleEnabled;

  @override
  Future<void> signInWithApple() {
    appleCalls++;
    return apple.future;
  }

  @override
  Future<void> signInWithGoogle() {
    googleCalls++;
    return google.future;
  }

  @override
  Future<void> resetPassword(String email) {
    resetCalls++;
    return reset.future;
  }

  @override
  Future<void> signOut() {
    logoutCalls++;
    return logout.future;
  }
}

Future<void> _showSignIn(
  WidgetTester tester, {
  Size size = const Size(375, 812),
  CollectorAuth? auth,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.light),
      home: CollectorSignInScreen(auth: auth),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('validation stays beside the field and clears when corrected', (
    WidgetTester tester,
  ) async {
    await _showSignIn(tester, auth: _Auth());
    await tester.tap(find.byType(PrimaryButton));
    await tester.pumpAndSettle();
    final Finder error = find.text('Enter a valid email address.');
    expect(error, findsOneWidget);
    expect(
      tester.getRect(error).top,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const Key('auth-email'))).bottom,
      ),
    );
    expect(
      tester.getRect(error).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('auth-password'))).top,
      ),
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('auth-email')),
        matching: find.byType(EditableText),
      ),
      'collector@example.test',
    );
    await tester.pumpAndSettle();
    expect(error, findsNothing);
  });

  for (final bool register in <bool>[false, true]) {
    testWidgets(
      'normal phone ${register ? "registration" : "sign in"} shows all providers without scrolling',
      (WidgetTester tester) async {
        final _Auth auth = _Auth()..appleEnabled = true;
        await _showSignIn(tester, size: const Size(375, 667), auth: auth);
        if (register) {
          await tester.tap(find.text('Create an account'));
          await tester.pumpAndSettle();
        }
        final ScrollableState scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scroll.position.maxScrollExtent, lessThanOrEqualTo(1));
        for (final Finder action in <Finder>[
          find.byType(PrimaryButton),
          find.byKey(const Key('auth-google')),
          find.byKey(const Key('auth-apple')),
          find.widgetWithText(TextButton, 'Privacy & data'),
        ]) {
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'phone keyboard keeps registration controls reachable and reset remains compact',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()..appleEnabled = true;
      await _showSignIn(tester, size: const Size(375, 667), auth: auth);
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .maxScrollExtent,
        lessThanOrEqualTo(1),
      );
      await tester.tap(find.text('Back to sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      expect(find.byType(CollectorBrandMark), findsOneWidget);
      expect(find.text('The Collector'), findsOneWidget);
      final Finder confirmation = find.descendant(
        of: find.byKey(const Key('auth-confirmation')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(confirmation, 'matching password');
      tester.view.viewInsets = const FakeViewPadding(bottom: 290);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byType(CollectorBrandMark), findsOneWidget);
      expect(find.text('The Collector'), findsOneWidget);
      expect(
        tester.widget<EditableText>(confirmation).focusNode.hasFocus,
        isTrue,
      );
      expect(
        tester.widget<EditableText>(confirmation).controller.text,
        'matching password',
      );
      await tester.ensureVisible(find.byKey(const Key('auth-confirmation')));
      await tester.ensureVisible(find.byType(PrimaryButton));
      expect(find.byType(PrimaryButton).hitTestable(), findsOneWidget);
      expect(
        tester.getSize(find.byType(PrimaryButton)).height,
        greaterThanOrEqualTo(44),
      );
      expect(auth.registerCalls, 0);
      tester.widget<EditableText>(confirmation).focusNode.unfocus();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.byType(CollectorBrandMark), findsOneWidget);
      expect(find.text('The Collector'), findsOneWidget);
      expect(
        tester.widget<EditableText>(confirmation).controller.text,
        'matching password',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Apple availability follows configured provider', (
    WidgetTester tester,
  ) async {
    await _showSignIn(tester, auth: _Auth());
    expect(find.byKey(const Key('auth-apple')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _showSignIn(tester, auth: _Auth()..appleEnabled = true);
    expect(find.byKey(const Key('auth-apple')), findsOneWidget);
  });

  for (final String? failure in <String?>[
    null,
    'canceled',
    'invalid-credential',
  ]) {
    testWidgets(
      'Apple completion and cancellation unlock all sign-in methods: $failure',
      (WidgetTester tester) async {
        final _Auth auth = _Auth()..appleEnabled = true;
        await _showSignIn(tester, auth: auth);
        final Finder apple = find.byKey(const Key('auth-apple'));
        final Finder google = find.byKey(const Key('auth-google'));
        await tester.ensureVisible(apple);
        await tester.tap(apple);
        await tester.pumpAndSettle();
        expect(auth.appleCalls, 1);
        expect(tester.widget<SecondaryButton>(apple).onPressed, isNull);
        expect(tester.widget<SecondaryButton>(google).onPressed, isNull);
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
          isNull,
        );
        if (failure == null) {
          auth.apple.complete();
        } else {
          auth.apple.completeError(
            FirebaseAuthException(
              code: failure,
              message: 'Private Apple diagnostic',
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.widget<SecondaryButton>(apple).onPressed, isNotNull);
        expect(tester.widget<SecondaryButton>(google).onPressed, isNotNull);
        expect(find.textContaining('Private Apple diagnostic'), findsNothing);
        expect(
          find.textContaining('Could not complete Apple'),
          failure == 'invalid-credential' ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'Apple sign-in stays reachable at 320px with large text: $mode',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final _Auth auth = _Auth()..appleEnabled = true;
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(mode),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.35)),
              child: CollectorSignInScreen(auth: auth),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final Finder apple = find.byKey(const Key('auth-apple'));
        await tester.ensureVisible(apple);
        expect(tester.getSize(apple).height, greaterThanOrEqualTo(44));
        await tester.tap(apple);
        await tester.pumpAndSettle();
        expect(auth.appleCalls, 1);
        await tester.pumpWidget(const SizedBox());
        auth.apple.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'filled registration fields keep names and keyboard advances before submit',
    (WidgetTester tester) async {
      final _Auth auth = _Auth();
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await _showSignIn(tester, auth: auth);
        await tester.tap(find.text('Create an account'));
        await tester.pumpAndSettle();
        Finder input(String key) => find
            .descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(EditableText),
            )
            .hitTestable();
        await tester.enterText(input('auth-email'), 'collector@example.test');
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(input('auth-password'))
              .focusNode
              .hasFocus,
          isTrue,
        );
        await tester.enterText(input('auth-password'), 'strong password');
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pumpAndSettle();
        expect(auth.registerCalls, 0);
        expect(find.text('Passwords do not match.'), findsNothing);
        expect(
          tester
              .widget<EditableText>(input('auth-confirmation'))
              .focusNode
              .hasFocus,
          isTrue,
        );
        await tester.enterText(input('auth-confirmation'), 'strong password');
        await tester.pumpAndSettle();
        for (final String label in <String>[
          'Email address',
          'Password',
          'Confirm password',
        ]) {
          final SemanticsNode node = tester.getSemantics(
            find.bySemanticsLabel(label).first,
          );
          expect(node.label, label);
          expect(node.getSemanticsData().flagsCollection.isTextField, isTrue);
          if (label != 'Email address') {
            expect(node.getSemanticsData().flagsCollection.isObscured, isTrue);
            expect(node.value, isNot('strong password'));
          }
        }
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(auth.registerCalls, 1);
        expect(auth.registeredEmail, 'collector@example.test');
        expect(auth.registeredPassword, 'strong password');
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('populated reset email retains its accessible name', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _showSignIn(tester, auth: _Auth());
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(EditableText).hitTestable(),
        'collector@example.test',
      );
      await tester.pumpAndSettle();
      final SemanticsNode node = tester.getSemantics(
        find.bySemanticsLabel('Email address').first,
      );
      expect(node.label, 'Email address');
      expect(node.getSemanticsData().flagsCollection.isTextField, isTrue);
      expect(node.value, 'collector@example.test');
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('small phone forms retain touch targets and reflow large text', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    tester.view.physicalSize = const Size(320, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: CollectorSignInScreen(auth: auth),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PrimaryButton)).height,
      greaterThanOrEqualTo(44),
    );
    await tester.ensureVisible(find.text('Create an account'));
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Create Account'));
    expect(find.byKey(const Key('auth-confirmation')), findsOneWidget);
    expect(
      tester.getSize(find.byType(PrimaryButton)).height,
      greaterThanOrEqualTo(44),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful logout unwinds navigation after auth completes', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              PageRouteBuilder<void>(
                pageBuilder: (
                  BuildContext context,
                  Animation<double> animation,
                  Animation<double> secondaryAnimation,
                ) => HubSettings(auth: auth),
              ),
            ),
            child: const Text('Open settings'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();
    expect(auth.logoutCalls, 1);
    expect(find.byType(ArcaneDialog), findsNothing);
    expect(find.text('Signing out…'), findsOneWidget);
    expect(find.byType(HubSettings), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
    auth.logout.complete();
    await tester.pumpAndSettle();
    expect(find.byType(HubSettings), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logout waits for completion and recovers from a failure', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: HubSettings(auth: auth),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();
    expect(find.byType(ArcaneDialog), findsNothing);
    await tester.tap(find.text('Signing out…'));
    await tester.pumpAndSettle();
    expect(auth.logoutCalls, 1);
    expect(find.text('Signing out…'), findsOneWidget);
    auth.logout.completeError(StateError('Private logout diagnostic'));
    await tester.pumpAndSettle();
    expect(find.text('Sign Out'), findsOneWidget);
    expect(
      find.text('Could not finish signing out. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('Private logout diagnostic'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();
    expect(auth.logoutCalls, 2);
    expect(find.text('Sign Out'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Google cancellation restores the form without an error', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    await _showSignIn(tester, auth: auth);
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(auth.googleCalls, 1);
    expect(
      tester.widget<SecondaryButton>(find.byType(SecondaryButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
      isNull,
    );

    auth.google.completeError(
      const GoogleSignInException(code: GoogleSignInExceptionCode.canceled),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sign In'), findsOneWidget);
    expect(
      tester.widget<SecondaryButton>(find.byType(SecondaryButton)).onPressed,
      isNotNull,
    );
    expect(find.textContaining('Could not'), findsNothing);
  });

  testWidgets('Google failures show safe feedback and allow retry', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    await _showSignIn(tester, auth: auth);
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    auth.google.completeError(
      FirebaseAuthException(
        code: 'network-request-failed',
        message: 'Private provider diagnostic',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Check your connection and try again.'), findsOneWidget);
    expect(find.textContaining('Private provider diagnostic'), findsNothing);
    expect(
      tester.widget<SecondaryButton>(find.byType(SecondaryButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'reset requests disable duplicate actions and conceal account existence',
    (WidgetTester tester) async {
      final _Auth auth = _Auth();
      await _showSignIn(tester, auth: auth);
      await tester.enterText(
        find.byType(EditableText).first,
        'collector@example.test',
      );
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
      expect(find.byType(CollectorPasswordResetScreen), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        'collector@example.test',
      );
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();
      expect(auth.resetCalls, 1);
      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
        isNull,
      );
      auth.reset.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('If an account uses this email, a reset link has been sent.'),
        findsOneWidget,
      );
      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('registration toggle changes the submit action', (
    WidgetTester tester,
  ) async {
    await _showSignIn(tester);
    expect(
      find.descendant(
        of: find.byType(PrimaryButton),
        matching: find.text('Sign In'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(PrimaryButton),
        matching: find.text('Create Account'),
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byType(EditableText).first,
      'collector@example.test',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('auth-password')),
        matching: find.byType(EditableText),
      ),
      'short',
    );
    await tester.tap(find.byType(PrimaryButton));
    await tester.pumpAndSettle();
    expect(
      find.text('Use a password with at least 6 characters.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Sign in instead'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(PrimaryButton),
        matching: find.text('Sign In'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('reset password validates email before accessing Firebase', (
    WidgetTester tester,
  ) async {
    await _showSignIn(tester, size: const Size(1280, 900));
    await tester.tap(find.text('Reset password'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send reset link'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a valid email address to reset your password.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'registration requires matching passwords before creating an account',
    (WidgetTester tester) async {
      final _Auth auth = _Auth();
      await _showSignIn(tester, auth: auth);
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('auth-email')),
          matching: find.byType(EditableText),
        ),
        ' collector@example.test ',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('auth-password')),
          matching: find.byType(EditableText),
        ),
        'strong password',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('auth-confirmation')),
          matching: find.byType(EditableText),
        ),
        'different password',
      );
      await tester.ensureVisible(find.byType(PrimaryButton));
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      expect(auth.registerCalls, 0);
      expect(find.text('Passwords do not match.'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('auth-confirmation')),
          matching: find.byType(EditableText),
        ),
        'strong password',
      );
      await tester.ensureVisible(find.byType(PrimaryButton));
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      expect(auth.registerCalls, 1);
      expect(auth.registeredEmail, 'collector@example.test');
      expect(auth.registeredPassword, 'strong password');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sign in validates email and password before accessing Firebase',
    (WidgetTester tester) async {
      await _showSignIn(tester);
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);

      await tester.enterText(
        find.byType(EditableText).first,
        'collector@example.test',
      );
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();
      expect(find.text('Enter your password.'), findsOneWidget);
    },
  );
}
