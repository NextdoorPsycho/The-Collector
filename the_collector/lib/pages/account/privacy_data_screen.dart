import 'package:arcane/arcane.dart';
import 'package:the_collector/utils/external_links.dart';
import 'package:the_collector/utils/scanning/cloud_scan_consent.dart';

class PrivacyDataScreen extends StatefulWidget {
  const PrivacyDataScreen({
    super.key,
    this.accountDeletionEnabled = false,
    this.privacyPolicyUrl = const String.fromEnvironment('PRIVACY_POLICY_URL'),
    this.openLink,
    this.cloudRecognitionEnabled = cloudCardHintsEnabled,
    this.embedded = false,
  });

  final bool accountDeletionEnabled;
  final String privacyPolicyUrl;
  final Future<void> Function(Uri)? openLink;
  final bool cloudRecognitionEnabled;
  final bool embedded;

  @override
  State<PrivacyDataScreen> createState() => _PrivacyDataScreenState();
}

class _PrivacyDataScreenState extends State<PrivacyDataScreen> {
  Uri? _privacyPolicyUri;
  String? _linkError;
  bool _openingLink = false;
  (String, String)? _topic;

  @override
  void initState() {
    super.initState();
    _privacyPolicyUri = _parsePrivacyPolicyUrl(widget.privacyPolicyUrl);
  }

  @override
  void didUpdateWidget(PrivacyDataScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.privacyPolicyUrl != widget.privacyPolicyUrl) {
      _privacyPolicyUri = _parsePrivacyPolicyUrl(widget.privacyPolicyUrl);
    }
  }

  Uri? _parsePrivacyPolicyUrl(String value) {
    if (value.isEmpty) return null;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError(
        'Privacy policy URL must use HTTPS with a host and no credentials.',
      );
    }
    return uri;
  }

  Future<void> _open(Uri uri) async {
    if (_openingLink) return;
    setState(() {
      _openingLink = true;
      _linkError = null;
    });
    try {
      await (widget.openLink ?? openCollectorLink)(uri);
    } catch (_) {
      if (mounted) {
        setState(() => _linkError = 'Could not open the link. Try again.');
      }
    } finally {
      if (mounted) setState(() => _openingLink = false);
    }
  }

  Widget _section(String title, String body) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Tile(
      title: Text(title),
      trailing: const Icon(Icons.caret_right, size: 16),
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 0),
      onPressed: () => setState(() => _topic = (title, body)),
    ),
  );

  Widget _link(String label, Uri uri) => MergeSemantics(
    child: Semantics(
      button: true,
      enabled: !_openingLink,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: TextButton(
          alignment: Alignment.centerLeft,
          onPressed: _openingLink ? null : () => _open(uri),
          child: Text(label),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    child: ListView(
      key: ValueKey<String>(_topic?.$1 ?? 'privacy-index'),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      children: <Widget>[
        if (_topic != null) ...<Widget>[
          Align(alignment: Alignment.centerRight, child: TextButton(
            key: const ValueKey<String>('privacy-topics'),
            onPressed: () => setState(() => _topic = null),
            child: const Text('Topics'),
          )),
          Semantics(header: true, child: Text(_topic!.$1,
            style: Theme.of(context).typography.large)),
          const SizedBox(height: 16),
          SelectableText(_topic!.$2),
        ] else ...<Widget>[
        if (!widget.embedded && Navigator.canPop(context))
          Align(alignment: Alignment.centerRight, child: IconButton(
            icon: const Icon(Icons.x, semanticLabel: 'Close privacy'),
            onPressed: () => Navigator.pop(context),
          )),
        if (_privacyPolicyUri != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _link('Privacy policy', _privacyPolicyUri!),
            ),
          ),
        _section(
          'Camera and recognition',
          widget.cloudRecognitionEnabled
              ? 'Camera previews, card detection, and text recognition run on your device. '
                    'Cloud recognition is off by default. If you allow it in Settings, '
                    'saved card crops are sent through Firebase to Google Cloud for image '
                    'transcription. Crops may include annotations or background details. '
                    'The app checks suggestions against Scryfall and keeps them for review. '
                    'Turning it off stops new uploads and ignores pending suggestions. '
                    'Photos already sent cannot be recalled. The callable does not store '
                    'the images; provider handling follows the provider policies.'
              : 'Camera previews, card detection, and text recognition run on your '
                    'device. The scanner does not upload your photos to Firebase or '
                    'Scryfall. Recognized card text is used for online printing lookups.',
        ),
        _section(
          'Photos and local drafts',
          'The scanner copies captured or chosen photos into its managed local '
              'draft storage so you can resume a batch. Original photos are retained '
              'while their cards still need review. Adding or discarding those cards '
              'schedules cleanup of their managed photos and crops; failed cleanup '
              'can retry later. Photos you chose from your gallery remain in your '
              'gallery. Temporary camera files may be removed after a draft copy '
              'has been saved.',
        ),
        _section(
          'Account and cloud data',
          'Firebase Authentication manages your sign-in account. Cloud '
              'Firestore stores your private collection, decks, preferences, and '
              'saved price history under your account. The app also keeps local '
              'caches and game state so some information is available without '
              'a connection.',
        ),
        _section(
          'Shared games',
          'Shared room data includes player names, life totals, membership, '
              'and game status. People who join a room can see and update its game '
              'state. Share room codes only with people you want to play with.',
        ),
        _section(
          'Card lookups and other services',
          'Scryfall receives card search queries and printing identifiers. The '
              'app retrieves card details, prices, rulings, and artwork from '
              'Scryfall. Artwork and symbol comparisons run locally using those '
              'retrieved images. Rules downloads and shop searches also contact '
              'their respective services. External links open outside the app.',
        ),
        _section(
          'Advertising and analytics',
          'The app has no advertising or app analytics features. Service '
              'providers may process connection, security, and other service data '
              'under their own policies.',
        ),
        if (widget.accountDeletionEnabled)
          _section(
            'Delete your account',
            'Delete account in Settings asks you to verify your sign-in before '
                'requesting deletion. This removes your account, collection, decks, '
                'cloud price history, drafts, and shared sessions you own, and '
                'removes your membership from joined sessions. Managed local '
                'account data and scan photos on this device are also cleared. '
                'Gallery originals are not deleted. Provider backup and log '
                'handling follows the provider policies linked below.',
          ),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            'Provider information',
            style: Theme.of(context).typography.small,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            _link(
              'Firebase privacy',
              Uri.https('firebase.google.com', '/support/privacy'),
            ),
            if (widget.cloudRecognitionEnabled)
              _link(
                'Google Cloud data handling',
                Uri.https(
                  'cloud.google.com',
                  '/vertex-ai/generative-ai/docs/data-governance',
                ),
              ),
            _link(
              'Scryfall API documentation',
              Uri.https('scryfall.com', '/docs/api'),
            ),
          ],
        ),
        if (_linkError != null) ...<Widget>[
          const SizedBox(height: 12),
          Semantics(liveRegion: true, child: Text(_linkError!)),
        ],
        ],
      ],
    ),
  );
}
