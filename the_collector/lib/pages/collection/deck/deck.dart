import 'package:flutter/material.dart';
import 'package:flyout/flyout.dart';
import 'package:the_collector/utils/data/deck/mtg_deck.dart';

class DeckFlyoutScreen extends StatelessWidget {
  const DeckFlyoutScreen({Key? key, required MTGDeck deck}) : super(key: key);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(
          // Scrolling will move the flyout and the scroller
          controller: flyoutController(context),
          children: const [],
        ),
      );
}
