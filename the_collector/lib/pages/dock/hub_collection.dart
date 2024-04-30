import 'dart:math';

import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/pages/nav_util.dart';
import 'package:the_collector/theme/color.dart';
import 'package:the_collector/utils/data/user/app_user_restricted.dart';
import 'package:the_collector/utils/ocr/ocr_utils.dart';

class HubCollection extends StatefulWidget {
  const HubCollection({super.key});

  @override
  _HubCollectionState createState() => _HubCollectionState();
}

class _HubCollectionState extends State<HubCollection>
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

        if (context.read<AppUserRestricted?>()?.admin ?? false) {
          Nav.goToAdmin(context);
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
    bool admin = context.watch<AppUserRestricted?>()?.admin ?? false;
    final iconColor = admin == true
        ? MyColors.red4
        : Theme.of(context).textTheme.bodyLarge!.color;
    return Scaffold(
      body: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 65, 16, 0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 180,
                    child: GestureDetector(
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
                  ),
                  const SizedBox(height: 50),
                  Text(
                    'The Collector',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 15),
                  AnimatedTextKit(
                    animatedTexts: [
                      TypewriterAnimatedText(
                        'Collect Everything.',
                        cursor: '|',
                        textAlign: TextAlign.left,
                        speed: const Duration(milliseconds: 50),
                      ),
                    ],
                    totalRepeatCount: 1,
                    pause: const Duration(milliseconds: 1000),
                    displayFullTextOnTap: true,
                    stopPauseOnTap: true,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 90,
            child: MaterialButton(
              color: Theme.of(context).colorScheme.onBackground,
              onPressed: () {
                //Navigate to the collection page
                Nav.goToCollection(context);
              },
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                "See Collection",
                style:
                    TextStyle(color: Theme.of(context).colorScheme.background),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
