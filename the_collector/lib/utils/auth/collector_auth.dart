import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

const bool appleSignInEnabled = bool.fromEnvironment('APPLE_SIGN_IN_ENABLED');

enum SocialSignInProvider { google, apple }

enum DeletionVerification { verified, manualAppleRevocation }

const String _googleServerClientId =
    '774038668608-hufn0cs8pj4sa9fna708kqn7e7jmoile.apps.googleusercontent.com';

abstract interface class CollectorAuth {
  bool get supportsGoogleSignIn;
  bool get supportsAppleSignIn;
  bool get deletionRequiresPassword;
  Future<DeletionVerification> reauthenticateForDeletion({String? password});
  Future<void> signInWithGoogle();
  Future<void> signInWithApple();
  Future<void> signInWithEmail(String email, String password);
  Future<void> registerWithEmail(String email, String password);
  Future<void> resetPassword(String email);
  Future<void> signOut();
}

class FirebaseCollectorAuth implements CollectorAuth {
  FirebaseCollectorAuth({
    this.firebaseAuth,
    GoogleSignIn? googleSignIn,
    this.isWeb = kIsWeb,
    this.appleEnabled = appleSignInEnabled,
    this.useEmulators = const bool.fromEnvironment('USE_FIREBASE_EMULATORS'),
    this.revocationClientFactory = http.Client.new,
  }) : _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  static final FirebaseCollectorAuth instance = FirebaseCollectorAuth();

  final FirebaseAuth? firebaseAuth;
  final bool isWeb;
  final bool appleEnabled;
  final bool useEmulators;
  final GoogleSignIn _googleSignIn;
  final http.Client Function() revocationClientFactory;
  Future<void>? _googleInitialization;

  FirebaseAuth get _firebase => firebaseAuth ?? FirebaseAuth.instance;

  @override
  bool get supportsGoogleSignIn =>
      isWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  bool get supportsAppleSignIn =>
      appleEnabled &&
      (isWeb ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<void> signInWithApple() async {
    if (!supportsAppleSignIn) {
      throw UnsupportedError('Apple sign-in is unavailable on this platform.');
    }
    final AppleAuthProvider provider = AppleAuthProvider()..addScope('email');
    if (isWeb) {
      await _firebase.signInWithPopup(provider);
    } else {
      await _firebase.signInWithProvider(provider);
    }
  }

  Future<void> _initializeGoogle() async {
    try {
      await (_googleInitialization ??= _googleSignIn.initialize(
        serverClientId: _googleServerClientId,
      ));
    } catch (_) {
      _googleInitialization = null;
      rethrow;
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    if (!supportsGoogleSignIn) {
      throw UnsupportedError('Google sign-in is unavailable on this platform.');
    }
    if (isWeb) {
      await _firebase.signInWithPopup(GoogleAuthProvider());
      return;
    }
    await _firebase.signInWithCredential(await _googleCredential());
  }

  Future<OAuthCredential> _googleCredential() async {
    await _initializeGoogle();
    final GoogleSignInAccount account = await _googleSignIn.authenticate();
    final String? token = account.authentication.idToken;
    if (token == null || token.isEmpty) {
      throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
      );
    }
    return GoogleAuthProvider.credential(idToken: token);
  }

  @override
  bool get deletionRequiresPassword =>
      _firebase.currentUser?.providerData.any(
        (UserInfo provider) => provider.providerId == 'password',
      ) ??
      false;

  @override
  Future<DeletionVerification> reauthenticateForDeletion({
    String? password,
  }) async {
    final User? user = _firebase.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'requires-recent-login');
    }
    final Set<String> providers = user.providerData
        .map((UserInfo provider) => provider.providerId)
        .toSet();
    UserCredential? appleCredential;
    if (providers.contains('password')) {
      final String? email = user.email;
      if (email == null || password == null || password.isEmpty) {
        throw FirebaseAuthException(code: 'wrong-password');
      }
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
    } else if (providers.contains('google.com')) {
      if (!supportsGoogleSignIn) {
        throw FirebaseAuthException(code: 'operation-not-allowed');
      }
      if (isWeb) {
        await user.reauthenticateWithPopup(GoogleAuthProvider());
      } else {
        await user.reauthenticateWithCredential(await _googleCredential());
      }
    } else if (providers.contains('apple.com')) {
      final AppleAuthProvider provider = AppleAuthProvider();
      appleCredential = isWeb
          ? await user.reauthenticateWithPopup(provider)
          : await user.reauthenticateWithProvider(provider);
    } else {
      throw FirebaseAuthException(code: 'operation-not-allowed');
    }
    _verifyCurrentUser(user);
    DeletionVerification verification = DeletionVerification.verified;
    if (providers.contains('apple.com')) {
      verification = appleCredential == null
          ? DeletionVerification.manualAppleRevocation
          : await _revokeApple(user, appleCredential);
    }
    await user.getIdToken(true);
    _verifyCurrentUser(user);
    return verification;
  }

  void _verifyCurrentUser(User user) {
    if (_firebase.currentUser?.uid != user.uid) {
      throw FirebaseAuthException(code: 'user-mismatch');
    }
  }

  Future<DeletionVerification> _revokeApple(
    User user,
    UserCredential credential,
  ) async {
    if (isWeb && useEmulators) {
      return DeletionVerification.manualAppleRevocation;
    }
    final AuthCredential? providerCredential = isWeb
        ? credential.credential
        : null;
    final String? token = isWeb
        ? (providerCredential is OAuthCredential &&
                  providerCredential.providerId == 'apple.com'
              ? providerCredential.accessToken
              : null)
        : credential.additionalUserInfo?.authorizationCode;
    if (token == null || token.isEmpty) {
      return DeletionVerification.manualAppleRevocation;
    }
    final String? idToken = await user.getIdToken(true);
    _verifyCurrentUser(user);
    if (idToken == null || idToken.isEmpty) {
      throw FirebaseAuthException(code: 'requires-recent-login');
    }
    DeletionVerification verification = DeletionVerification.verified;
    if (isWeb) {
      final http.Client client = revocationClientFactory();
      try {
        _verifyCurrentUser(user);
        final String? tenantId = _firebase.tenantId;
        final http.Response response = await client
            .post(
              Uri.https(
                'identitytoolkit.googleapis.com',
                '/v2/accounts:revokeToken',
                <String, String>{'key': _firebase.app.options.apiKey},
              ),
              headers: const <String, String>{
                'Content-Type': 'application/json',
              },
              body: jsonEncode(<String, String>{
                'providerId': 'apple.com',
                'tokenType': 'ACCESS_TOKEN',
                'token': token,
                'idToken': idToken,
                'tenantId': ?tenantId,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          verification = DeletionVerification.manualAppleRevocation;
        }
      } on Exception {
        verification = DeletionVerification.manualAppleRevocation;
      } finally {
        client.close();
      }
    } else {
      try {
        await _firebase
            .revokeTokenWithAuthorizationCode(token)
            .timeout(const Duration(seconds: 15));
      } on Exception {
        verification = DeletionVerification.manualAppleRevocation;
      }
    }
    _verifyCurrentUser(user);
    return verification;
  }

  @override
  Future<void> signInWithEmail(String email, String password) async {
    await _firebase.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  @override
  Future<void> registerWithEmail(String email, String password) async {
    await _firebase.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  @override
  Future<void> resetPassword(String email) async {
    try {
      await _firebase.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (error) {
      if (error.code != 'user-not-found') rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      final bool googleSession =
          _googleInitialization != null ||
          (_firebase.currentUser?.providerData.any(
                (UserInfo provider) => provider.providerId == 'google.com',
              ) ??
              false);
      if (!isWeb && supportsGoogleSignIn && googleSession) {
        await _initializeGoogle();
        await _googleSignIn.signOut();
      }
    } finally {
      await _firebase.signOut();
    }
  }
}

String? authFailureMessage(Object error, {SocialSignInProvider? provider}) {
  final String? providerName = switch (provider) {
    SocialSignInProvider.google => 'Google',
    SocialSignInProvider.apple => 'Apple',
    null => null,
  };
  if (error is PlatformException &&
      (error.code == 'keychain-error' || error.code == 'keychain_error')) {
    return 'Your device could not save sign-in credentials. Check Keychain access and try again.';
  }
  if (error is GoogleSignInException) {
    return switch (error.code) {
      GoogleSignInExceptionCode.canceled => null,
      GoogleSignInExceptionCode.clientConfigurationError ||
      GoogleSignInExceptionCode.providerConfigurationError =>
        'Google sign-in is unavailable. Use email and password.',
      _ => 'Could not complete Google sign-in. Try again.',
    };
  }
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'popup-closed-by-user' || 'cancelled-popup-request' => null,
      'invalid-credential' when providerName != null =>
        'Could not complete $providerName sign-in. Try again.',
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' => 'The email or password is incorrect.',
      'invalid-email' => 'Enter a valid email address.',
      'weak-password' => 'Use a stronger password and try again.',
      'email-already-in-use' =>
        'An account already uses this email address. Sign in instead.',
      'account-exists-with-different-credential' =>
        'This account uses another sign-in method. Use that method first.',
      'network-request-failed' => 'Check your connection and try again.',
      'keychain-error' => 'Your device could not save sign-in credentials. Check Keychain access and try again.',
      'too-many-requests' => 'Too many attempts. Wait and try again.',
      'popup-blocked' =>
        'Allow pop-ups, then try ${providerName ?? 'sign-in'} again.',
      'operation-not-allowed' || 'unauthorized-domain' =>
        'This sign-in method is unavailable. Try another method.',
      'user-disabled' => 'This account is disabled. Contact support.',
      'requires-recent-login' => 'Sign in again before deleting your account.',
      'user-mismatch' => 'Verify the account that is currently signed in.',
      'canceled' || 'web-context-canceled' => null,
      _ => 'Could not complete the request. Try again.',
    };
  }
  return 'Could not complete the request. Try again.';
}
