import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import 'color.dart';

class MyThemeData {
  const MyThemeData._();

  static final _baseColorScheme = ColorScheme.fromSwatch(
    primarySwatch: MyColors.primarySwatchColor,
    accentColor: MyColors.defaultAccent,
    errorColor: MyColors.red5,
  );

  static ThemeData themeData(Brightness brightness) {
    bool isLight = brightness == Brightness.light;

    var colorScheme = _baseColorScheme.copyWith(
      brightness: brightness,
      background:
          isLight ? MyColors.backgroundColor : MyColors.darkBackgroundColor,
      surface: isLight ? MyColors.cardBackground : MyColors.darkCardBackground,
      onBackground: isLight ? Colors.black : Colors.white,
      onSurface: isLight ? Colors.black : Colors.white,
    );

    return ThemeData(
      brightness: brightness,
      primaryColor: colorScheme.primary,
      hintColor: colorScheme.secondary,
      backgroundColor: colorScheme.background,
      scaffoldBackgroundColor: colorScheme.background,
      cardColor: colorScheme.surface,
      dialogBackgroundColor: colorScheme.background,
      colorScheme: colorScheme,
      appBarTheme: appBarTheme(isLight, colorScheme),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: MyColors.defaultAccent,
      ),
      tabBarTheme: TabBarTheme(
        labelColor: colorScheme.onSurface,
        unselectedLabelColor: colorScheme.onBackground.withOpacity(0.5),
      ),
      textTheme: getTextTheme(colorScheme),
      buttonTheme: ButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      inputDecorationTheme: inputDecorationTheme(isLight),
      switchTheme: switchThemeData(isLight),
      checkboxTheme: checkboxThemeData(isLight),
      radioTheme: radioThemeData(isLight),
    );
  }

  static AppBarTheme appBarTheme(bool isLight, ColorScheme colorScheme) =>
      AppBarTheme(
        elevation: 1,
        backgroundColor: colorScheme.background,
        foregroundColor: colorScheme.onBackground,
        systemOverlayStyle:
            isLight ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        titleTextStyle: getTextTheme(colorScheme).headlineSmall,
        iconTheme: IconThemeData(color: colorScheme.onBackground),
        actionsIconTheme: IconThemeData(color: colorScheme.onBackground),
      );

  static TextTheme getTextTheme(ColorScheme colorScheme) => TextTheme(
        displayLarge: TextStyle(
            fontSize: 26,
            color: colorScheme.onBackground,
            fontWeight: FontWeight.bold),
        // Define other styles similarly
      );

  static InputDecorationTheme inputDecorationTheme(bool isLight) =>
      InputDecorationTheme(
        filled: true,
        fillColor: isLight ? MyColors.button : MyColors.darkButton,
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: Colors.transparent),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: MyColors.defaultAccent),
        ),
      );

  static SwitchThemeData switchThemeData(bool isLight) => SwitchThemeData(
        thumbColor: MaterialStateProperty.resolveWith<Color>(
            (Set<MaterialState> states) {
          if (states.contains(MaterialState.disabled)) return Colors.grey;
          return isLight ? MyColors.defaultAccent : Colors.white;
        }),
        trackColor: MaterialStateProperty.resolveWith<Color>(
            (Set<MaterialState> states) {
          if (states.contains(MaterialState.disabled)) {
            return Colors.grey.shade300;
          }
          return isLight ? MyColors.defaultAccent : MyColors.dark2;
        }),
      );

  static CheckboxThemeData checkboxThemeData(bool isLight) => CheckboxThemeData(
        fillColor: MaterialStateProperty.resolveWith<Color>(
            (Set<MaterialState> states) {
          if (states.contains(MaterialState.disabled)) return Colors.grey;
          return isLight ? MyColors.defaultAccent : Colors.white;
        }),
      );

  static RadioThemeData radioThemeData(bool isLight) => RadioThemeData(
        fillColor: MaterialStateProperty.resolveWith<Color>(
            (Set<MaterialState> states) {
          if (states.contains(MaterialState.disabled)) return Colors.grey;
          return isLight ? MyColors.defaultAccent : Colors.white;
        }),
      );
}
