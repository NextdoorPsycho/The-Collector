import 'package:fire_crud/fire_crud.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';

class HubDice extends StatefulWidget {
  const HubDice({
    super.key,
  });

  @override
  _HubDiceState createState() => _HubDiceState();
}

class _HubDiceState extends State<HubDice> {
  @override
  Widget build(BuildContext c) {
    return FireList(
        crud: Crud.card(u),
        builder: (context, card) {
          return InkWell(
            onTap: () => Crud.card(u).delete(card.id!),
            onLongPress: () => Crud.card(u).txn(
                card.id!,
                (data) => data.copyWith(
                      quantity: data.quantity + 1,
                    )),
            child: Container(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Card ID: ${card.id}, Name: ${card.name}',
                    style: const TextStyle(fontSize: 16.0),
                  ),
                  const SizedBox(height: 8.0),
                  Text(
                    'Quantity: ${card.quantity}',
                    style: const TextStyle(fontSize: 14.0),
                  ),
                ],
              ),
            ),
          );
        });
  }
}
