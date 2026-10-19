import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/user/app_user_restricted.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/pages/admin/admin_users.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);
  late FakeFirebaseFirestore database;
  late CollectionStore<AppUser> users;
  final List<String> permissionReads = <String>[];
  final List<AppUser> fixtureUsers = <AppUser>[];
  final List<(String, int, String?)> pageRequests = <(String, int, String?)>[];

  CollectionStore<AppUserRestricted> permissions(String uid) {
    permissionReads.add(uid);
    return CollectionStore<AppUserRestricted>(
      collection: database.collection('user').doc(uid).collection('restricted'),
      toMap: (AppUserRestricted data) => data.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          AppUserRestrictedMapper.fromMap(data)..id = id,
    );
  }

  setUp(() async {
    database = FakeFirebaseFirestore();
    permissionReads.clear();
    fixtureUsers.clear();
    pageRequests.clear();
    users = CollectionStore<AppUser>(
      collection: database.collection('user'),
      toMap: (AppUser data) => data.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          AppUserMapper.fromMap(data)..id = id,
    );
    for (int index = 0; index < 75; index++) {
      final String uid = 'user-${index.toString().padLeft(3, '0')}';
      await users.set(uid, AppUser());
      fixtureUsers.add(AppUser()..id = uid);
      await permissions(uid).set('perms', AppUserRestricted(admin: index == 0));
    }
    permissionReads.clear();
  });

  Future<void> show(WidgetTester tester, {bool allowed = true}) async {
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: Provider<AppUserRestricted?>.value(
          value: AppUserRestricted(admin: allowed),
          child: AdminUsers(
            loadUsers:
                ({
                  required String prefix,
                  required int limit,
                  String? after,
                }) async {
                  pageRequests.add((prefix, limit, after));
                  return fixtureUsers
                      .where(
                        (AppUser user) =>
                            user.id!.startsWith(prefix) &&
                            (after == null || user.id!.compareTo(after) > 0),
                      )
                      .take(limit)
                      .toList();
                },
            permissionStore: permissions,
            currentUserId: 'user-000',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('admin pages user IDs and loads permissions only on selection', (
    WidgetTester tester,
  ) async {
    await show(tester);
    expect(permissionReads, isEmpty);
    expect(pageRequests, <(String, int, String?)>[('', 51, null)]);
    expect(find.text('1–50'), findsOneWidget);
    await tester.tap(find.text('Next page'));
    await tester.pumpAndSettle();
    expect(find.text('51–75'), findsOneWidget);
    expect(pageRequests.last, ('', 51, 'user-049'));
    expect(find.text('user-050').hitTestable(), findsOneWidget);
    await tester.tap(find.text('user-050'));
    await tester.pumpAndSettle();
    expect(permissionReads, <String>['user-050']);
    expect(find.text('Administrator access'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
  });

  testWidgets(
    'own permission stays read only and denied viewers load no users',
    (WidgetTester tester) async {
      await show(tester, allowed: false);
      expect(find.text('Administrator access is required.'), findsOneWidget);
      expect(permissionReads, isEmpty);
      expect(pageRequests, isEmpty);
      await show(tester);
      await tester.tap(find.text('user-000'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.text('Your account'), findsOneWidget);
    },
  );

  testWidgets(
    'admin prefix search resets paging and permission grants require confirmation',
    (WidgetTester tester) async {
      await show(tester);
      await tester.enterText(find.byType(EditableText), 'user-06');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('1–10'), findsOneWidget);
      expect(pageRequests.last, ('user-06', 51, null));
      await tester.tap(find.text('user-060'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        find.text('Grant administrator access?').hitTestable(),
        findsOneWidget,
      );
      expect((await permissions('user-060').get('perms')).admin, isFalse);
      await tester.tap(find.text('Grant access'));
      await tester.pumpAndSettle();
      expect((await permissions('user-060').get('perms')).admin, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
