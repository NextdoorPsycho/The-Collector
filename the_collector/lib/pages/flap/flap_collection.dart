import 'package:flutter/material.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/data/user_manager.dart';

class FlapCollection extends StatefulWidget {
  const FlapCollection({
    super.key,
  });

  @override
  _FlapCollectionState createState() => _FlapCollectionState();
}

class _FlapCollectionState extends State<FlapCollection> {
  @override
  Widget build(BuildContext c) {
    return UserManager.streamCollection().build((collection) {
      Map<MtgCard, int> cards = collection ?? {};
      return Center(
        child: Text("Collection: $cards"),
      );
    });
  }
}
