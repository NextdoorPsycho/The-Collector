import 'dart:typed_data';

import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:foil/foil.dart';
import 'package:memcached/memcached.dart';
import 'package:scryfall_api/scryfall_api.dart';

ScryfallApiClient? _sf;

ScryfallApiClient sfClient() {
  if (_sf == null) {
    _sf = ScryfallApiClient();
    verbose("Initialized Scryfall API client");
  }
  return _sf!;
}

Future<Uint8List> getImage({
  required String id,
  ImageVersion size = ImageVersion.normal,
  bool back = true,
}) {
  String cacheKey = "card$id$back${size.index}";
  verbose("Fetching image with cache key: $cacheKey");
  return getCached(
    id: cacheKey,
    getter: () =>
        sfClient().getCardByIdAsImage(id, imageVersion: size, backFace: back),
    duration: const Duration(minutes: 5),
  );
}

class CardView extends StatelessWidget {
  final String id;
  final ImageVersion size;
  final bool back;
  final bool foil;
  final bool flat;
  final bool interactive;
  final bool interactive3D;

  const CardView({
    super.key,
    required this.id,
    this.interactive3D = true,
    this.interactive = false,
    this.size = ImageVersion.normal,
    this.back = false,
    this.foil = false,
    this.flat = true,
  }) : assert((interactive && !flat) || !interactive,
            "Interactive cards must be non-flat");

  Widget buildImage(BuildContext context, Uint8List bytes) {
    verbose("Building image widget");
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.8,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.memory(
          bytes,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            child = ClipRRect(
                borderRadius: BorderRadius.circular(20), child: child);
            if (wasSynchronouslyLoaded) {
              success("Image loaded synchronously");
              return child;
            }
            return AnimatedOpacity(
              child: child,
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 750),
              curve: Curves.easeInOutCirc,
            );
          },
        ),
      ),
    );
  }

  Widget interactiveWrap(BuildContext context, Widget child) {
    info("Wrapping image for interactive viewing");
    return interactive ? InteractiveViewer(minScale: 0.1, child: child) : child;
  }

  Widget wrap(BuildContext context, Widget child) {
    verbose("Applying foil effects");
    return Foil(
      isUnwrapped: !foil,
      opacity: 0.4,
      scalar: const Scalar(horizontal: 0.2, vertical: 0.2),
      child: Foil(
        isUnwrapped: !foil,
        opacity: 0.2,
        scalar: const Scalar(horizontal: 0.55, vertical: 0.55),
        gradient: Foils.linearLoopingReversed,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    info("Building main card view widget");
    return FutureBuilder<Uint8List>(
      future: getImage(id: id, size: size, back: back),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          success("Data fetched successfully");
          return interactiveWrap(
            context,
            !flat
                ? wrap(context, buildImage(context, snapshot.data!))
                : buildImage(context, snapshot.data!),
          );
        } else if (snapshot.hasError) {
          info("Error loading image: ${snapshot.error}");
          return Text('Error: ${snapshot.error}');
        }
        return const SizedBox.shrink();
      },
    );
  }
}
