import 'dart:math';

import 'package:flutter/material.dart';
import 'package:the_collector/pages/adw_home.dart';
import 'package:the_collector/pages/screen_templates/template_simple.dart';

class AutoSignInPage extends StatefulWidget {
  const AutoSignInPage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<AutoSignInPage> createState() => _AutoSignInPageState();
}

class _AutoSignInPageState extends State<AutoSignInPage> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _opacityAnimation;
  bool _showLoadingScreen = true;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _opacityAnimation = Tween<double>(begin: 2.0, end: 0.0).animate(_animationController);
    _autoSignIn();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _autoSignIn() async {
    // Simulate a delay to show the loading screen
    await Future.delayed(const Duration(milliseconds: 500));

    // Start the fade-out animation
    await _animationController.forward();

    // Set the flag to hide the loading screen
    setState(() {
      _showLoadingScreen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      body: Stack(
        children: [
          // Load the actual app behind the screen
          AdwHomePage(themeNotifier: widget.themeNotifier),
          // Conditionally show the loading screen based on the flag
          if (_showLoadingScreen)
            FadeTransition(
              opacity: _opacityAnimation,
              child: Center(
                child: Container(
                  color: theme.colorScheme.background,
                  child: SimpleScreen(
                    image: Padding(
                      padding: const EdgeInsets.only(top: 87),
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.rotationZ(pi), // Rotate 180 degrees
                        child: const Icon(
                          Icons.change_history_sharp,
                          color: Colors.black,
                          size: 130, // Set the icon size
                        ),
                      ),
                    ),
                    title: 'The Collector',
                    description: '',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
