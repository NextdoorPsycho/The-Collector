import 'package:flutter/widgets.dart';

import 'card_effects.dart';

class TradingCard extends StatelessWidget {
  const TradingCard({
    super.key,
    required this.card,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(75.0),
    this.borderRadius = 10.0,
  });

  /// A `String` representing a url leading to an image.
  final String card;

  /// Constrain the dimensions of this `TradingCard`.
  final double? width, height;

  /// Space around the card to accommodate its transforms.
  final EdgeInsets padding;

  /// The border radius of the rounded corners.
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final Image image = Image.network(
      card,
      frameBuilder: (_, child, currentFrame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: currentFrame == null ? 0 : 1,
          duration: const Duration(milliseconds: 500),
          curve: Curves.ease,
          child: child,
        );
      },
    );

    return Padding(
      padding: padding,
      child: SizedBox(
        width: width ?? MediaQuery.of(context).size.width,
        height: height ?? MediaQuery.of(context).size.height,
        child: CardEffects(
          parallax: true,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: image,
            ),
          ),
        ),
      ),
    );
  }
}
