import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:the_collector/pages/collection/collection_cards.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/collection/collection_prices.dart';
import 'package:the_collector/pages/collection/moxfield_import_screen.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/pages/dock/hub_more.dart';
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/utils/crud.dart';

enum CollectorWorkspace { cards, containers, scan, tabletop, more }

class CollectorHub extends StatefulWidget {
  const CollectorHub({
    super.key,
    this.initialWorkspace = CollectorWorkspace.cards,
    this.cards,
    this.containers,
    this.scanner,
    this.tabletop,
    this.more,
  });

  final CollectorWorkspace initialWorkspace;
  final Widget? cards;
  final Widget? containers;
  final Widget? scanner;
  final Widget? tabletop;
  final Widget? more;

  @override
  State<CollectorHub> createState() => _CollectorHubState();
}

class _CollectorHubState extends State<CollectorHub> {
  late int _currentIndex = widget.initialWorkspace.index;
  late final Set<int> _visited = <int>{_currentIndex};
  MTGDeck? _scanDestination;
  String? _openContainerId;
  static const List<(IconData, String)> _destinations = <(IconData, String)>[
    (Icons.cards, 'Cards'),
    (Icons.archive, 'Containers'),
    (Icons.camera, 'Scan'),
    (Icons.dice_six, 'Tabletop'),
    (Icons.dots_three, 'More'),
  ];

  void _select(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _visited.add(index);
      _currentIndex = index;
    });
  }

  void _value(List<MTGCard>? scope) => openCollectorUtility(
    context,
    CollectionPrices(cardIds: scope?.map((MTGCard card) => card.id!).toSet()),
  );

  Future<void> _scanInto(MTGDeck group) async {
    setState(() => _scanDestination = group);
    _select(CollectorWorkspace.scan.index);
  }

  Future<void> _import(String? parentId) async {
    final String? userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    final String? created = await Arcane.push<String>(
      context,
      MoxfieldImportScreen(groups: Crud.deck(userId), parentId: parentId),
    );
    if (!mounted || created == null) return;
    setState(() => _openContainerId = created);
    _select(CollectorWorkspace.containers.index);
  }

  Widget _content(int index) => switch (CollectorWorkspace.values[index]) {
    CollectorWorkspace.cards =>
      widget.cards ??
          CollectionCards(active: _currentIndex == index, onValue: _value),
    CollectorWorkspace.containers =>
      widget.containers ??
          CollectionDecks(
            active: _currentIndex == index,
            onImport: _import,
            onScan: _scanInto,
            openGroupId: _openContainerId,
          ),
    CollectorWorkspace.scan =>
      widget.scanner ??
          ScanScreen(
            userId: u,
            openCamera: true,
            active: _currentIndex == index,
            destination: _scanDestination,
          ),
    CollectorWorkspace.tabletop => widget.tabletop ?? const HubDice(),
    CollectorWorkspace.more => widget.more ?? const HubMore(),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    footers: <Widget>[
      CollectorDock(
        selectedIndex: _currentIndex,
        items: <CollectorDockItem>[
          for (int index = 0; index < _destinations.length; index++)
            CollectorDockItem(
              icon: _destinations[index].$1,
              label: _destinations[index].$2,
              onPressed: () => _select(index),
            ),
        ],
      ),
    ],
    child: IndexedStack(
      index: _currentIndex,
      children: <Widget>[
        for (int index = 0; index < CollectorWorkspace.values.length; index++)
          TickerMode(
            enabled: _currentIndex == index,
            child: _visited.contains(index)
                ? _content(index)
                : const SizedBox.shrink(),
          ),
      ],
    ),
  );
}
