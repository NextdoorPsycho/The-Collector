import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:the_collector/pages/account/account_deletion_dialog.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

import 'helpers/load_collector_fonts.dart';

class _Auth extends Fake implements CollectorAuth {
  @override
  bool deletionRequiresPassword = true;
  int calls = 0;
  String? password;
  Object? error;
  Completer<void>? pending;
  DeletionVerification verification = DeletionVerification.verified;
  @override
  Future<DeletionVerification> reauthenticateForDeletion({
    String? password,
  }) async {
    calls++;
    this.password = password;
    if (error != null) throw error!;
    await pending?.future;
    return verification;
  }
}

Future<void> _show(
  WidgetTester tester,
  _Auth auth,
  Future<void> Function() delete, {
  ThemeMode mode = ThemeMode.light,
  double scale = 1,
  double keyboardInset = 0,
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
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          child: Center(
            child: SecondaryButton(
              onPressed: () => showAccountDeletionDialog(
                context,
                auth: auth,
                requestDeletion: delete,
              ),
              child: const Text('Account settings'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Account settings'));
  await tester.pumpAndSettle();
}

Finder get _password => find
    .descendant(
      of: find.byKey(const Key('deletion-password')),
      matching: find.byType(EditableText),
    )
    .hitTestable();

Future<void> _confirm(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('confirm-account-deletion')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete my account').hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets('password Done only focuses the explicit deletion confirmation', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    int deletes = 0;
    await _show(tester, auth, () async {
      deletes++;
    });
    await tester.ensureVisible(find.byKey(const Key('deletion-password')));
    await tester.enterText(_password, 'current password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(auth.calls, 0);
    expect(deletes, 0);
    expect(
      tester
          .widget<PrimaryButton>(
            find.byKey(const Key('confirm-account-deletion')),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(auth.calls, 1);
    expect(deletes, 1);
  });

  testWidgets('Cancel performs neither verification nor deletion', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth();
    int deletes = 0;
    await _show(tester, auth, () async {
      deletes++;
    });
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel').hitTestable());
    await tester.pumpAndSettle();
    expect(auth.calls, 0);
    expect(deletes, 0);
    expect(find.byType(AccountDeletionDialog), findsNothing);
  });

  testWidgets('empty and wrong password cannot delete; a corrected retry can', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth()
      ..error = FirebaseAuthException(code: 'wrong-password');
    int deletes = 0;
    await _show(tester, auth, () async {
      deletes++;
    });
    await _confirm(tester);
    expect(auth.calls, 0);
    expect(deletes, 0);
    expect(
      find.text('Enter your password to verify this account.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('deletion-password')));
    await tester.enterText(_password, 'wrong password');
    await _confirm(tester);
    expect(deletes, 0);
    expect(find.text('The email or password is incorrect.'), findsOneWidget);
    expect(find.byType(AccountDeletionDialog), findsOneWidget);
    auth.error = null;
    await tester.ensureVisible(find.byKey(const Key('deletion-password')));
    await tester.enterText(_password, 'correct password');
    await _confirm(tester);
    expect(auth.calls, 2);
    expect(auth.password, 'correct password');
    expect(deletes, 1);
    expect(find.byType(AccountDeletionDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider cancellation keeps account and dialog intact', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth()
      ..deletionRequiresPassword = false
      ..error = const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
      );
    int deletes = 0;
    await _show(tester, auth, () async {
      deletes++;
    });
    expect(find.byType(EditableText), findsNothing);
    await _confirm(tester);
    expect(deletes, 0);
    expect(
      find.text('Verification canceled. Your account has not been deleted.'),
      findsOneWidget,
    );
    expect(find.byType(AccountDeletionDialog), findsOneWidget);
  });

  testWidgets(
    'busy blocks duplicate confirmation, cancel and back until deletion completes',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()
        ..deletionRequiresPassword = false
        ..pending = Completer<void>();
      final Completer<void> deleting = Completer<void>();
      int deletes = 0;
      await _show(tester, auth, () {
        deletes++;
        return deleting.future;
      });
      await _confirm(tester);
      await _confirm(tester);
      expect(auth.calls, 1);
      await tester.tap(find.text('Cancel').hitTestable());
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AccountDeletionDialog), findsOneWidget);
      expect(deletes, 0);
      auth.pending!.complete();
      await tester.pumpAndSettle();
      expect(deletes, 1);
      expect(find.text('Deleting account…'), findsOneWidget);
      await _confirm(tester);
      expect(deletes, 1);
      deleting.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AccountDeletionDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deletion failure stays visible and retries after fresh verification',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()..deletionRequiresPassword = false;
      int deletes = 0;
      await _show(tester, auth, () async {
        deletes++;
        if (deletes == 1) throw StateError('private backend detail');
      });
      await _confirm(tester);
      expect(
        find.text(
          'Could not delete your account. Check your connection and retry.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private backend'), findsNothing);
      expect(find.byType(AccountDeletionDialog), findsOneWidget);
      await _confirm(tester);
      expect(auth.calls, 2);
      expect(deletes, 2);
      expect(find.byType(AccountDeletionDialog), findsNothing);
    },
  );

  testWidgets(
    'disposed dialog does not call deletion after pending verification',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()
        ..deletionRequiresPassword = false
        ..pending = Completer<void>();
      int deletes = 0;
      await _show(tester, auth, () async {
        deletes++;
      });
      await _confirm(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      auth.pending!.complete();
      await tester.pumpAndSettle();
      expect(deletes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual Apple instructions require a second confirmation and Cancel preserves the account',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()
        ..verification = DeletionVerification.manualAppleRevocation;
      int deletes = 0;
      await _show(tester, auth, () async {
        deletes++;
      });
      await tester.ensureVisible(find.byKey(const Key('deletion-password')));
      await tester.enterText(_password, 'current password');
      await _confirm(tester);
      expect(auth.calls, 1);
      expect(deletes, 0);
      expect(find.byKey(const Key('deletion-password')), findsNothing);
      expect(find.textContaining('Apple access may remain'), findsOneWidget);
      expect(
        find.textContaining('your Apple Account, then Sign in with Apple'),
        findsOneWidget,
      );
      expect(find.text('Continue with deletion'), findsOneWidget);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel').hitTestable());
      await tester.pumpAndSettle();
      expect(deletes, 0);
      expect(find.byType(AccountDeletionDialog), findsNothing);
    },
  );

  testWidgets(
    'manual Apple final confirmation deletes once without requesting the cleared password',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()
        ..verification = DeletionVerification.manualAppleRevocation;
      final Completer<void> pending = Completer<void>();
      int deletes = 0;
      await _show(tester, auth, () {
        deletes++;
        return pending.future;
      });
      await tester.ensureVisible(find.byKey(const Key('deletion-password')));
      await tester.enterText(_password, 'current password');
      await _confirm(tester);
      await tester.ensureVisible(find.text('Continue with deletion'));
      await tester.tap(find.text('Continue with deletion').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with deletion').hitTestable());
      await tester.pumpAndSettle();
      expect(auth.calls, 1);
      expect(deletes, 1);
      expect(
        find.text('Enter your password to verify this account.'),
        findsNothing,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AccountDeletionDialog), findsNothing);
    },
  );

  testWidgets('manual revocation retry verifies again before deletion', (
    WidgetTester tester,
  ) async {
    final _Auth auth = _Auth()
      ..verification = DeletionVerification.manualAppleRevocation;
    int deletes = 0;
    await _show(tester, auth, () async {
      deletes++;
    });
    await tester.ensureVisible(find.byKey(const Key('deletion-password')));
    await tester.enterText(_password, 'current password');
    await _confirm(tester);
    await tester.ensureVisible(find.text('Try verification again'));
    await tester.tap(find.text('Try verification again').hitTestable());
    await tester.pumpAndSettle();
    expect(deletes, 0);
    expect(find.text('Continue with deletion'), findsNothing);
    auth.verification = DeletionVerification.verified;
    await tester.ensureVisible(find.byKey(const Key('deletion-password')));
    await tester.enterText(_password, 'current password');
    await _confirm(tester);
    expect(auth.calls, 2);
    expect(deletes, 1);
  });

  testWidgets(
    'captured-account request guard rejects account changes during manual confirmation',
    (WidgetTester tester) async {
      final _Auth auth = _Auth()
        ..deletionRequiresPassword = false
        ..verification = DeletionVerification.manualAppleRevocation;
      bool sameAccount = true;
      int deletes = 0;
      await _show(tester, auth, () async {
        if (!sameAccount) throw FirebaseAuthException(code: 'user-mismatch');
        deletes++;
      });
      await _confirm(tester);
      sameAccount = false;
      await tester.ensureVisible(find.text('Continue with deletion'));
      await tester.tap(find.text('Continue with deletion').hitTestable());
      await tester.pumpAndSettle();
      expect(deletes, 0);
      expect(find.text('Continue with deletion'), findsNothing);
      expect(
        find.text(
          'Could not delete your account. Check your connection and retry.',
        ),
        findsOneWidget,
      );
      expect(find.byType(AccountDeletionDialog), findsOneWidget);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double keyboardInset in <double>[0, 240]) {
      testWidgets(
        'manual Apple instructions and actions fit 320px AX large ${mode.name}, keyboard=$keyboardInset',
        (WidgetTester tester) async {
          final _Auth auth = _Auth()
            ..deletionRequiresPassword = false
            ..verification = DeletionVerification.manualAppleRevocation;
          int deletes = 0;
          await _show(
            tester,
            auth,
            () async {
              deletes++;
            },
            mode: mode,
            scale: 2.35,
            keyboardInset: keyboardInset,
          );
          await _confirm(tester);
          expect(deletes, 0);
          expect(
            find.textContaining('Apple access may remain'),
            findsOneWidget,
          );
          for (final String label in <String>[
            'Cancel',
            'Try verification again',
            'Continue with deletion',
          ]) {
            final Finder action = find.text(label);
            await tester.ensureVisible(action);
            await tester.pumpAndSettle();
            expect(action.hitTestable(), findsOneWidget);
            final Rect bounds = tester.getRect(action);
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(320));
            expect(bounds.bottom, lessThanOrEqualTo(568));
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'deletion copy, password and actions fit 320px AX large ${mode.name}',
      (WidgetTester tester) async {
        final _Auth auth = _Auth();
        await _show(tester, auth, () async {}, mode: mode, scale: 2.35);
        expect(find.textContaining('cloud history'), findsOneWidget);
        final Finder password = find.byKey(const Key('deletion-password'));
        await tester.ensureVisible(password);
        await tester.pumpAndSettle();
        await tester.enterText(_password, 'secret password');
        final EditableText editable = tester.widget<EditableText>(_password);
        expect(editable.obscureText, isTrue);
        for (final String label in <String>['Cancel', 'Delete my account']) {
          final Finder action = find.text(label);
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          final Rect bounds = tester.getRect(action);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(320));
          expect(bounds.bottom, lessThanOrEqualTo(568));
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
