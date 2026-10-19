import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/cloud_card_hints_service.dart';

Map<String, Object?> _status(bool configured) => <String, Object?>{
  'configured': configured,
  'mode': 'text-transcription',
  'model': configured ? 'configured-model' : null,
};

void main() {
  test(
    'disabled service never contacts Firebase or advertises availability',
    () async {
      int calls = 0;
      final CloudCardHintsService service = CloudCardHintsService(
        enabled: false,
        statusCallable: () async {
          calls++;
          return _status(true);
        },
        callable: (String _) async {
          calls++;
          return null;
        },
      );
      addTearDown(service.dispose);
      expect(
        (await service.checkAvailability(force: true)).availability,
        CloudCardHintsAvailability.disabled,
      );
      await expectLater(
        service.suggest('image', isAuthorized: () => true),
        throwsA(isA<CloudCardHintsException>()),
      );
      expect(service.status.value.canEnable, isFalse);
      expect(calls, 0);
    },
  );

  test('status remains unverified until an authenticated configured response; concurrent checks share one request', () async {
    int checks = 0;
    final Completer<Object?> response = Completer<Object?>();
    final CloudCardHintsService service = CloudCardHintsService(
      enabled: true,
      statusCallable: () {
        checks++;
        return response.future;
      },
    );
    addTearDown(service.dispose);
    expect(
      service.status.value.availability,
      CloudCardHintsAvailability.unchecked,
    );
    expect(service.status.value.canEnable, isFalse);
    final Future<CloudCardHintsStatus> first = service.checkAvailability();
    final Future<CloudCardHintsStatus> second = service.checkAvailability(
      force: true,
    );
    expect(identical(first, second), isTrue);
    expect(
      service.status.value.availability,
      CloudCardHintsAvailability.checking,
    );
    response.complete(_status(true));
    expect((await first).canEnable, isTrue);
    expect((await second).message, 'Text assistance configured');
    expect(checks, 1);
  });

  test('unconfigured deployment blocks image inference until explicit status retry succeeds', () async {
    bool configured = false;
    int images = 0;
    int checks = 0;
    final CloudCardHintsService service = CloudCardHintsService(
      enabled: true,
      statusCallable: () async {
        checks++;
        return _status(configured);
      },
      callable: (String _) async {
        images++;
        return <String, Object?>{};
      },
    );
    addTearDown(service.dispose);
    await expectLater(
      service.suggest('image', isAuthorized: () => true),
      throwsA(isA<CloudCardHintsException>()),
    );
    expect(
      service.status.value.availability,
      CloudCardHintsAvailability.notConfigured,
    );
    expect(service.status.value.canEnable, isFalse);
    expect(images, 0);
    configured = true;
    await service.checkAvailability(force: true);
    await service.suggest('image', isAuthorized: () => true);
    expect(images, 1);
    expect(checks, 2);
  });

  test('malformed status cannot advertise a configured model', () async {
    for (final Object? response in <Object?>[
      null,
      <String, Object?>{},
      <String, Object?>{..._status(true), 'model': ''},
      <String, Object?>{..._status(true), 'model': '../model'},
      <String, Object?>{..._status(true), 'mode': 'printing-classifier'},
      <String, Object?>{..._status(false), 'model': 'disabled-model'},
      <String, Object?>{..._status(true), 'confidence': 1},
    ]) {
      final CloudCardHintsService service = CloudCardHintsService(
        enabled: true,
        statusCallable: () async => response,
      );
      final CloudCardHintsStatus status = await service.checkAvailability();
      expect(status.failure, CloudCardHintsFailure.invalidResponse);
      expect(status.canEnable, isFalse);
      service.dispose();
    }
  });

  test('callable failures expose deployment, verification, authentication and timeout states without logging server messages', () async {
    final List<
      ({
        FirebaseFunctionsException error,
        CloudCardHintsFailure? failure,
        CloudCardHintsAvailability availability,
      })
    >
    cases =
        <
          ({
            FirebaseFunctionsException error,
            CloudCardHintsFailure? failure,
            CloudCardHintsAvailability availability,
          })
        >[
          (
            error: FirebaseFunctionsException(
              code: 'not-found',
              message: 'private diagnostic',
            ),
            failure: CloudCardHintsFailure.notDeployed,
            availability: CloudCardHintsAvailability.unavailable,
          ),
          (
            error: FirebaseFunctionsException(
              code: 'unauthenticated',
              message: 'Authentication failed',
            ),
            failure: CloudCardHintsFailure.authenticationUnavailable,
            availability: CloudCardHintsAvailability.unavailable,
          ),
          (
            error: FirebaseFunctionsException(
              code: 'unauthenticated',
              message: 'Sign in required',
              details: <String, String>{'reason': 'sign-in-required'},
            ),
            failure: CloudCardHintsFailure.signInRequired,
            availability: CloudCardHintsAvailability.unavailable,
          ),
          (
            error: FirebaseFunctionsException(
              code: 'failed-precondition',
              message: 'Verification required',
              details: <String, String>{'reason': 'app-verification-required'},
            ),
            failure: CloudCardHintsFailure.appVerificationRequired,
            availability: CloudCardHintsAvailability.unavailable,
          ),
          (
            error: FirebaseFunctionsException(
              code: 'failed-precondition',
              message: 'Unconfigured',
              details: <String, String>{'reason': 'not-configured'},
            ),
            failure: null,
            availability: CloudCardHintsAvailability.notConfigured,
          ),
          (
            error: FirebaseFunctionsException(
              code: 'deadline-exceeded',
              message: 'Timed out',
            ),
            failure: CloudCardHintsFailure.timedOut,
            availability: CloudCardHintsAvailability.unavailable,
          ),
        ];
    for (final ({
          FirebaseFunctionsException error,
          CloudCardHintsFailure? failure,
          CloudCardHintsAvailability availability,
        })
        item
        in cases) {
      final CloudCardHintsService service = CloudCardHintsService(
        enabled: true,
        statusCallable: () async => throw item.error,
      );
      final CloudCardHintsStatus status = await service.checkAvailability();
      expect(status.availability, item.availability);
      expect(status.failure, item.failure);
      expect(status.message, isNot(contains('private diagnostic')));
      expect(status.canEnable, isFalse);
      service.dispose();
    }
  });

  test('revoking permission while the no-image probe runs prevents the paid image call', () async {
    final Completer<Object?> status = Completer<Object?>();
    bool permitted = true;
    int images = 0;
    final CloudCardHintsService service = CloudCardHintsService(
      enabled: true,
      statusCallable: () => status.future,
      callable: (String _) async {
        images++;
        return null;
      },
    );
    addTearDown(service.dispose);
    final Future<void> result = expectLater(
      service.suggest('image', isAuthorized: () => permitted),
      throwsA(isA<CloudCardHintsException>()),
    );
    permitted = false;
    status.complete(_status(true));
    await result;
    expect(images, 0);
  });

  test('deadline during status check cannot launch inference when its response arrives late', () async {
    final Completer<Object?> status = Completer<Object?>();
    int images = 0;
    final CloudCardHintsService service = CloudCardHintsService(
      enabled: true,
      timeout: const Duration(milliseconds: 5),
      statusCallable: () => status.future,
      callable: (String _) async {
        images++;
        return null;
      },
    );
    addTearDown(service.dispose);
    await expectLater(
      service.suggest('image', isAuthorized: () => true),
      throwsA(isA<CloudCardHintsException>()),
    );
    expect(service.status.value.failure, CloudCardHintsFailure.timedOut);
    status.complete(_status(true));
    await Future<void>.delayed(Duration.zero);
    expect(images, 0);
    expect(service.status.value.canEnable, isFalse);
  });

  test('disposed service ignores an in-flight availability reply and cannot start an image call', () async {
    final Completer<Object?> status = Completer<Object?>();
    int images = 0;
    final CloudCardHintsService service = CloudCardHintsService(
      enabled: true,
      statusCallable: () => status.future,
      callable: (String _) async {
        images++;
        return null;
      },
    );
    final Future<void> result = expectLater(
      service.suggest('image', isAuthorized: () => true),
      throwsA(isA<CloudCardHintsException>()),
    );
    service.dispose();
    status.complete(_status(true));
    await result;
    expect(images, 0);
  });
}
