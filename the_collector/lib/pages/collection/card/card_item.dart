import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flyout/flyout.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

Widget buildCardItem(MTGCard card, ScryfallApiClient apiClient) {
  return FutureBuilder<Uint8List>(
    future: apiClient.getCardByIdAsImage(card.id!,
        imageVersion: ImageVersion.small),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        // Loading screen
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        );
      } else if (snapshot.hasError) {
        return const Text('Error loading image');
      } else if (snapshot.hasData) {
        return InkWell(
          onTap: () => flyout(context, () => CardFlyoutScreen(card: card)),
          onLongPress: () {
            Crud.card(u).delete(card.id.toString());
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Image.memory(
                    snapshot.data!,
                    fit: BoxFit.cover,
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withOpacity(0.8),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          card.name,
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withOpacity(0.8),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          'Count: ${card.quantity}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        // Placeholder when no data is available
        return const Text('No data');
      }
    },
  );
}
