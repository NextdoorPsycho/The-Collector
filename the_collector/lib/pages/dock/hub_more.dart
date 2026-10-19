import 'package:arcane/arcane.dart';
import 'package:the_collector/pages/account/privacy_data_screen.dart';
import 'package:the_collector/pages/collection/collection_shops.dart';
import 'package:the_collector/pages/dock/hub_rules.dart';
import 'package:the_collector/pages/dock/hub_settings.dart';
import 'package:the_collector/utils/auth/account_deletion.dart';

void openCollectorUtility(BuildContext context, Widget child) {
  Arcane.push<void>(context, _UtilityPage(child: child));
}

class _UtilityPage extends StatelessWidget {
  const _UtilityPage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    headers: <Widget>[
      Align(
        alignment: Alignment.centerRight,
        child: SizedBox.square(
          dimension: 44,
          child: IconButton(
            icon: const Icon(Icons.x, size: 18, semanticLabel: 'Close'),
            variance: ButtonVariance.ghost,
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ),
    ],
    child: child,
  );
}

class HubMore extends StatelessWidget {
  const HubMore({
    super.key,
    this.rules,
    this.settings,
    this.privacy,
    this.shops,
  });
  final Widget? rules;
  final Widget? settings;
  final Widget? privacy;
  final Widget? shops;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    children: <Widget>[
      for (final (String, IconData, Widget) item
          in <(String, IconData, Widget)>[
            ('Rules', Icons.book_open, rules ?? const HubRules()),
            ('Settings', Icons.gear, settings ?? const HubSettings()),
            (
              'Privacy & data',
              Icons.lock,
              privacy ??
                  const PrivacyDataScreen(
                    accountDeletionEnabled: accountDeletionEnabled,
                    embedded: true,
                  ),
            ),
            ('Shops', Icons.storefront, shops ?? const CollectionShops()),
          ])
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Button(
            key: ValueKey<String>('more-${item.$1}'),
            style: const ButtonStyle.ghost(),
            onPressed: () => openCollectorUtility(context, item.$3),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: <Widget>[
                  Icon(item.$2, size: 20),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(item.$1, style: const TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
