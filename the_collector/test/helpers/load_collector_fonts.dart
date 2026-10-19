import 'package:flutter/services.dart';

Future<void> loadCollectorFonts() async {
  final FontLoader sans = FontLoader('packages/arcane/GeistSans');
  for (final String weight in <String>['Regular', 'Medium', 'SemiBold']) {
    sans.addFont(
      rootBundle.load('packages/arcane/resources/fonts/Geist-$weight.otf'),
    );
  }
  final FontLoader icons = FontLoader('packages/arcane/Phosphor')
    ..addFont(rootBundle.load('packages/arcane/fonts/Phosphor.ttf'));
  await Future.wait(<Future<void>>[sans.load(), icons.load()]);
}
