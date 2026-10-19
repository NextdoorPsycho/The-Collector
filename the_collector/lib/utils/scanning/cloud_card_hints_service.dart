import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'cloud_scan_consent.dart';

typedef CloudCardHintsCallable = Future<Object?> Function(String imageBase64);
typedef CloudCardHintsStatusCallable = Future<Object?> Function();

enum CloudCardHintsAvailability {
  disabled,
  unchecked,
  checking,
  ready,
  notConfigured,
  unavailable,
}

enum CloudCardHintsFailure {
  signInRequired,
  authenticationUnavailable,
  appVerificationRequired,
  notDeployed,
  timedOut,
  requestFailed,
  invalidResponse,
  invalidCrop,
  catalogUnavailable,
  consentRequired,
}

class CloudCardHintsStatus {
  const CloudCardHintsStatus(this.availability, {this.failure});
  final CloudCardHintsAvailability availability;
  final CloudCardHintsFailure? failure;
  bool get canEnable => availability == CloudCardHintsAvailability.ready;
  String get message => switch (failure) {
    CloudCardHintsFailure.signInRequired => 'Sign in required',
    CloudCardHintsFailure.authenticationUnavailable =>
      'Authentication unavailable',
    CloudCardHintsFailure.appVerificationRequired =>
      'App verification required',
    CloudCardHintsFailure.notDeployed => 'Cloud service not deployed',
    CloudCardHintsFailure.timedOut => 'Cloud request timed out',
    CloudCardHintsFailure.invalidResponse => 'Invalid cloud response',
    CloudCardHintsFailure.invalidCrop => 'Card image unavailable',
    CloudCardHintsFailure.catalogUnavailable => 'Catalog unavailable',
    CloudCardHintsFailure.consentRequired => 'Cloud assistance is off',
    CloudCardHintsFailure.requestFailed => 'Cloud assistance unavailable',
    null => switch (availability) {
      CloudCardHintsAvailability.disabled => 'Unavailable in this build',
      CloudCardHintsAvailability.unchecked => 'Availability not checked',
      CloudCardHintsAvailability.checking => 'Checking availability',
      CloudCardHintsAvailability.ready => 'Text assistance configured',
      CloudCardHintsAvailability.notConfigured =>
        'Cloud service not configured',
      CloudCardHintsAvailability.unavailable => 'Cloud assistance unavailable',
    },
  };
}

class CloudCardHintsException implements Exception {
  const CloudCardHintsException(this.status);
  final CloudCardHintsStatus status;
}

class CloudCardHintsService {
  CloudCardHintsService({
    this.enabled = cloudCardHintsEnabled,
    CloudCardHintsCallable? callable,
    CloudCardHintsStatusCallable? statusCallable,
    this.timeout = const Duration(seconds: 15),
  }) : _callable = callable ?? _callFirebase,
       _statusCallable = statusCallable ?? _statusFirebase,
       _status = ValueNotifier<CloudCardHintsStatus>(
         CloudCardHintsStatus(
           enabled
               ? CloudCardHintsAvailability.unchecked
               : CloudCardHintsAvailability.disabled,
         ),
       );

  static final CloudCardHintsService instance = CloudCardHintsService();
  final bool enabled;
  final Duration timeout;
  final CloudCardHintsCallable _callable;
  final CloudCardHintsStatusCallable _statusCallable;
  final ValueNotifier<CloudCardHintsStatus> _status;
  Future<CloudCardHintsStatus>? _checking;
  bool _disposed = false;
  ValueListenable<CloudCardHintsStatus> get status => _status;

  void _publish(CloudCardHintsStatus status) {
    if (!_disposed) _status.value = status;
  }

  void reportFailure(CloudCardHintsFailure failure) => _publish(
    CloudCardHintsStatus(
      CloudCardHintsAvailability.unavailable,
      failure: failure,
    ),
  );
  void reportError(Object error) => _publish(_errorStatus(error));

  Future<CloudCardHintsStatus> checkAvailability({bool force = false}) {
    if (_disposed || !enabled) {
      return Future<CloudCardHintsStatus>.value(_status.value);
    }
    final Future<CloudCardHintsStatus>? pending = _checking;
    if (pending != null) return pending;
    if (!force &&
        (_status.value.canEnable ||
            _status.value.availability ==
                CloudCardHintsAvailability.notConfigured)) {
      return Future<CloudCardHintsStatus>.value(_status.value);
    }
    _publish(const CloudCardHintsStatus(CloudCardHintsAvailability.checking));
    final Future<CloudCardHintsStatus> request = _check().whenComplete(
      () => _checking = null,
    );
    _checking = request;
    return request;
  }

  Future<CloudCardHintsStatus> _check() async {
    CloudCardHintsStatus result;
    try {
      final Object? response = await _statusCallable().timeout(timeout);
      if (response is! Map<Object?, Object?> ||
          response.length != 3 ||
          response['configured'] is! bool ||
          response['mode'] != 'text-transcription' ||
          (response['configured'] == true &&
              (response['model'] is! String ||
                  !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
                      .hasMatch(response['model'] as String))) ||
          (response['configured'] == false && response['model'] != null)) {
        throw const CloudCardHintsException(
          CloudCardHintsStatus(
            CloudCardHintsAvailability.unavailable,
            failure: CloudCardHintsFailure.invalidResponse,
          ),
        );
      }
      result = CloudCardHintsStatus(
        response['configured'] == true
            ? CloudCardHintsAvailability.ready
            : CloudCardHintsAvailability.notConfigured,
      );
    } catch (error) {
      result = _errorStatus(error);
    }
    _publish(result);
    return result;
  }

  Future<Object?> suggest(
    String imageBase64, {
    required bool Function() isAuthorized,
  }) async {
    if (!enabled) throw CloudCardHintsException(_status.value);
    if (_disposed || !isAuthorized()) {
      throw const CloudCardHintsException(
        CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.consentRequired,
        ),
      );
    }
    final CloudCardHintsStatus availability = await checkAvailability();
    if (!availability.canEnable) throw CloudCardHintsException(availability);
    if (_disposed || !isAuthorized()) {
      throw const CloudCardHintsException(
        CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.consentRequired,
        ),
      );
    }
    try {
      final Object? result = await _callable(imageBase64).timeout(timeout);
      if (_disposed || !isAuthorized()) {
        throw const CloudCardHintsException(
          CloudCardHintsStatus(
            CloudCardHintsAvailability.unavailable,
            failure: CloudCardHintsFailure.consentRequired,
          ),
        );
      }
      _publish(const CloudCardHintsStatus(CloudCardHintsAvailability.ready));
      return result;
    } catch (error) {
      final CloudCardHintsStatus failure = _errorStatus(error);
      if (isAuthorized()) _publish(failure);
      throw CloudCardHintsException(failure);
    }
  }

  static CloudCardHintsStatus _errorStatus(Object error) {
    if (error is CloudCardHintsException) return error.status;
    if (error is TimeoutException) {
      return const CloudCardHintsStatus(
        CloudCardHintsAvailability.unavailable,
        failure: CloudCardHintsFailure.timedOut,
      );
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      if (error.code == 'failed-precondition' &&
          details is Map<Object?, Object?> &&
          details['reason'] == 'not-configured') {
        return const CloudCardHintsStatus(
          CloudCardHintsAvailability.notConfigured,
        );
      }
      if (details is Map<Object?, Object?> &&
          details['reason'] == 'sign-in-required') {
        return const CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.signInRequired,
        );
      }
      if (details is Map<Object?, Object?> &&
          details['reason'] == 'app-verification-required') {
        return const CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.appVerificationRequired,
        );
      }
      final CloudCardHintsFailure failure = switch (error.code) {
        'unauthenticated' => CloudCardHintsFailure.authenticationUnavailable,
        'permission-denied' => CloudCardHintsFailure.appVerificationRequired,
        'not-found' || 'unimplemented' => CloudCardHintsFailure.notDeployed,
        'deadline-exceeded' => CloudCardHintsFailure.timedOut,
        _ => CloudCardHintsFailure.requestFailed,
      };
      return CloudCardHintsStatus(
        CloudCardHintsAvailability.unavailable,
        failure: failure,
      );
    }
    return const CloudCardHintsStatus(
      CloudCardHintsAvailability.unavailable,
      failure: CloudCardHintsFailure.requestFailed,
    );
  }

  static Future<Object?> _invoke(String name, Object payload) async {
    final HttpsCallableResult<Object?> result =
        await FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable(
              name,
              options: HttpsCallableOptions(
                timeout: const Duration(seconds: 15),
              ),
            )
            .call<Object?>(payload);
    return result.data;
  }

  static Future<Object?> _statusFirebase() =>
      _invoke('cardHintsStatus', const <String, Object?>{});
  static Future<Object?> _callFirebase(String imageBase64) =>
      _invoke('suggestCardHints', <String, String>{'imageBase64': imageBase64});

  void dispose() {
    _disposed = true;
    _status.dispose();
  }
}
