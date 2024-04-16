import 'package:flutter/material.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class DeckPage extends StatefulWidget {
  const DeckPage({super.key, required this.themeNotifier, this.deckId});

  final ValueNotifier<ThemeMode> themeNotifier;
  final String? deckId;

  @override
  State<DeckPage> createState() => _DeckPageState();
}

class _DeckPageState extends State<DeckPage> {
  int _currentIndex = 0;

  late ThemeMode _initialThemeMode;

  String get deckId => widget.deckId!;

  @override
  void initState() {
    super.initState();

    // Get the initial theme mode
    UserManager.streamTheme().first.then((isDark) {
      setState(() {
        _initialThemeMode = isDark ? ThemeMode.dark : ThemeMode.light;
        widget.themeNotifier.value = _initialThemeMode;
        // set the cards in a collection somehow
      });
    });
  }

  void changeTheme() {
    if (widget.themeNotifier.value == ThemeMode.light) {
      widget.themeNotifier.value = ThemeMode.dark;
      UserManager.updateTheme(isDark: true);
    } else {
      widget.themeNotifier.value = ThemeMode.light;
      UserManager.updateTheme(isDark: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UserManager.streamDeckById(deckId).build((deck) {
      return const Placeholder();
    });
  }
}
