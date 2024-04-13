import 'dart:math';

import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/data/user_manager.dart';
import 'package:the_collector/functions/ocr_utils.dart';
import 'package:the_collector/pages/screen_templates/template_animate_simple.dart';
import 'package:the_collector/theme/color.dart';

class FlapWelcome extends StatefulWidget {
  const FlapWelcome({super.key});

  @override
  _FlapWelcomeState createState() => _FlapWelcomeState();
}

class _FlapWelcomeState extends State<FlapWelcome>
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
    _animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _isAnimating = false;
        });
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
    // final mostConfidentCard = await CardSearch.searchMostConfidentCard(
    //     List.of(['Rotat', 'firepl', 'TIME', 'number']));
    // info('Most Confident Card: ${mostConfidentCard?.name}');

    OCRUtilities().pickAndProcessImage(context);
    //should be
  }

  @override
  Widget build(BuildContext context) {
    return UserManager.streamAdminStatus().build((admin) {
      final iconColor = admin == true ? MyColors.red5 : context.textColor;
      return Scaffold(
        floatingActionButton: FloatingActionButton(
          onPressed: getCards,
          child: const Icon(Icons.play_arrow),
        ),
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
          title: 'The Collector',
          description: 'Store Everything.',
        ),
      );
    });
  }
}
