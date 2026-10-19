import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/local_account_data.dart';

const bool cloudCardHintsEnabled = bool.fromEnvironment(
  'CLOUD_CARD_HINTS_ENABLED',
);

abstract interface class CloudScanPermission {
  bool get isValid;
}

class CloudScanConsentStore {
  CloudScanConsentStore({
    required this.currentUserId,
    Future<SharedPreferences> Function()? preferences,
    Stream<String?>? accountChanges,
  }) : _preferences = preferences ?? SharedPreferences.getInstance {
    _lastUserId = currentUserId();
    _accounts = accountChanges?.listen((String? userId) {
      if (userId == _lastUserId) return;
      _lastUserId = userId;
      _authRevision++;
      _leases.clear();
      _suspended.clear();
    });
  }

  static final CloudScanConsentStore instance = CloudScanConsentStore(
    currentUserId: () => FirebaseAuth.instance.currentUser?.uid,
    accountChanges: FirebaseAuth.instance.authStateChanges().map(
      (User? user) => user?.uid,
    ),
  );

  final String? Function() currentUserId;
  final Future<SharedPreferences> Function() _preferences;
  final Map<String, bool> _granted = <String, bool>{};
  final Map<String, int> _revisions = <String, int>{};
  final Map<String, Future<void>> _loading = <String, Future<void>>{};
  final Map<String, CloudScanConsentLease> _leases =
      <String, CloudScanConsentLease>{};
  final Set<String> _suspended = <String>{};
  StreamSubscription<String?>? _accounts;
  String? _lastUserId;
  Future<void> _mutations = Future<void>.value();
  int _authRevision = 0;
  bool _disposed = false;

  static String preferenceKey(String uid) {
    if (uid.isEmpty || uid.contains('/')) throw ArgumentError.value(uid, 'uid');
    return 'scan.cloudConsent.$uid';
  }

  bool _owns(String uid) =>
      !_disposed &&
      !_suspended.contains(uid) &&
      currentUserId() == uid &&
      !LocalAccountData.isDeleting(uid);

  void suspend(String uid) {
    preferenceKey(uid);
    _suspended.add(uid);
    _revisions[uid] = (_revisions[uid] ?? 0) + 1;
    _leases.remove(uid);
  }

  void resume(String uid) => _suspended.remove(uid);

  Future<void> _load(String uid) {
    preferenceKey(uid);
    if (_granted.containsKey(uid)) return Future<void>.value();
    return _loading
        .putIfAbsent(uid, () async {
          final int revision = _revisions[uid] ?? 0;
          try {
            final SharedPreferences preferences = await _preferences();
            if (!_disposed && revision == (_revisions[uid] ?? 0)) {
              _granted[uid] = preferences.getBool(preferenceKey(uid)) == true;
            }
          } catch (_) {
            if (revision == (_revisions[uid] ?? 0)) _granted[uid] = false;
          }
        })
        .whenComplete(() => _loading.remove(uid));
  }

  Future<bool> isGranted(String uid) async {
    if (!_owns(uid)) return false;
    await _load(uid);
    return _owns(uid) && _granted[uid] == true;
  }

  Future<CloudScanPermission?> acquire(String uid) async {
    if (!await isGranted(uid)) return null;
    final CloudScanConsentLease lease = _leases.putIfAbsent(
      uid,
      () => CloudScanConsentLease._(
        this,
        uid,
        _revisions[uid] ?? 0,
        _authRevision,
      ),
    );
    return lease.isValid ? lease : null;
  }

  Future<void> setGranted(String uid, bool value) {
    preferenceKey(uid);
    final int revision = (_revisions[uid] ?? 0) + 1;
    _revisions[uid] = revision;
    _granted[uid] = false;
    _leases.remove(uid);
    final Future<void> next = _mutations.then((_) async {
      if (!_owns(uid)) throw StateError('Account changed.');
      await LocalAccountData.mutate(uid, () async {
        final SharedPreferences preferences = await _preferences();
        if (!_owns(uid)) throw StateError('Account changed.');
        if (!await preferences.setBool(preferenceKey(uid), value)) {
          throw StateError('Could not save cloud recognition preference.');
        }
      });
      if (!_owns(uid)) throw StateError('Account changed.');
      if (revision == _revisions[uid]) _granted[uid] = value;
    });
    _mutations = next.catchError((Object _) {});
    return next;
  }

  void dispose() {
    _disposed = true;
    _authRevision++;
    _leases.clear();
    unawaited(_accounts?.cancel());
  }
}

class CloudScanConsentLease implements CloudScanPermission {
  const CloudScanConsentLease._(
    this._store,
    this._uid,
    this._revision,
    this._authRevision,
  );
  final CloudScanConsentStore _store;
  final String _uid;
  final int _revision;
  final int _authRevision;

  @override
  bool get isValid =>
      _store._owns(_uid) &&
      _store._granted[_uid] == true &&
      (_store._revisions[_uid] ?? 0) == _revision &&
      _store._authRevision == _authRevision;
}
