import 'package:flutter/material.dart';
import 'package:magic_card/magic_card.dart';
import 'package:scryfall_api/scryfall_api.dart';

class FlapCard extends StatefulWidget {
  const FlapCard({super.key});

  @override
  _FlapCardState createState() => _FlapCardState();
}

class _FlapCardState extends State<FlapCard> {
  final apiClient = ScryfallApiClient();

  Future<MtgCard> getRandomCard() async {
    return await apiClient.getRandomCard();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MtgCard>(
      future: getRandomCard(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else {
          final randomCard = snapshot.data!;
          return Center(
            child: CardView(
              id: randomCard.id,
              back: false,
              foil: true,
              interactive3D: false,
              interactive: false,
            ),
          );
        }
      },
    );
  }
}
