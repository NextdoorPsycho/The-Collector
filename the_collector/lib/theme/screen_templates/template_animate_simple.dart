import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:flutter/material.dart';

class AnimatedSimpleScreen extends StatelessWidget {
  const AnimatedSimpleScreen({
    super.key,
    required this.title,
    required this.description,
    this.secondDescription,
    this.image,
    this.footer,
  });

  const AnimatedSimpleScreen.runDemo({
    super.key,
    required this.title,
    required this.description,
    this.secondDescription,
    required IconData icon,
    required String nextPageViewName,
    this.image,
    this.footer,
  });

  final String title;
  final String description;
  final String? secondDescription;
  final Widget? image;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              height: 180,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
              ),
            ),
            if (image != null) ...[
              image!,
              const SizedBox(height: 50),
            ],
            Text(
              title,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 15),
            AnimatedTextKit(
              animatedTexts: [
                TypewriterAnimatedText(
                  cursor: '|',
                  description,
                  textAlign: TextAlign.left,
                  speed: const Duration(milliseconds: 50),
                ),
              ],
              totalRepeatCount: 1,
              pause: const Duration(milliseconds: 1000),
              displayFullTextOnTap: true,
              stopPauseOnTap: true,
            ),
            if (secondDescription != null) ...[
              const SizedBox(height: 20),
              AnimatedTextKit(
                animatedTexts: [
                  TypewriterAnimatedText(
                    secondDescription!,
                    textStyle: Theme.of(context).textTheme.headlineMedium,
                    speed: const Duration(milliseconds: 100),
                  ),
                ],
                totalRepeatCount: 1,
                pause: const Duration(milliseconds: 1000),
                displayFullTextOnTap: true,
                stopPauseOnTap: true,
              ),
            ],
            if (footer != null) ...[
              SizedBox(height: secondDescription != null ? 20 : 40),
              footer!,
            ],
            const SizedBox(height: 140),
          ],
        ),
      ),
    );
  }
}
