import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:the_collector/utils/scanning/cloud_scan_consent.dart';

class _BlockedPreferences extends InMemorySharedPreferencesStore {
  _BlockedPreferences({this.fail = false}) : super.empty();
  final bool fail;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (++writes == 1) {
      started.complete();
      await release.future;
    }
    if (fail) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previous;
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    previous = SharedPreferencesStorePlatform.instance;
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = previous);

  test('consent defaults off, saves per user, and leases invalidate on account changes', () async {
    String? owner = 'alice';
    final StreamController<String?> accounts =
        StreamController<String?>.broadcast(sync: true);
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => owner,
      accountChanges: accounts.stream,
    );
    addTearDown(() async {
      store.dispose();
      await accounts.close();
    });
    expect(await store.acquire('alice'), isNull);
    await store.setGranted('alice', true);
    final CloudScanPermission first = (await store.acquire('alice'))!;
    expect(first.isValid, isTrue);
    expect(await store.acquire('alice'), same(first));
    owner = 'bob';
    accounts.add(owner);
    expect(first.isValid, isFalse);
    expect(await store.acquire('alice'), isNull);
    expect(await store.acquire('bob'), isNull);
    owner = 'alice';
    accounts.add(owner);
    expect(first.isValid, isFalse);
    expect((await store.acquire('alice'))!.isValid, isTrue);
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(CloudScanConsentStore.preferenceKey('alice')),
      isTrue,
    );
    expect(
      preferences.getBool(CloudScanConsentStore.preferenceKey('bob')),
      isNull,
    );
    final CloudScanConsentStore reopened = CloudScanConsentStore(
      currentUserId: () => owner,
    );
    addTearDown(reopened.dispose);
    expect(await reopened.isGranted('alice'), isTrue);
  });

  test('pending preference load cannot authorize after sign-out', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'scan.cloudConsent.alice': true,
    });
    String? owner = 'alice';
    final Completer<SharedPreferences> loading = Completer<SharedPreferences>();
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => owner,
      preferences: () => loading.future,
    );
    addTearDown(store.dispose);
    final Future<CloudScanPermission?> pending = store.acquire('alice');
    owner = null;
    loading.complete(await SharedPreferences.getInstance());
    expect(await pending, isNull);
  });

  test(
    'initial auth snapshot cannot reopen a pending sign-out suspension',
    () async {
      final StreamController<String?> accounts =
          StreamController<String?>.broadcast(sync: true);
      final CloudScanConsentStore store = CloudScanConsentStore(
        currentUserId: () => 'alice',
        accountChanges: accounts.stream,
      );
      addTearDown(() async {
        store.dispose();
        await accounts.close();
      });
      await store.setGranted('alice', true);
      store.suspend('alice');
      accounts.add('alice');
      expect(await store.acquire('alice'), isNull);
      store.resume('alice');
      expect((await store.acquire('alice'))!.isValid, isTrue);
    },
  );

  test('load failure never grants cloud access', () async {
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => 'alice',
      preferences: () async => throw StateError('Unavailable preferences'),
    );
    addTearDown(store.dispose);
    expect(await store.acquire('alice'), isNull);
    expect(await store.isGranted('alice'), isFalse);
  });

  test('revoke and regrant cannot revive a pending lease', () async {
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => 'alice',
    );
    addTearDown(store.dispose);
    await store.setGranted('alice', true);
    final CloudScanPermission first = (await store.acquire('alice'))!;
    final Future<void> revoking = store.setGranted('alice', false);
    expect(first.isValid, isFalse);
    expect(await store.acquire('alice'), isNull);
    await revoking;
    await store.setGranted('alice', true);
    expect(first.isValid, isFalse);
    final CloudScanPermission second = (await store.acquire('alice'))!;
    store.suspend('alice');
    expect(second.isValid, isFalse);
    expect(await store.acquire('alice'), isNull);
    store.resume('alice');
    expect(second.isValid, isFalse);
    expect((await store.acquire('alice'))!.isValid, isTrue);
  });

  test(
    'a later revoke stays closed while an earlier consent save is pending',
    () async {
      final _BlockedPreferences platform = _BlockedPreferences();
      SharedPreferencesStorePlatform.instance = platform;
      final CloudScanConsentStore store = CloudScanConsentStore(
        currentUserId: () => 'alice',
      );
      addTearDown(store.dispose);
      final Future<void> enabling = store.setGranted('alice', true);
      await platform.started.future;
      final Future<void> disabling = store.setGranted('alice', false);
      expect(await store.acquire('alice'), isNull);
      platform.release.complete();
      await Future.wait<void>(<Future<void>>[enabling, disabling]);
      expect(await store.isGranted('alice'), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'scan.cloudConsent.alice',
        ),
        isFalse,
      );
    },
  );

  test('failed persistence and disposal remain closed', () async {
    final _BlockedPreferences platform = _BlockedPreferences(fail: true);
    SharedPreferencesStorePlatform.instance = platform;
    final CloudScanConsentStore store = CloudScanConsentStore(
      currentUserId: () => 'alice',
    );
    final Future<void> saving = store.setGranted('alice', true);
    final Future<void> failure = expectLater(saving, throwsStateError);
    await platform.started.future;
    expect(await store.acquire('alice'), isNull);
    platform.release.complete();
    await failure;
    expect(await store.acquire('alice'), isNull);
    store.dispose();
    expect(await store.acquire('alice'), isNull);
  });
}
