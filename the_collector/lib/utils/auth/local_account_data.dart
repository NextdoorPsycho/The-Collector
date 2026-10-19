import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalAccountData {
  static const String _markerBox = 'account_deletions_v1';
  static final ValueNotifier<Set<String>> _deleting =
      ValueNotifier<Set<String>>(const <String>{});
  static ValueListenable<Set<String>> get deletingUids => _deleting;
  static final Set<String> _accepted = <String>{};
  static final Set<String> _cleaned = <String>{};
  static final Map<String, Set<Future<void>>> _operations =
      <String, Set<Future<void>>>{};
  static final Map<String, Future<void>> _purges = <String, Future<void>>{};
  static Future<Box<String>>? _opening;
  static Future<void> _markers = Future<void>.value();

  static Future<Box<String>> _box() {
    if (Hive.isBoxOpen(_markerBox)) {
      return Future<Box<String>>.value(Hive.box<String>(_markerBox));
    }
    return _opening ??= Hive.openBox<String>(_markerBox)
        .whenComplete(() => _opening = null);
  }

  static Future<void> initialize() async {
    final Box<String> box = await _box();
    _accepted.clear();
    _cleaned.clear();
    final Set<String> owners = <String>{};
    for (final String uid in box.keys.cast<String>()) {
      final String state = box.get(uid)!;
      if (state != 'pending' && state != 'accepted' && state != 'cleaned') {
        throw const FormatException('Invalid local account deletion state.');
      }
      owners.add(uid);
      if (state == 'accepted' || state == 'cleaned') _accepted.add(uid);
      if (state == 'cleaned') _cleaned.add(uid);
    }
    _deleting.value = Set<String>.unmodifiable(owners);
  }

  static void _validate(String uid) {
    if (uid.isEmpty || uid.contains('/')) throw ArgumentError.value(uid, 'uid');
  }

  static bool isDeleting(String uid) => _deleting.value.contains(uid);

  static bool isDeletionAccepted(String uid) => _accepted.contains(uid);

  static bool needsDeletionCleanup(String uid) =>
      _accepted.contains(uid) && !_cleaned.contains(uid);

  static Future<void> acceptDeletion(String uid) => _serializeMarker(() async {
    _validate(uid);
    if (!isDeleting(uid)) {
      throw StateError('Mark account deletion before accepting it.');
    }
    final Box<String> box = await _box();
    await box.put(uid, _cleaned.contains(uid) ? 'cleaned' : 'accepted');
    await box.flush();
    _accepted.add(uid);
    _deleting.value = Set<String>.unmodifiable(_deleting.value);
  });

  static Future<void> finishDeletionCleanup(String uid) =>
      _serializeMarker(() async {
        _validate(uid);
        if (!_accepted.contains(uid)) {
          throw StateError('Account deletion has not been accepted.');
        }
        if (_purges.containsKey(uid)) {
          throw StateError('Wait for local account cleanup to finish.');
        }
        final Box<String> box = await _box();
        await box.put(uid, 'cleaned');
        await box.flush();
        _cleaned.add(uid);
        _deleting.value = Set<String>.unmodifiable(_deleting.value);
      });

  static void requireWritable(String uid) {
    _validate(uid);
    if (isDeleting(uid)) throw StateError('This account is being deleted.');
  }

  static Future<void> _serializeMarker(Future<void> Function() action) {
    final Future<void> next = _markers.then((_) => action());
    _markers = next.catchError((Object _) {});
    return next;
  }

  static Future<void> markDeleting(String uid) {
    _validate(uid);
    _deleting.value = Set<String>.unmodifiable(<String>{
      ..._deleting.value,
      uid,
    });
    return _serializeMarker(() async {
      final Box<String> box = await _box();
      await box.put(
        uid,
        _cleaned.contains(uid)
            ? 'cleaned'
            : _accepted.contains(uid)
            ? 'accepted'
            : 'pending',
      );
      await box.flush();
    });
  }

  static Future<void> cancelDeleting(String uid) => _serializeMarker(() async {
    _validate(uid);
    if (_accepted.contains(uid) || _purges.containsKey(uid)) {
      throw StateError('Accepted account deletion cannot be cancelled.');
    }
    final Box<String> box = await _box();
    await box.delete(uid);
    await box.flush();
    _deleting.value = Set<String>.unmodifiable(
      <String>{..._deleting.value}..remove(uid),
    );
  });

  /// A purge waits for work admitted before the deletion gate closed.
  static Future<T> mutate<T>(String uid, Future<T> Function() action) {
    requireWritable(uid);
    final Completer<void> finished = Completer<void>();
    final Set<Future<void>> work = _operations.putIfAbsent(
      uid,
      () => <Future<void>>{},
    );
    work.add(finished.future);
    return Future<T>.sync(() {
      requireWritable(uid);
      return action();
    }).whenComplete(() {
      work.remove(finished.future);
      if (work.isEmpty) _operations.remove(uid);
      finished.complete();
    });
  }

  static Future<void> purge(String uid) {
    _validate(uid);
    if (!isDeleting(uid)) {
      throw StateError('Mark account deletion before purging.');
    }
    return _purges.putIfAbsent(
      uid,
      () => _purge(uid).whenComplete(() {
        _purges.remove(uid);
      }),
    );
  }

  static Future<void> _purge(String uid) async {
    await acceptDeletion(uid);
    while (_operations[uid]?.isNotEmpty ?? false) {
      await Future.wait<void>(List<Future<void>>.of(_operations[uid]!));
    }
    final String owner = sha256.convert(utf8.encode(uid)).toString();
    final String? markerPath = (await _box()).path;
    for (final String name in <String>[
      'scanner_queue_v2_$owner',
      'scanner_drafts_v1_$owner',
    ]) {
      await Hive.deleteBoxFromDisk(name);
    }
    if (!kIsWeb && markerPath != null) {
      final Directory images = Directory(
        '${File(markerPath).parent.path}/scanner_images_$owner',
      );
      if (await images.exists()) await images.delete(recursive: true);
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String cloudConsentKey = 'scan.cloudConsent.$uid';
    if (preferences.containsKey(cloudConsentKey) &&
        !await preferences.remove(cloudConsentKey)) {
      throw StateError('Could not remove cloud recognition preference.');
    }
    final RegExp gameKey = RegExp(
      '^game\\.${RegExp.escape(uid)}\\.(standard|commander)\\.[2-8]\$',
    );
    for (final String key
        in preferences.getKeys().where(gameKey.hasMatch).toList()) {
      if (!await preferences.remove(key)) {
        throw StateError('Could not remove the saved game.');
      }
    }
  }
}
