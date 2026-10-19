import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:the_collector/pages/account/privacy_data_screen.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/auth/account_deletion.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

class CollectorSignInScreen extends StatefulWidget {
  const CollectorSignInScreen({super.key, this.auth, this.accountNotice});

  final CollectorAuth? auth;
  final String? accountNotice;

  @override
  State<CollectorSignInScreen> createState() => _CollectorSignInScreenState();
}

class _CollectorSignInScreenState extends State<CollectorSignInScreen> {
  late final CollectorAuth _auth =
      widget.auth ?? FirebaseCollectorAuth.instance;
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _confirmationFocus = FocusNode();
  bool _register = false;
  bool _reset = false;
  bool _busy = false;
  String? _message;
  String? _emailError;
  String? _passwordError;
  String? _confirmationError;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    _passwordFocus.dispose();
    _confirmationFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _message = null;
      _emailError = null;
      _passwordError = null;
      _confirmationError = null;
    });
    if (!_validEmail) {
      setState(() => _emailError = 'Enter a valid email address.');
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _passwordError = 'Enter your password.');
      return;
    }
    if (_register && _password.text.length < 6) {
      setState(() => _passwordError = 'Use a password with at least 6 characters.');
      return;
    }
    if (_register && _confirmation.text != _password.text) {
      setState(() => _confirmationError = 'Passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (_register) {
        await _auth.registerWithEmail(_email.text.trim(), _password.text);
      } else {
        await _auth.signInWithEmail(_email.text.trim(), _password.text);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = authFailureMessage(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  bool get _validEmail =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim());

  void _resetPassword() {
    if (_busy) return;
    setState(() => _reset = true);
  }

  Widget _fieldError(String message) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Semantics(liveRegion: true, child: Text(message,
      style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.destructive))),
  );

  Future<void> _signInWithProvider(SocialSignInProvider provider) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      switch (provider) {
        case SocialSignInProvider.google:
          await _auth.signInWithGoogle();
        case SocialSignInProvider.apple:
          await _auth.signInWithApple();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = authFailureMessage(error, provider: provider),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _reset
      ? CollectorPasswordResetScreen(auth: _auth, initialEmail: _email.text.trim(),
          onClose: () => setState(() => _reset = false))
      : Scaffold(
    child: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ComponentTheme<TextFieldTheme>(
              data: MyThemeData.inputTheme.copyWith(
                padding: () =>
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: <Widget>[
                        const CollectorBrandMark(size: 32),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            'The Collector',
                            style: Theme.of(context).typography.h2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  if (widget.accountNotice != null) ...<Widget>[
                    Semantics(
                      liveRegion: true,
                      child: Text(widget.accountNotice!),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: <Widget>[
                      Text(
                        _register ? 'Register' : 'Sign in',
                        style: Theme.of(context).typography.large,
                      ),
                      TextButton(
                        density: ButtonDensity.normal,
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _register = !_register;
                                _confirmation.clear();
                                _message = null;
                                _emailError = null;
                                _passwordError = null;
                                _confirmationError = null;
                              }),
                        child: Text(
                          _register ? 'Sign in instead' : 'Create an account',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    semanticLabel: 'Email address',
                    key: const Key('auth-email'),
                    controller: _email,
                    onChanged: (_) => setState(() => _emailError = null),
                    placeholder: const ExcludeSemantics(
                      child: Text('Email address'),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) {
                      if (!_busy) _passwordFocus.requestFocus();
                    },
                    autofillHints: const <String>[AutofillHints.email],
                    enabled: !_busy,
                  ),
                  if (_emailError != null) _fieldError(_emailError!),
                  const SizedBox(height: 8),
                  TextField(
                    semanticLabel: 'Password',
                    key: const Key('auth-password'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    controller: _password,
                    onChanged: (_) => setState(() => _passwordError = null),
                    focusNode: _passwordFocus,
                    placeholder: const ExcludeSemantics(
                      child: Text('Password'),
                    ),
                    obscureText: true,
                    features: const <InputFeature>[
                      InputFeature.passwordToggle(),
                    ],
                    textInputAction: _register
                        ? TextInputAction.next
                        : TextInputAction.done,
                    autofillHints: <String>[
                      _register
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    enabled: !_busy,
                    onSubmitted: (_) {
                      if (_busy) return;
                      if (_register) {
                        _confirmationFocus.requestFocus();
                      } else {
                        _submit();
                      }
                    },
                  ),
                  if (_passwordError != null) _fieldError(_passwordError!),
                  if (_register) ...<Widget>[
                    const SizedBox(height: 8),
                    TextField(
                      semanticLabel: 'Confirm password',
                      key: const Key('auth-confirmation'),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      controller: _confirmation,
                      onChanged: (_) => setState(() => _confirmationError = null),
                      focusNode: _confirmationFocus,
                      placeholder: const ExcludeSemantics(
                        child: Text('Confirm password'),
                      ),
                      obscureText: true,
                      features: const <InputFeature>[
                        InputFeature.passwordToggle(),
                      ],
                      textInputAction: TextInputAction.done,
                      autofillHints: const <String>[AutofillHints.newPassword],
                      enabled: !_busy,
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_confirmationError != null) _fieldError(_confirmationError!),
                  ] else
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        density: ButtonDensity.normal,
                        onPressed: _busy ? null : _resetPassword,
                        child: const Text('Reset password'),
                      ),
                    ),
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Semantics(liveRegion: true, child: Text(_message!)),
                  ],
                  const SizedBox(height: 8),
                  PrimaryButton(
                    density: ButtonDensity.normal,
                    onPressed: _busy ? null : _submit,
                    child: Text(
                      _busy
                          ? 'Please wait...'
                          : (_register ? 'Create Account' : 'Sign In'),
                    ),
                  ),
                  if (_auth.supportsGoogleSignIn) ...<Widget>[
                    const SizedBox(height: 8),
                    SecondaryButton(
                      density: ButtonDensity.normal,
                      key: const Key('auth-google'),
                      onPressed: _busy
                          ? null
                          : () => _signInWithProvider(
                              SocialSignInProvider.google,
                            ),
                      child: const Text('Continue with Google'),
                    ),
                  ],
                  if (_auth.supportsAppleSignIn) ...<Widget>[
                    const SizedBox(height: 8),
                    ComponentTheme<SecondaryButtonTheme>(
                      data: SecondaryButtonTheme(
                        decoration:
                            (
                              BuildContext context,
                              Set<WidgetState> states,
                              Decoration decoration,
                            ) => (decoration as BoxDecoration).copyWith(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black,
                            ),
                        textStyle:
                            (
                              BuildContext context,
                              Set<WidgetState> states,
                              TextStyle style,
                            ) => style.copyWith(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.black
                                  : Colors.white,
                            ),
                        padding: (
                          BuildContext context,
                          Set<WidgetState> states,
                          EdgeInsetsGeometry padding,
                        ) => const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: SecondaryButton(
                        key: const Key('auth-apple'),
                        density: ButtonDensity.normal,
                        onPressed: _busy
                            ? null
                            : () => _signInWithProvider(
                                SocialSignInProvider.apple,
                              ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: ExcludeSemantics(
                                child: Image.asset(
                                  Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? 'assets/images/apple-sign-in-white.png'
                                      : 'assets/images/apple-sign-in-black.png',
                                  width: 32,
                                  height: 32,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: const Text('Continue with Apple'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Arcane.push<void>(
                            context,
                            const PrivacyDataScreen(
                              accountDeletionEnabled: accountDeletionEnabled,
                            ),
                          ),
                    child: const Text('Privacy & data'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class CollectorPasswordResetScreen extends StatefulWidget {
  const CollectorPasswordResetScreen({
    super.key,
    required this.auth,
    this.initialEmail = '',
    this.onClose,
  });
  final CollectorAuth auth;
  final String initialEmail;
  final VoidCallback? onClose;

  @override
  State<CollectorPasswordResetScreen> createState() =>
      _CollectorPasswordResetScreenState();
}

class _CollectorPasswordResetScreenState
    extends State<CollectorPasswordResetScreen> {
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail,
  );
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _sendReset() async {
    if (_busy) return;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      setState(
        () => _message = 'Enter a valid email address to reset your password.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.auth.resetPassword(_email.text.trim());
      if (mounted) {
        setState(
          () => _message =
              'If an account uses this email, a reset link has been sent.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = authFailureMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ComponentTheme<TextFieldTheme>(
            data: MyThemeData.inputTheme.copyWith(
              padding: () =>
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(children: <Widget>[
                  const CollectorBrandMark(size: 32),
                  const SizedBox(width: 12),
                  Flexible(child: Text('Reset password', style: Theme.of(context).typography.h2)),
                ]),
                const SizedBox(height: 12),
                TextField(
                  semanticLabel: 'Email address',
                  key: const Key('reset-email'),
                  controller: _email,
                  placeholder: const ExcludeSemantics(
                    child: Text('Email address'),
                  ),
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autofillHints: const <String>[AutofillHints.email],
                  onSubmitted: (_) => _sendReset(),
                ),
                if (_message != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_message!)),
                ],
                const SizedBox(height: 12),
                PrimaryButton(
                  density: ButtonDensity.normal,
                  onPressed: _busy ? null : _sendReset,
                  child: Text(_busy ? 'Please wait...' : 'Send reset link'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  density: ButtonDensity.normal,
                  onPressed: _busy ? null : widget.onClose ?? () => Navigator.of(context).pop(),
                  child: const Text('Back to sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
