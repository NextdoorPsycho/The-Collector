import 'package:arcane/arcane.dart';
import 'package:the_collector/utils/external_links.dart';

class CollectionShops extends StatefulWidget {
  const CollectionShops({super.key, this.openLink});
  final Future<void> Function(Uri)? openLink;
  @override
  State<CollectionShops> createState() => _CollectionShopsState();
}

class _CollectionShopsState extends State<CollectionShops> {
  final TextEditingController _location = TextEditingController();
  String? _error;
  bool _opening = false;

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    if (_opening) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await (widget.openLink ?? openCollectorLink)(uri);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open the shop search. Try again.');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    child: SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              semanticLabel: 'City or postal code',
              controller: _location,
              enabled: !_opening,
              placeholder: const ExcludeSemantics(
                child: Text('City or postal code'),
              ),
              onSubmitted: (_) => _open(shopSearchUri(_location.text)),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              onPressed: _opening ? null : () => _open(shopSearchUri(_location.text)),
              child: Text(_opening ? 'Opening…' : 'Find card shops'),
            ),
            const SizedBox(height: 16),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: Tile(
              title: const Text('Wizards Store & Event Locator'),

              trailing: const Icon(Icons.arrow_up_right),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: _opening ? null : () => _open(Uri.parse('https://locator.wizards.com/')),
            )),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: Text(_error!)),
            ],
          ],
        ),
      ),
    ),
  );
}
