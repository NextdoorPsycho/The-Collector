import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/src/components/overlay/dialog.dart'
    show showDialog;
import 'package:flutter/services.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';

Future<void> showAccountDeletionDialog(
  BuildContext context, {
  required CollectorAuth auth,
  required Future<void> Function() requestDeletion,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) =>
        AccountDeletionDialog(auth: auth, requestDeletion: requestDeletion),
  );
}

class AccountDeletionDialog extends StatefulWidget {
  const AccountDeletionDialog({
    super.key,
    required this.auth,
    required this.requestDeletion,
  });

  final CollectorAuth auth;
  final Future<void> Function() requestDeletion;

  @override
  State<AccountDeletionDialog> createState() => _AccountDeletionDialogState();
}

class _AccountDeletionDialogState extends State<AccountDeletionDialog> {
  final TextEditingController _password = TextEditingController();
  final FocusNode _confirmationFocus = FocusNode();
  bool _busy = false;
  bool _manualAppleRevocation = false;
  String? _error;
  String _progress = 'Verifying account…';

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _confirmationFocus.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_busy) return;
    if (!_manualAppleRevocation &&
        widget.auth.deletionRequiresPassword &&
        _password.text.isEmpty) {
      setState(() => _error = 'Enter your password to verify this account.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Verifying account…';
    });
    bool verified = _manualAppleRevocation;
    try {
      if (!_manualAppleRevocation) {
        final DeletionVerification verification = await widget.auth
            .reauthenticateForDeletion(password: _password.text);
        if (!mounted) return;
        _password.clear();
        verified = true;
        if (verification == DeletionVerification.manualAppleRevocation) {
          setState(() => _manualAppleRevocation = true);
          _confirmationFocus.unfocus();
          return;
        }
      }
      setState(() => _progress = 'Deleting account…');
      await widget.requestDeletion();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _manualAppleRevocation = false;
          _error = verified
              ? 'Could not delete your account. Check your connection and retry.'
              : authFailureMessage(error) ??
                    'Verification canceled. Your account has not been deleted.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: ArcaneDialog(
      title: const Text('Delete account'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Permanently delete your account, collection, decks, cloud history, '
            'drafts, and shared sessions you own. You will be removed from '
            'shared sessions you joined. This cannot be undone.',
          ),
          const SizedBox(height: 16),
          if (_manualAppleRevocation) ...<Widget>[
            Semantics(
              liveRegion: true,
              child: const Text(
                'Apple access may remain. You can still delete your '
                'account and its data.',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'After deletion, open Settings on your iPhone or iPad, select '
              'your Apple Account, then Sign in with Apple. Select The Collector '
              'and stop using Sign in with Apple. You can also manage this '
              'access at account.apple.com.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Try verification again, or '
              'confirm below to delete your account now.',
            ),
          ] else if (widget.auth.deletionRequiresPassword) ...<Widget>[
            const Text('Verify with your current password.'),
            const SizedBox(height: 8),
            TextField(
              key: const Key('deletion-password'),
              controller: _password,
              semanticLabel: 'Current password',
              placeholder: const ExcludeSemantics(
                child: Text('Current password'),
              ),
              obscureText: true,
              enabled: !_busy,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_busy) _confirmationFocus.requestFocus();
              },
            ),
          ] else
            const Text('Verify with your sign-in provider to continue.'),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_error!)),
          ],
          if (_busy) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_progress)),
          ],
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              MergeSemantics(
                child: Semantics(
                  button: true,
                  enabled: !_busy,
                  child: OutlineButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              if (_manualAppleRevocation)
                MergeSemantics(
                  child: Semantics(
                    button: true,
                    enabled: !_busy,
                    child: OutlineButton(
                      key: const Key('retry-apple-revocation'),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _manualAppleRevocation = false;
                              _error = null;
                            }),
                      child: const Text('Try verification again'),
                    ),
                  ),
                ),
              MergeSemantics(
                child: Semantics(
                  button: true,
                  enabled: !_busy,
                  child: PrimaryButton(
                    key: const Key('confirm-account-deletion'),
                    focusNode: _confirmationFocus,
                    onPressed: _busy ? null : _delete,
                    child: Text(
                      _manualAppleRevocation
                          ? 'Continue with deletion'
                          : 'Delete my account',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
