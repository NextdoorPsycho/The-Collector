import 'dart:math';

import 'package:flutter/material.dart';
import 'package:the_collector/pages/nav_util.dart';
import 'package:the_collector/theme/screen_templates/template_animate_simple.dart';
import 'package:the_collector/utils/functions/ocr_utils.dart';

class AdminUsers extends StatefulWidget {
  const AdminUsers({super.key});

  @override
  _AdminUsersState createState() => _AdminUsersState();
}

class _AdminUsersState extends State<AdminUsers>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  bool _isAnimating = false;

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

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
        Nav.goToHome(context);
      }
    });
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
    final iconColor = Theme.of(context).textTheme.bodyLarge!.color;
    return Scaffold(
      body: AnimatedSimpleScreen(
        image: GestureDetector(
          onTap: _startAnimation,
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              return Transform(
                alignment: const Alignment(0, 0.23),
                transform: Matrix4.rotationZ(_animation.value + pi),
                child: Icon(
                  Icons.change_history_sharp,
                  size: 200,
                  color: iconColor,
                ),
              );
            },
          ),
        ),
        title: 'The Director',
        description: 'Manage Everything',
      ),
    );
  }
}
