import 'package:arcane/arcane.dart';

import 'color.dart';

class MyThemeData {
  const MyThemeData._();

  static ArcaneTheme themeData(ThemeMode mode) => ArcaneTheme(
    themeMode: mode,
    radius: 0,
    surfaceOpacity: 1,
    surfaceOpacityLight: 1,
    surfaceEffect: const StaticSurfaceEffect(),
    shadThemeBuilder: (ArcaneTheme theme, Brightness brightness) => ThemeData(
      colorScheme: theme.scheme!.scheme(brightness),
      radius: theme.radius,
      typography: const Typography.geist(
        sans: TextStyle(fontFamily: 'GeistSans', package: 'arcane'),
        mono: TextStyle(fontFamily: 'GeistMono', package: 'arcane'),
        h1: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        h2: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
    ),
    scheme: ContrastedColorScheme(
      light: ColorSchemes.lightDefaultColor.copyWith(
        background: () => MyColors.backgroundColor,
        card: () => MyColors.cardBackground,
        primary: () => Colors.black,
        primaryForeground: () => Colors.white,
        destructive: () => MyColors.red5,
        mutedForeground: () => const Color(0xff4a4a4a),
        border: () => const Color(0xff737373),
        ring: () => Colors.black,
      ),
      dark: ColorSchemes.darkDefaultColor.copyWith(
        background: () => MyColors.darkBackgroundColor,
        card: () => MyColors.darkCardBackground,
        primary: () => Colors.white,
        primaryForeground: () => Colors.black,
        destructive: () => MyColors.red2,
        border: () => const Color(0xff737373),
        ring: () => Colors.white,
      ),
    ),
  );

  static const TextFieldTheme inputTheme = TextFieldTheme(
    filled: false,
    border: Border.fromBorderSide(BorderSide(color: Color(0xff737373))),
    borderRadius: BorderRadius.zero,
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );
}
