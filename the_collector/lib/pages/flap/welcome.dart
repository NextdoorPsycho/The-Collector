import 'dart:math';

import 'package:flutter/material.dart';
import 'package:the_collector/pages/transitory/simple_screen.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SimpleScreen(
      image: Transform(
        alignment: Alignment.center,
        transform: Matrix4.rotationZ(pi), // Rotate 180 degrees
        child: const Icon(
          Icons.change_history_sharp,
          size: 130, // Set the icon size
        ),
      ),
      title: 'The Collector',
      description: 'Keeping it together.',
    );
  }
}
