import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/user/app_user_restricted.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/main.dart';
import 'package:the_collector/pages/account/account_deletion_dialog.dart';
import 'package:the_collector/pages/account/privacy_data_screen.dart';
import 'package:the_collector/pages/admin/admin.dart';
import 'package:the_collector/utils/auth/account_deletion.dart';
import 'package:the_collector/utils/auth/local_account_data.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';
import 'package:the_collector/utils/scanning/cloud_scan_consent.dart';
import 'package:the_collector/utils/scanning/cloud_card_hints_service.dart';

enum _SettingsTopic { appearance, scanning, tabletop, account }

class HubSettings extends StatefulWidget {
  const HubSettings({
    super.key,
    this.auth,
    this.cloudConsent,
    this.cloudHints,
    this.userId,
    this.cloudRecognitionEnabled = cloudCardHintsEnabled,
  });

  final CollectorAuth? auth;
  final CloudScanConsentStore? cloudConsent;
  final CloudCardHintsService? cloudHints;
  final String? userId;
  final bool cloudRecognitionEnabled;

  @override
  State<HubSettings> createState() => _HubSettingsState();
}

class _HubSettingsState extends State<HubSettings> {
  _SettingsTopic? _topic;
  bool _signingOut = false;
  bool _saving = false;
  String? _saveError;
  bool _cloudGranted = false;
  bool _cloudLoading = true;
  bool _cloudSaving = false;
  String? _cloudOwner;
  int _cloudGeneration = 0;
  CloudScanConsentStore get _cloudConsent =>
      widget.cloudConsent ?? CloudScanConsentStore.instance;
  CloudCardHintsService get _cloudHints => widget.cloudHints ?? CloudCardHintsService.instance;

  @override
  void initState() {
    super.initState();
    if (widget.cloudRecognitionEnabled) {
      _loadCloudConsent();
      unawaited(_cloudHints.checkAvailability(force: true));
    }
  }

  @override
  void didUpdateWidget(HubSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cloudRecognitionEnabled &&
        (oldWidget.userId != widget.userId ||
            oldWidget.cloudConsent != widget.cloudConsent ||
            oldWidget.cloudHints != widget.cloudHints ||
            !oldWidget.cloudRecognitionEnabled)) {
      _loadCloudConsent();
      unawaited(_cloudHints.checkAvailability(force: true));
    }
  }

  Future<void> _loadCloudConsent() async {
    final int generation = ++_cloudGeneration;
    _cloudGranted = false;
    _cloudLoading = true;
    try {
      final String owner = widget.userId ?? u;
      _cloudOwner = owner;
      final bool granted = await _cloudConsent.isGranted(owner);
      if (mounted && generation == _cloudGeneration && owner == _cloudOwner) {
        setState(() {
          _cloudGranted = granted;
          _cloudLoading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _cloudGeneration) {
        setState(() => _cloudLoading = false);
      }
    }
  }

  Future<void> _setCloudConsent(bool value) async {
    final String? owner = _cloudOwner;
    if (owner == null || _cloudSaving || _cloudLoading || _signingOut) return;
    if (value && !_cloudHints.status.value.canEnable) return;
    final int generation = _cloudGeneration;
    final CloudScanConsentStore consent = _cloudConsent;
    setState(() {
      _cloudSaving = true;
      _saveError = null;
      _cloudGranted = false;
    });
    try {
      await consent.setGranted(owner, value);
      final bool granted = await consent.isGranted(owner);
      if (mounted && generation == _cloudGeneration && _cloudOwner == owner) {
        setState(() => _cloudGranted = granted);
      }
    } catch (_) {
      if (mounted && generation == _cloudGeneration) {
        setState(
          () => _saveError = 'Cloud assistance is off. Preference not saved.',
        );
      }
    } finally {
      if (mounted) setState(() => _cloudSaving = false);
    }
  }

  Future<void> _savePreference(String field, bool value) async {
    if (_saving || _signingOut) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      LocalAccountData.requireWritable(u);
      await Crud.user().collection.doc(u).update(<String, Object?>{
        field: value,
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _saveError = 'Could not save your preference. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    final String? owner = _cloudOwner;
    if (widget.cloudRecognitionEnabled && owner != null) {
      _cloudConsent.suspend(owner);
    }
    await SignOutManager.signOut(context, auth: widget.auth);
    if (widget.cloudRecognitionEnabled && owner != null) {
      _cloudConsent.resume(owner);
    }
    if (mounted) setState(() => _signingOut = false);
  }

  void _openTopic(_SettingsTopic topic) => setState(() {
    _topic = topic;
    _saveError = null;
  });

  Widget _indexRow(String title, {String? detail, required VoidCallback? open}) => Container(
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.border))),
    child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: Tile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: detail == null ? null : Text(detail, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.caret_right, size: 16),
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 0),
      onPressed: open,
    )),
  );

  Widget _toggle({required String label, required bool value,
      required ValueChanged<bool>? change, Key? key}) => MergeSemantics(
    child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: Tile(
      title: Text(label),
      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 0),
      onPressed: change == null ? null : () => change(!value),
      trailing: Switch(key: key, value: value, onChanged: change),
    )),
  );

  Widget _cloud() => ValueListenableBuilder<CloudCardHintsStatus>(
    valueListenable: _cloudHints.status,
    builder: (BuildContext context, CloudCardHintsStatus status, Widget? child) {
      final bool canToggle = !_cloudLoading && !_cloudSaving && !_signingOut &&
          (_cloudGranted || status.canEnable);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        _toggle(
          key: const ValueKey<String>('cloud-recognition-consent'),
          label: 'Cloud text assistance', value: _cloudGranted,
          change: canToggle ? _setCloudConsent : null,
        ),
        Semantics(liveRegion: true, child: Text(status.message,
          key: const ValueKey<String>('cloud-assistance-status'), style: const TextStyle(fontSize: 13))),
        const SizedBox(height: 8),
        const Text('Saved crops go to Google Cloud. Review suggestions.', style: TextStyle(fontSize: 13)),
        if (!status.canEnable && status.availability != CloudCardHintsAvailability.checking)
          Align(alignment: Alignment.centerLeft, child: TextButton(
            key: const ValueKey<String>('cloud-assistance-check'),
            onPressed: _cloudLoading || _signingOut ? null :
                () => unawaited(_cloudHints.checkAvailability(force: true)),
            child: const Text('Check status'),
          )),
      ]);
    },
  );

  Widget _signOutAction() => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 44),
    child: TextButton(
      alignment: Alignment.centerLeft,
      onPressed: _signingOut ? null : _signOut,
      child: Text(_signingOut ? 'Signing out…' : 'Sign Out'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final AppUser? profile = Provider.of<AppUser?>(context);
    final bool administrator = context.watch<AppUserRestricted?>()?.admin ?? false;
    final bool editable = !_signingOut && !_saving && profile != null;
    final _SettingsTopic? topic = _topic;
    return Scaffold(child: ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: <Widget>[
        if (topic == null) ...<Widget>[
          _indexRow('Appearance', detail: profile?.theme == true ? 'Light' : 'Dark',
            open: () => _openTopic(_SettingsTopic.appearance)),
          if (widget.cloudRecognitionEnabled)
            _indexRow('Scanning', open: () => _openTopic(_SettingsTopic.scanning)),
          _indexRow('Tabletop', detail: profile?.showCommander == true ? 'Commander on' : null,
            open: () => _openTopic(_SettingsTopic.tabletop)),
          _indexRow('Account', open: () => _openTopic(_SettingsTopic.account)),
          _indexRow('Privacy & data', open: () => Arcane.push<void>(context,
            const PrivacyDataScreen(accountDeletionEnabled: accountDeletionEnabled))),
          if (administrator)
            _indexRow('Administration', open: _signingOut ? null :
              () => Arcane.push<void>(context, const AdminHub())),
          const SizedBox(height: 12),
          _signOutAction(),
        ] else ...<Widget>[
          Row(children: <Widget>[
            Expanded(child: Semantics(header: true, child: Text(switch (topic) {
              _SettingsTopic.appearance => 'Appearance',
              _SettingsTopic.scanning => 'Scanning',
              _SettingsTopic.tabletop => 'Tabletop',
              _SettingsTopic.account => 'Account',
            }, style: Theme.of(context).typography.large))),
            TextButton(
              key: const ValueKey<String>('settings-topics'),
              onPressed: () => setState(() => _topic = null),
              child: const Text('Done'),
            ),
          ]),
          const SizedBox(height: 12),
          if (topic == _SettingsTopic.appearance)
            _toggle(label: 'Light theme', value: profile?.theme ?? false,
              change: editable ? (bool value) => _savePreference('theme', value) : null),
          if (topic == _SettingsTopic.tabletop)
            _toggle(label: 'Commander', value: profile?.showCommander ?? false,
              change: editable ? (bool value) => _savePreference('showCommander', value) : null),
          if (topic == _SettingsTopic.scanning && widget.cloudRecognitionEnabled) _cloud(),
          if (topic == _SettingsTopic.account) ...<Widget>[
            if (widget.userId != null || profile?.id != null) ...<Widget>[
              const Text('Account ID', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(widget.userId ?? profile!.id!),
              const SizedBox(height: 16),
            ],
            _signOutAction(),
            if (accountDeletionEnabled)
              TextButton(
                alignment: Alignment.centerLeft,
                onPressed: _signingOut || _saving ? null : () {
                  final String owner = widget.userId ?? u;
                  showAccountDeletionDialog(context,
                    auth: widget.auth ?? FirebaseCollectorAuth.instance,
                    requestDeletion: () => AccountDeletionController.instance.request(owner));
                },
                child: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.destructive)),
              ),
          ],
          if (_saveError != null) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_saveError!)),
          ],
        ],
      ],
    ));
  }
}
