import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:the_collector/firebase_options.dart';

const bool _emulatorsRequested = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
const bool _cloudCardHintsEnabled = bool.fromEnvironment(
  'CLOUD_CARD_HINTS_ENABLED',
);
const bool _cloudAppCheckDebug = bool.fromEnvironment('CLOUD_APP_CHECK_DEBUG');
const String _emulatorHost = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '127.0.0.1',
);
bool _emulatorsInitialized = false;

Future<void> initializeCollectorFirebase() async {
  if (_cloudAppCheckDebug && !_cloudCardHintsEnabled) {
    throw StateError(
      'CLOUD_APP_CHECK_DEBUG requires CLOUD_CARD_HINTS_ENABLED.',
    );
  }
  if (_cloudCardHintsEnabled) {
    if (_cloudAppCheckDebug && kReleaseMode) {
      throw StateError(
        'App Check debug providers require a debug or profile build.',
      );
    }
    if (_emulatorsRequested) {
      throw StateError(
        'Disable cloud card hints when using Firebase emulators.',
      );
    }
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      throw UnsupportedError('Cloud card hints require iOS or Android.');
    }
  }
  if (_emulatorsRequested && kReleaseMode) {
    throw StateError('Firebase emulators require a debug or profile build.');
  }
  if (_emulatorsRequested &&
      kIsWeb &&
      (!kDebugMode || Uri.base.host != 'localhost')) {
    throw StateError(
      'Use a debug web build at http://localhost, so Firebase authentication stays connected after refresh.',
    );
  }
  if (_emulatorsRequested && _emulatorsInitialized) {
    return;
  }
  final FirebaseOptions options = _emulatorsRequested
      ? FirebaseOptions(
          apiKey: 'A00000000000000000000000000000000000000',
          appId: DefaultFirebaseOptions.currentPlatform.appId,
          messagingSenderId: '123456789',
          projectId: 'demo-the-collector',
          authDomain: 'localhost',
        )
      : DefaultFirebaseOptions.currentPlatform;
  await Firebase.initializeApp(options: options);
  if (_cloudCardHintsEnabled) {
    await FirebaseAppCheck.instance.activate(
      providerApple: _cloudAppCheckDebug
          ? const AppleDebugProvider()
          : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      providerAndroid: _cloudAppCheckDebug
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
    );
  }
  if (_emulatorsRequested) {
    await FirebaseAuth.instance.useAuthEmulator(_emulatorHost, 19099);
    FirebaseFirestore.instance.useFirestoreEmulator(_emulatorHost, 18080);
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );
    FirebaseFunctions.instanceFor(region: 'us-central1')
        .useFunctionsEmulator(_emulatorHost, 15001);
    _emulatorsInitialized = true;
  }
}
