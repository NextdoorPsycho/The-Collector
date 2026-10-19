import 'dart:convert';

import 'package:arcane/arcane.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:the_collector/main.dart' as app;
import 'package:the_collector/utils/auth/local_account_data.dart';
import 'package:the_collector/utils/auth/account_deletion.dart';
import 'package:the_collector/utils/firebase_environment.dart';

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 55));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  expect(tester.takeException(), isNull);
}

Future<void> waitForCloudDeletion(
  WidgetTester tester,
  String uid,
  String token,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  final Uri uri = Uri.http(
    '127.0.0.1:18080',
    '/v1/projects/demo-the-collector/databases/(default)/documents/accountDeletions/$uid',
  );
  while (DateTime.now().isBefore(deadline)) {
    final http.Response response = await http
        .get(uri, headers: <String, String>{'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 5));
    expect(response.statusCode, 200);
    final Map<String, Object?> document =
        jsonDecode(response.body) as Map<String, Object?>;
    final Map<String, Object?> fields =
        document['fields']! as Map<String, Object?>;
    final Map<String, Object?> state = fields['state']! as Map<String, Object?>;
    if (state['stringValue'] == 'complete') return;
    await tester.pump(const Duration(milliseconds: 250));
  }
  fail('The actual callable-triggered deletion worker did not complete.');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('verified deletion cleans account and supports another login', (
    WidgetTester tester,
  ) async {
    expect(const bool.fromEnvironment('USE_FIREBASE_EMULATORS'), isTrue);
    await initializeCollectorFirebase();
    final FirebaseAuth auth = FirebaseAuth.instance;
    if (auth.currentUser != null) {
      expect(
        auth.currentUser!.isAnonymous ||
            (auth.currentUser!.email?.startsWith('deletion-') == true &&
                auth.currentUser!.email?.endsWith('@example.test') == true),
        isTrue,
        reason: 'Only discard local emulator fixture logins.',
      );
      await auth.signOut();
    }
    const String password = 'FixturePassword123!';
    final String email =
        'deletion-${DateTime.now().microsecondsSinceEpoch}@example.test';
    final User owner = (await auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    )).user!;
    final String uid = owner.uid;
    final String token = (await owner.getIdToken())!;
    await FirebaseFirestore.instance.doc('user/$uid').set(<String, Object>{
      'theme': true,
      'showCommander': false,
    });
    await app.main();
    await waitFor(
      tester,
      find.widgetWithText(IconTab, 'Settings').hitTestable(),
    );
    await tester.tap(find.widgetWithText(IconTab, 'Settings').hitTestable());
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(tester, find.text('Privacy & data').hitTestable());
    await tester.tap(find.text('Privacy & data').hitTestable());
    await waitFor(tester, find.text('Camera and recognition'));
    if (const bool.fromEnvironment('DELETION_UI_SCREENSHOTS')) {
      await tester.pump(const Duration(milliseconds: 700));
      debugPrint('DELETION_UI_READY:privacy');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    await tester.tap(find.byIcon(Icons.arrow_left).hitTestable());
    await tester.pump(const Duration(milliseconds: 300));
    await waitFor(tester, find.text('Delete account').hitTestable());
    await tester.ensureVisible(find.text('Delete account').hitTestable());
    await tester.tap(find.text('Delete account').hitTestable());
    await waitFor(
      tester,
      find.byKey(const Key('deletion-password')).hitTestable(),
    );
    if (const bool.fromEnvironment('DELETION_UI_SCREENSHOTS')) {
      await tester.pump(const Duration(milliseconds: 700));
      debugPrint('DELETION_UI_READY:confirmation');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    await tester.enterText(
      find.byKey(const Key('deletion-password')).hitTestable(),
      password,
    );
    await tester.tap(
      find.byKey(const Key('confirm-account-deletion')).hitTestable(),
    );
    await waitFor(tester, find.byKey(const Key('auth-email')));
    expect(auth.currentUser, isNull);
    expect(LocalAccountData.isDeletionAccepted(uid), isTrue);
    expect(LocalAccountData.needsDeletionCleanup(uid), isFalse);
    expect(tester.takeException(), isNull);
    await waitForCloudDeletion(tester, uid, token);
    final User next = (await auth.signInAnonymously()).user!;
    await waitFor(
      tester,
      find.widgetWithText(IconTab, 'Collection').hitTestable(),
    );
    final DocumentSnapshot<Map<String, dynamic>> profile =
        await FirebaseFirestore.instance
            .doc('user/${next.uid}')
            .get(const GetOptions(source: Source.server));
    expect(
      profile.exists,
      isTrue,
      reason: 'Firestore must restart at the emulator after cache clearing.',
    );
    expect(next.uid, isNot(uid));
    await FirebaseFirestore.instance.disableNetwork();
    try {
      expect(
        await prepareAccount(next.uid),
        isTrue,
        reason: 'Known cached accounts remain usable offline.',
      );
      await LocalAccountData.markDeleting(next.uid);
      await expectLater(
        prepareAccount(next.uid),
        throwsA(isA<FirebaseException>()),
      );
      expect(LocalAccountData.isDeleting(next.uid), isTrue);
      await LocalAccountData.cancelDeleting(next.uid);
    } finally {
      await FirebaseFirestore.instance.enableNetwork();
    }
    await auth.signOut();
    await waitFor(tester, find.byKey(const Key('auth-email')));
    expect(tester.takeException(), isNull);
  });
}
