import 'dart:math';

import 'package:flutter/material.dart';
import 'package:the_collector/nav_util.dart';
import 'package:the_collector/pages/screen_templates/template_animate_simple.dart';
import 'package:the_collector/utils/data/user_manager.dart';
import 'package:the_collector/utils/functions/ocr_utils.dart';

class CollectionZone extends StatefulWidget {
  const CollectionZone({super.key});

  @override
  _CollectionZoneState createState() => _CollectionZoneState();
}

class _CollectionZoneState extends State<CollectionZone>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _animation = Tween<double>(begin: 0, end: 2 * pi).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOutBack,
      ),
    );
    _animationController.addStatusListener((status) async {
      if (status == AnimationStatus.completed) {
        setState(() {
          _isAnimating = false;
        });
        bool isAdmin = await UserManager.streamAdminStatus().first;
        if (isAdmin) {
          Nav.goToHome(context);
        }
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _startAnimation() {
    if (!_isAnimating) {
      setState(() {
        _isAnimating = true;
      });
      _animationController.forward(from: 0);
    }
  }

  getCards() async {
    OCRUtilities().pickAndProcessImage(context);
  }

  @override
  Widget build(BuildContext context) {
    return UserManager.streamAdminStatus().build((admin) {
      final iconColor = Theme.of(context).textTheme.bodyLarge!.color;
      return Scaffold(
        // add a back arrow in the app bar
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
          title: const Text('Leave Collections'),
        ),
        body: const AnimatedSimpleScreen(
          title: 'The Placeholder',
          description: 'Im ready to die!',
        ),
      );
    });
  }
}
