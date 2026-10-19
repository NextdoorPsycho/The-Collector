import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

class _Info extends Fake implements AdditionalUserInfo {
  _Info(this.authorizationCode);
  @override
  final String? authorizationCode;
}

class _Credential extends Fake implements UserCredential {
  _Credential([this.additionalUserInfo, this.credential]);
  @override
  final AdditionalUserInfo? additionalUserInfo;
  @override
  final AuthCredential? credential;
}

class _App extends Fake implements FirebaseApp {
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'test-public-api-key',
    appId: 'test-app',
    messagingSenderId: 'test-sender',
    projectId: 'test-project',
  );
}

class _Client extends MockClient {
  _Client(super.fn);

  int closeCalls = 0;

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

class _Provider extends Fake implements UserInfo {
  _Provider(this.providerId);
  @override
  final String providerId;
}

class _User extends Fake implements User {
  _User(String provider) : providerData = <UserInfo>[_Provider(provider)];
  @override
  final List<UserInfo> providerData;
  @override
  String get uid => 'current-user';
  @override
  String get email => 'current@example.test';
  final List<AuthCredential> credentials = <AuthCredential>[];
  final List<AuthProvider> popupProviders = <AuthProvider>[];
  final List<AuthProvider> nativeProviders = <AuthProvider>[];
  final List<bool> tokenRefreshes = <bool>[];
  Object? error;
  String? authorizationCode;
  String? accessToken;
  String? idToken = 'fresh-token';
  void Function()? onReauthenticate;
  void Function()? onTokenRefresh;

  Future<UserCredential> _result() async {
    if (error != null) throw error!;
    onReauthenticate?.call();
    return _Credential(
      _Info(authorizationCode),
      accessToken == null
          ? null
          : OAuthProvider('apple.com').credential(accessToken: accessToken),
    );
  }

  @override
  Future<UserCredential> reauthenticateWithCredential(
    AuthCredential credential,
  ) {
    credentials.add(credential);
    return _result();
  }

  @override
  Future<UserCredential> reauthenticateWithPopup(AuthProvider provider) {
    popupProviders.add(provider);
    return _result();
  }

  @override
  Future<UserCredential> reauthenticateWithProvider(AuthProvider provider) {
    nativeProviders.add(provider);
    return _result();
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    tokenRefreshes.add(forceRefresh);
    onTokenRefresh?.call();
    return idToken;
  }
}

class _Firebase extends Fake implements FirebaseAuth {
  final List<AuthCredential> credentials = <AuthCredential>[];
  final List<AuthProvider> providers = <AuthProvider>[];
  final List<AuthProvider> nativeProviders = <AuthProvider>[];
  Object? providerError;
  int signOutCalls = 0;
  Object? resetError;
  User? user;
  final List<String> revokedCodes = <String>[];
  Object? revokeError;
  void Function()? onRevoke;

  @override
  FirebaseApp get app => _App();

  @override
  String? tenantId;

  @override
  User? get currentUser => user;
  @override
  Future<void> revokeTokenWithAuthorizationCode(
    String authorizationCode,
  ) async {
    revokedCodes.add(authorizationCode);
    onRevoke?.call();
    if (revokeError != null) throw revokeError!;
  }

  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    credentials.add(credential);
    return _Credential();
  }

  @override
  Future<UserCredential> signInWithPopup(AuthProvider provider) async {
    providers.add(provider);
    if (providerError != null) throw providerError!;
    return _Credential();
  }

  @override
  Future<UserCredential> signInWithProvider(AuthProvider provider) async {
    nativeProviders.add(provider);
    if (providerError != null) throw providerError!;
    return _Credential();
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) async {
    if (resetError != null) throw resetError!;
  }
}

class _Account extends Fake implements GoogleSignInAccount {
  _Account(this.token);

  final String? token;

  @override
  GoogleSignInAuthentication get authentication =>
      GoogleSignInAuthentication(idToken: token);
}

class _Google extends Fake implements GoogleSignIn {
  int initializeCalls = 0;
  int authenticateCalls = 0;
  int signOutCalls = 0;
  String? initializedClientId;
  String? initializedServerClientId;
  Object? initializeError;
  Object? authenticateError;
  Object? signOutError;
  String? token = 'mock-id-token';

  @override
  Future<void> initialize({
    String? clientId,
    String? serverClientId,
    String? nonce,
    String? hostedDomain,
  }) async {
    initializeCalls++;
    initializedClientId = clientId;
    initializedServerClientId = serverClientId;
    if (initializeError != null) throw initializeError!;
  }

  @override
  Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const <String>[],
  }) async {
    authenticateCalls++;
    if (authenticateError != null) throw authenticateError!;
    return _Account(token);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (signOutError != null) throw signOutError!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Apple sign-in is hidden until explicitly configured', () async {
    final _Firebase firebase = _Firebase();
    final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
      firebaseAuth: firebase,
      appleEnabled: false,
      isWeb: true,
    );
    expect(auth.supportsAppleSignIn, isFalse);
    await expectLater(auth.signInWithApple(), throwsUnsupportedError);
    expect(firebase.providers, isEmpty);
    expect(firebase.nativeProviders, isEmpty);
  });

  for (final TargetPlatform platform in TargetPlatform.values) {
    test('Apple native availability and routing on $platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final _Firebase firebase = _Firebase();
      final _Google google = _Google();
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: google,
        appleEnabled: true,
        isWeb: false,
      );
      final bool supported =
          platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
      expect(auth.supportsAppleSignIn, supported);
      if (supported) {
        await auth.signInWithApple();
        final AppleAuthProvider provider =
            firebase.nativeProviders.single as AppleAuthProvider;
        expect(provider.scopes, <String>['email']);
      } else {
        await expectLater(auth.signInWithApple(), throwsUnsupportedError);
        expect(firebase.nativeProviders, isEmpty);
      }
      expect(firebase.providers, isEmpty);
      expect(firebase.credentials, isEmpty);
      expect(firebase.revokedCodes, isEmpty);
      expect(google.initializeCalls, 0);
    });
  }

  test(
    'Apple popup routing, cancellation and retry preserve safe feedback',
    () async {
      final _Firebase firebase = _Firebase()
        ..providerError = FirebaseAuthException(code: 'canceled');
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        appleEnabled: true,
        isWeb: true,
      );
      await expectLater(
        auth.signInWithApple(),
        throwsA(isA<FirebaseAuthException>()),
      );
      expect(authFailureMessage(firebase.providerError!), isNull);
      firebase.providerError = null;
      await auth.signInWithApple();
      expect((firebase.providers.last as AppleAuthProvider).scopes, <String>[
        'email',
      ]);
      expect(firebase.nativeProviders, isEmpty);
      expect(
        authFailureMessage(
          FirebaseAuthException(code: 'invalid-credential'),
          provider: SocialSignInProvider.apple,
        ),
        'Could not complete Apple sign-in. Try again.',
      );
      expect(
        authFailureMessage(
          FirebaseAuthException(code: 'popup-blocked'),
          provider: SocialSignInProvider.apple,
        ),
        contains('Apple'),
      );
    },
  );

  test(
    'email deletion verifies current email and refreshes only after success',
    () async {
      final _User user = _User('password');
      final _Firebase firebase = _Firebase()..user = user;
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
      );
      expect(auth.deletionRequiresPassword, isTrue);
      user.error = FirebaseAuthException(code: 'wrong-password');
      await expectLater(
        auth.reauthenticateForDeletion(password: 'wrong'),
        throwsA(isA<FirebaseAuthException>()),
      );
      expect(user.tokenRefreshes, isEmpty);
      user.error = null;
      await auth.reauthenticateForDeletion(password: 'current password');
      final EmailAuthCredential credential =
          user.credentials.last as EmailAuthCredential;
      expect(credential.email, 'current@example.test');
      expect(credential.password, 'current password');
      expect(user.tokenRefreshes, <bool>[true]);
      expect(firebase.credentials, isEmpty);
    },
  );

  for (final bool web in <bool>[false, true]) {
    test('Google deletion reauthenticates current user, web=$web', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final _User user = _User('google.com');
      final _Firebase firebase = _Firebase()..user = user;
      final _Google google = _Google();
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: google,
        isWeb: web,
      );
      expect(auth.deletionRequiresPassword, isFalse);
      await auth.reauthenticateForDeletion();
      expect(user.tokenRefreshes, <bool>[true]);
      expect(firebase.credentials, isEmpty);
      expect(firebase.providers, isEmpty);
      if (web) {
        expect(user.popupProviders.single, isA<GoogleAuthProvider>());
        expect(google.authenticateCalls, 0);
      } else {
        expect(
          (user.credentials.single as OAuthCredential).idToken,
          'mock-id-token',
        );
        expect(google.authenticateCalls, 1);
      }
    });
  }

  test(
    'native Apple deletion refreshes around authorization-code revocation',
    () async {
      final _User user = _User('apple.com')
        ..authorizationCode = 'test-authorization';
      final _Firebase firebase = _Firebase()..user = user;
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        isWeb: false,
      );
      expect(
        await auth.reauthenticateForDeletion(),
        DeletionVerification.verified,
      );
      expect(user.nativeProviders.single, isA<AppleAuthProvider>());
      expect(firebase.revokedCodes, <String>['test-authorization']);
      expect(user.tokenRefreshes, <bool>[true, true]);
      expect(firebase.credentials, isEmpty);
    },
  );

  test(
    'missing Apple token permits deletion with explicit manual revocation',
    () async {
      final _User user = _User('apple.com');
      final _Firebase firebase = _Firebase()..user = user;
      final DeletionVerification verification = await FirebaseCollectorAuth(
        firebaseAuth: firebase,
        isWeb: true,
      ).reauthenticateForDeletion();
      expect(verification, DeletionVerification.manualAppleRevocation);
      expect(user.popupProviders.single, isA<AppleAuthProvider>());
      expect(firebase.revokedCodes, isEmpty);
      expect(user.tokenRefreshes, <bool>[true]);
    },
  );

  test('web Apple revocation posts fresh same-user access token and closes its client', () async {
    final _User user = _User('apple.com')..accessToken = 'apple-access-token';
    final _Firebase firebase = _Firebase()
      ..user = user
      ..tenantId = 'test-tenant';
    final List<http.Request> requests = <http.Request>[];
    final _Client client = _Client((http.Request request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
      firebaseAuth: firebase,
      isWeb: true,
      revocationClientFactory: () => client,
    );
    expect(
      await auth.reauthenticateForDeletion(),
      DeletionVerification.verified,
    );
    final http.Request request = requests.single;
    expect(request.method, 'POST');
    expect(
      request.url,
      Uri.parse(
        'https://identitytoolkit.googleapis.com/v2/accounts:revokeToken?key=test-public-api-key',
      ),
    );
    expect(request.headers['content-type'], contains('application/json'));
    expect(jsonDecode(request.body), <String, String>{
      'providerId': 'apple.com',
      'tokenType': 'ACCESS_TOKEN',
      'token': 'apple-access-token',
      'idToken': 'fresh-token',
      'tenantId': 'test-tenant',
    });
    expect(firebase.revokedCodes, isEmpty);
    expect(user.tokenRefreshes, <bool>[true, true]);
    expect(client.closeCalls, 1);
  });

  test(
    'web emulator verification never creates a production revocation client',
    () async {
      final _User user = _User('apple.com')
        ..accessToken = 'emulator-access-token';
      final _Firebase firebase = _Firebase()..user = user;
      expect(
        await FirebaseCollectorAuth(
          firebaseAuth: firebase,
          isWeb: true,
          useEmulators: true,
          revocationClientFactory: () =>
              throw StateError('Production revocation must not run'),
        ).reauthenticateForDeletion(),
        DeletionVerification.manualAppleRevocation,
      );
      expect(user.tokenRefreshes, <bool>[true]);
      expect(firebase.revokedCodes, isEmpty);
    },
  );

  test(
    'web emulator compile define prevents production revocation by default',
    () async {
      final _User user = _User('apple.com')
        ..accessToken = 'emulator-access-token';
      final _Firebase firebase = _Firebase()..user = user;
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        isWeb: true,
        revocationClientFactory: () =>
            throw StateError('Production revocation must not run'),
      );
      expect(auth.useEmulators, isTrue);
      expect(
        await auth.reauthenticateForDeletion(),
        DeletionVerification.manualAppleRevocation,
      );
      expect(user.tokenRefreshes, <bool>[true]);
      expect(firebase.revokedCodes, isEmpty);
    },
    skip: !const bool.fromEnvironment('USE_FIREBASE_EMULATORS'),
  );

  test('web revocation failure closes its client and permits explicit manual fallback', () async {
    for (final bool transportFailure in <bool>[false, true]) {
      final _User user = _User('apple.com')..accessToken = 'apple-access-token';
      final _Firebase firebase = _Firebase()..user = user;
      final _Client client = _Client((http.Request request) async {
        expect(jsonDecode(request.body), isNot(contains('tenantId')));
        if (transportFailure) {
          throw http.ClientException('private token detail');
        }
        return http.Response('private provider diagnostics', 400);
      });
      expect(
        await FirebaseCollectorAuth(
          firebaseAuth: firebase,
          isWeb: true,
          revocationClientFactory: () => client,
        ).reauthenticateForDeletion(),
        DeletionVerification.manualAppleRevocation,
      );
      expect(client.closeCalls, 1);
      expect(user.tokenRefreshes, <bool>[true, true]);
    }
  });

  testWidgets(
    'web revocation timeout closes the one-off client and preserves deletion fallback',
    (WidgetTester tester) async {
      final _User user = _User('apple.com')..accessToken = 'apple-access-token';
      final _Firebase firebase = _Firebase()..user = user;
      final Completer<http.Response> pending = Completer<http.Response>();
      final _Client client = _Client((http.Request request) => pending.future);
      final Future<DeletionVerification> verification = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        isWeb: true,
        revocationClientFactory: () => client,
      ).reauthenticateForDeletion();
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      expect(await verification, DeletionVerification.manualAppleRevocation);
      expect(client.closeCalls, 1);
      pending.complete(http.Response('{}', 200));
      await tester.pump();
    },
  );

  test('native Apple missing code and failed revocation remain deletable with manual instructions', () async {
    for (final String? code in <String?>[null, '', 'test-authorization']) {
      final _User user = _User('apple.com')..authorizationCode = code;
      final _Firebase firebase = _Firebase()
        ..user = user
        ..revokeError = FirebaseAuthException(
          code: 'internal-error',
          message: 'private details',
        );
      expect(
        await FirebaseCollectorAuth(
          firebaseAuth: firebase,
          isWeb: false,
        ).reauthenticateForDeletion(),
        DeletionVerification.manualAppleRevocation,
      );
      expect(
        firebase.revokedCodes,
        code == 'test-authorization' ? <String>[code!] : isEmpty,
      );
    }
  });

  test('linked Apple identity verified with password or Google requires manual revocation', () async {
    for (final String provider in <String>['password', 'google.com']) {
      final _User user = _User(provider)
        ..providerData.add(_Provider('apple.com'));
      final _Firebase firebase = _Firebase()..user = user;
      expect(
        await FirebaseCollectorAuth(
          firebaseAuth: firebase,
          isWeb: true,
        ).reauthenticateForDeletion(password: 'current password'),
        DeletionVerification.manualAppleRevocation,
      );
      expect(firebase.revokedCodes, isEmpty);
      expect(user.nativeProviders, isEmpty);
      expect(user.popupProviders.whereType<AppleAuthProvider>(), isEmpty);
      expect(user.tokenRefreshes, <bool>[true]);
    }
  });

  test(
    'Apple account changes before revocation never revoke another account',
    () async {
      for (final bool duringRefresh in <bool>[false, true]) {
        final _User user = _User('apple.com')
          ..authorizationCode = 'test-authorization';
        final _Firebase firebase = _Firebase()..user = user;
        if (duringRefresh) {
          user.onTokenRefresh = () => firebase.user = null;
        } else {
          user.onReauthenticate = () => firebase.user = null;
        }
        await expectLater(
          FirebaseCollectorAuth(
            firebaseAuth: firebase,
            isWeb: false,
          ).reauthenticateForDeletion(),
          throwsA(
            isA<FirebaseAuthException>().having(
              (FirebaseAuthException e) => e.code,
              'code',
              'user-mismatch',
            ),
          ),
        );
        expect(firebase.revokedCodes, isEmpty);
      }
    },
  );

  test(
    'account changes during native or web revocation cannot pass verification',
    () async {
      for (final bool web in <bool>[false, true]) {
        final _User user = _User('apple.com')
          ..authorizationCode = 'test-authorization'
          ..accessToken = 'apple-access-token';
        final _Firebase firebase = _Firebase()..user = user;
        firebase.onRevoke = () => firebase.user = null;
        final _Client client = _Client((http.Request request) async {
          firebase.user = null;
          return http.Response('{}', 200);
        });
        await expectLater(
          FirebaseCollectorAuth(
            firebaseAuth: firebase,
            isWeb: web,
            revocationClientFactory: () => client,
          ).reauthenticateForDeletion(),
          throwsA(
            isA<FirebaseAuthException>().having(
              (FirebaseAuthException e) => e.code,
              'code',
              'user-mismatch',
            ),
          ),
        );
        expect(user.tokenRefreshes, <bool>[true]);
        expect(client.closeCalls, web ? 1 : 0);
      }
    },
  );

  test(
    'absent, unsupported or changed accounts cannot pass deletion verification',
    () async {
      final _Firebase firebase = _Firebase();
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
      );
      await expectLater(
        auth.reauthenticateForDeletion(),
        throwsA(isA<FirebaseAuthException>()),
      );
      firebase.user = _User('anonymous');
      await expectLater(
        auth.reauthenticateForDeletion(),
        throwsA(isA<FirebaseAuthException>()),
      );
      final _User user = _User('password')
        ..onReauthenticate = () => firebase.user = null;
      firebase.user = user;
      await expectLater(
        auth.reauthenticateForDeletion(password: 'password'),
        throwsA(isA<FirebaseAuthException>()),
      );
      expect(user.tokenRefreshes, isEmpty);
    },
  );

  test(
    'Google verification cancellation does not refresh or sign in',
    () async {
      final _User user = _User('google.com');
      final _Firebase firebase = _Firebase()..user = user;
      final _Google google = _Google()
        ..authenticateError = const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
        );
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: google,
        isWeb: false,
      );
      await expectLater(
        auth.reauthenticateForDeletion(),
        throwsA(isA<GoogleSignInException>()),
      );
      expect(user.credentials, isEmpty);
      expect(user.tokenRefreshes, isEmpty);
      expect(firebase.credentials, isEmpty);
    },
  );

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    test(
      '$platform uses the configured web OAuth ID for native sign-in',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final Map<String, Object?> configuration = jsonDecode(
          await File('android/app/google-services.json').readAsString(),
        ) as Map<String, Object?>;
        final Map<String, Object?> client =
            (configuration['client']! as List<Object?>).first!
                as Map<String, Object?>;
        final Map<String, Object?> webClient =
            (client['oauth_client']! as List<Object?>)
                .cast<Map<String, Object?>>()
                .singleWhere(
                  (Map<String, Object?> value) => value['client_type'] == 3,
                );
        final _Firebase firebase = _Firebase();
        final _Google google = _Google();
        final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
          firebaseAuth: firebase,
          googleSignIn: google,
          isWeb: false,
        );
        await auth.signInWithGoogle();
        expect(google.initializedServerClientId, webClient['client_id']);
        expect(google.initializedClientId, isNull);
        expect(firebase.credentials, hasLength(1));
      },
    );
  }

  test('native Google sign-in passes only the ID token to Firebase', () async {
    final _Firebase firebase = _Firebase();
    final _Google google = _Google();
    final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
      firebaseAuth: firebase,
      googleSignIn: google,
      isWeb: false,
    );
    await auth.signInWithGoogle();
    expect(google.initializeCalls, 1);
    expect(google.authenticateCalls, 1);
    expect(firebase.credentials.single.providerId, 'google.com');
    final OAuthCredential credential =
        firebase.credentials.single as OAuthCredential;
    expect(credential.idToken, 'mock-id-token');
    expect(credential.accessToken, isNull);
    await auth.signOut();
    expect(google.signOutCalls, 1);
    expect(firebase.signOutCalls, 1);
    await auth.signInWithGoogle();
    expect(google.initializeCalls, 1);
  });

  test(
    'native initialization failure can be retried without signing in',
    () async {
      final _Firebase firebase = _Firebase();
      final _Google google = _Google()
        ..initializeError = StateError('Mock init failure');
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: google,
        isWeb: false,
      );
      await expectLater(auth.signInWithGoogle(), throwsStateError);
      expect(google.authenticateCalls, 0);
      expect(firebase.credentials, isEmpty);
      google.initializeError = null;
      await auth.signInWithGoogle();
      expect(google.initializeCalls, 2);
      expect(firebase.credentials, hasLength(1));
    },
  );

  test('native cancellation never submits a Firebase credential', () async {
    final _Firebase firebase = _Firebase();
    const GoogleSignInException cancellation = GoogleSignInException(
      code: GoogleSignInExceptionCode.canceled,
    );
    final _Google google = _Google()..authenticateError = cancellation;
    final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
      firebaseAuth: firebase,
      googleSignIn: google,
      isWeb: false,
    );
    await expectLater(auth.signInWithGoogle(), throwsA(same(cancellation)));
    expect(firebase.credentials, isEmpty);
    expect(authFailureMessage(cancellation), isNull);
  });

  test('missing Google token never submits a Firebase credential', () async {
    final _Firebase firebase = _Firebase();
    final _Google google = _Google()..token = null;
    final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
      firebaseAuth: firebase,
      googleSignIn: google,
      isWeb: false,
    );
    await expectLater(
      auth.signInWithGoogle(),
      throwsA(isA<GoogleSignInException>()),
    );
    expect(firebase.credentials, isEmpty);
  });

  test(
    'Firebase signs out even if clearing the Google session fails',
    () async {
      final _Firebase firebase = _Firebase();
      final _Google google = _Google()
        ..signOutError = StateError('Mock sign-out failure');
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: google,
        isWeb: false,
      );
      await auth.signInWithGoogle();
      await expectLater(auth.signOut(), throwsStateError);
      expect(firebase.signOutCalls, 1);
    },
  );

  test(
    'web Google sign-in uses Firebase popup without the native plugin',
    () async {
      final _Firebase firebase = _Firebase();
      final _Google google = _Google();
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: google,
        isWeb: true,
      );
      await auth.signInWithGoogle();
      expect(firebase.providers.single, isA<GoogleAuthProvider>());
      expect(firebase.credentials, isEmpty);
      expect(google.initializeCalls, 0);
      expect(google.authenticateCalls, 0);
      await auth.signOut();
      expect(firebase.signOutCalls, 1);
      expect(google.signOutCalls, 0);
    },
  );

  test('keychain failures identify credential storage without exposing diagnostics', () {
    final FirebaseAuthException firebaseError = FirebaseAuthException(
      code: 'keychain-error',
      message: 'Private NSError',
    );
    final PlatformException platformError = PlatformException(
      code: 'keychain-error',
      message: 'Private NSError',
    );
    expect(authFailureMessage(firebaseError), contains('Keychain access'));
    expect(authFailureMessage(platformError), contains('Keychain access'));
    expect(
      authFailureMessage(firebaseError),
      isNot(contains('Private NSError')),
    );
  });

  test('popup cancellation is silent and blocked popups offer recovery', () {
    expect(
      authFailureMessage(FirebaseAuthException(code: 'popup-closed-by-user')),
      isNull,
    );
    expect(
      authFailureMessage(FirebaseAuthException(code: 'popup-blocked')),
      contains('Allow pop-ups'),
    );
  });

  test(
    'password reset does not reveal whether an email has an account',
    () async {
      final _Firebase firebase = _Firebase()
        ..resetError = FirebaseAuthException(code: 'user-not-found');
      final FirebaseCollectorAuth auth = FirebaseCollectorAuth(
        firebaseAuth: firebase,
        googleSignIn: _Google(),
      );
      await expectLater(
        auth.resetPassword('collector@example.test'),
        completes,
      );
    },
  );
}
