import 'package:flutter/material.dart';
import 'package:flyout/flyout.dart';
import 'package:magic_card/magic_card.dart';
import 'package:padded/padded.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

class CardFlyoutScreen extends StatefulWidget {
  final MTGCard card;

  const CardFlyoutScreen({super.key, required this.card});

  @override
  State<CardFlyoutScreen> createState() => _CardFlyoutScreenState();
}

class _CardFlyoutScreenState extends State<CardFlyoutScreen> {
  int? quantity;

  @override
  void initState() {
    super.initState();
    initializeQuantity();
  }

  Future<void> initializeQuantity() async {
    final card = await Crud.card(u).get(widget.card.id!);
    setState(() {
      quantity = card.quantity;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Card Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            title: const Text('Quantity'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: quantity == null
                      ? null
                      : () {
                          if (quantity! <= 1) {
                            Crud.card(u).delete(widget.card.id!);
                            Navigator.of(context).pop();
                          } else {
                            Crud.card(u).txn(widget.card.id!, (card) {
                              setState(() {
                                quantity = quantity! - 1;
                              });
                              return card.copyWith(quantity: quantity);
                            });
                          }
                        },
                ),
                Text(quantity?.toString() ?? ''),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: quantity == null
                      ? null
                      : () {
                          Crud.card(u).txn(widget.card.id!, (card) {
                            setState(() {
                              quantity = quantity! + 1;
                            });
                            return card.copyWith(quantity: quantity);
                          });
                        },
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: flyoutController(context),
              children: [
                PaddingAll(
                  padding: 10,
                  child: CardView(
                    id: widget.card.id!,
                    back: false,
                    foil: false,
                    interactive3D: false,
                    interactive: false,
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
