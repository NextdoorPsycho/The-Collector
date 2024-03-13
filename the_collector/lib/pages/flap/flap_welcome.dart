import 'dart:math';

import 'package:flutter/material.dart';
import 'package:the_collector/data/user_manager.dart';
import 'package:the_collector/pages/screen_templates/template_animate_simple.dart';
import 'package:the_collector/theme/color.dart';

class FlapWelcome extends StatelessWidget {
  const FlapWelcome({super.key});

  @override
  Widget build(BuildContext context) {
    return UserManager.streamAdminStatus().build((admin) {
      final iconColor = admin == true ? MyColors.red5 : MyColors.dark5;

      return AnimatedSimpleScreen(
        image: Transform(
          alignment: Alignment.center,
          transform: Matrix4.rotationZ(pi), // Rotate 180 degrees
          child: Icon(
            Icons.change_history_sharp,
            size: 130, // Set the icon size
            color: iconColor,
          ),
        ),
        title: 'The Collector',
        description: 'Store Everything.',
      );
    });
  }
}
