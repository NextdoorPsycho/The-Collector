import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';

class CardThumbnail extends StatelessWidget {
  const CardThumbnail({super.key, required this.card, this.width = 42});

  final MTGCard card;
  final double width;

  @override
  Widget build(BuildContext context) {
    final double height = width * 7 / 5;
    final Widget unavailable = SizedBox(
      width: width,
      height: height,
      child: const Center(child: Icon(Icons.cards, size: 20)),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: card.imageUrl == null
            ? unavailable
            : Image.network(
                card.imageUrl!,
                width: width,
                height: height,
                fit: BoxFit.cover,
                cacheWidth: 180,
                errorBuilder: (
                  BuildContext context,
                  Object error,
                  StackTrace? stack,
                ) => unavailable,
              ),
      ),
    );
  }
}
