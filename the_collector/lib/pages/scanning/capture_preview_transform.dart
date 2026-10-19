import 'package:arcane/arcane.dart';

class CapturePreviewTransform {
  CapturePreviewTransform({
    required this.sourceSize,
    required this.viewportSize,
    this.fit = BoxFit.cover,
  }) {
    final FittedSizes sizes = applyBoxFit(fit, sourceSize, viewportSize);
    sourceRect = Alignment.center.inscribe(
      sizes.source,
      Offset.zero & sourceSize,
    );
    destinationRect = Alignment.center.inscribe(
      sizes.destination,
      Offset.zero & viewportSize,
    );
  }

  final Size sourceSize;
  final Size viewportSize;
  final BoxFit fit;
  late final Rect sourceRect;
  late final Rect destinationRect;

  Offset project(Offset normalizedPoint) => Offset(
    destinationRect.left +
        (normalizedPoint.dx * sourceSize.width - sourceRect.left) *
            destinationRect.width /
            sourceRect.width,
    destinationRect.top +
        (normalizedPoint.dy * sourceSize.height - sourceRect.top) *
            destinationRect.height /
            sourceRect.height,
  );

  Offset normalizedTap(Offset point) => Offset(
    ((sourceRect.left +
                (point.dx - destinationRect.left) *
                    sourceRect.width /
                    destinationRect.width) /
            sourceSize.width)
        .clamp(0, 1),
    ((sourceRect.top +
                (point.dy - destinationRect.top) *
                    sourceRect.height /
                    destinationRect.height) /
            sourceSize.height)
        .clamp(0, 1),
  );
}
