import 'package:flutter/material.dart';
import 'package:the_collector/pages/collection/collection.dart';
import 'package:the_collector/utils/data/user_manager.dart';
import 'package:toastification/toastification.dart';

class AutoSignInPage extends StatefulWidget {
  const AutoSignInPage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<AutoSignInPage> createState() => _AutoSignInPageState();
}

class _AutoSignInPageState extends State<AutoSignInPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _opacityAnimation;
  bool _showLoadingScreen = true;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1),
    );
    _opacityAnimation =
        Tween<double>(begin: 2.0, end: 0.0).animate(_animationController);
    _autoSignIn();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _autoSignIn() async {
    changeTheme();

    // Start the fade-out animation
    await _animationController.forward();

    // Set the flag to hide the loading screen
    setState(() {
      _showLoadingScreen = false;
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
    ThemeData theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      body: Stack(
        children: [
          // Load the actual app behind the screen
          ToastificationConfigProvider(
            config: const ToastificationConfig(
              itemWidth: 500,
              animationDuration: Duration(milliseconds: 500),
            ),
            child: CollectionHub(themeNotifier: widget.themeNotifier),
          ),
        ],
      ),
    );
  }
}
