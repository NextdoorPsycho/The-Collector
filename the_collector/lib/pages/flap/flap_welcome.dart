import 'dart:math';

import 'package:flutter/material.dart';
import 'package:the_collector/data/user_manager.dart';
import 'package:the_collector/pages/screen_templates/template_animate_simple.dart';

class FlapWelcome extends StatelessWidget {
  const FlapWelcome({super.key});

  @override
  Widget build(BuildContext context) {
    return UserManager.streamUploaderStatus().build((uploader) => AnimatedSimpleScreen(
        image: Transform(
          alignment: Alignment.center,
          transform: Matrix4.rotationZ(pi), // Rotate 180 degrees
          child: const Icon(
            Icons.change_history_sharp,
            size: 130, // Set the icon size
          ),
        ),
        title: 'The Collector',
        description: 'Status: ${(uploader == true) ? 'Curator' : 'Deriver'}'));
  }
}
