import 'package:flutter/material.dart';
import 'package:xl/xl.dart';

class TradingCard extends StatelessWidget {
  const TradingCard({
    Key? key,
    required this.card,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(75.0),
    this.borderRadius = 10.0,
  }) : super(key: key);

  /// A `String` representing a url leading to an image.
  final String card;

  /// Constrain the dimensions of this `TradingCard`.
  final double? width, height;

  /// Pad this `TradingCard` so a `Foil` that wraps it may have extra room
  /// in the gradient shader to accommodate this widget's [XL] as it transforms.
  final EdgeInsets padding;

  /// The border radius of the rounded corners.
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final image = Image.network(
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
        child: XL(
          sharesPointer: false,
          duration: const Duration(milliseconds: 150),
          layers: [
            XLayer(
              dimensionalOffset: 0.002,
              xOffset: 75,
              yOffset: 75,
              xRotation: 1,
              yRotation: 0.6,
              zRotationByX: 0.5,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(borderRadius),
                  child: image,
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
