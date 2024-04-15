import 'package:flutter/material.dart';

class SimpleScreen extends StatelessWidget {
  const SimpleScreen({
    super.key,
    required this.title,
    required this.description,
    this.secondDescription,
    this.image,
    this.footer,
  });

  const SimpleScreen.runDemo({
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
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (image != null) ...[
              image!,
              const SizedBox(height: 30),
            ],
            Text(
              title,
              style: Theme.of(context).textTheme.headlineLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 15),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (secondDescription != null) ...[
              const SizedBox(height: 20),
              Text(
                secondDescription!,
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
            ],
            if (footer != null) ...[
              SizedBox(height: secondDescription != null ? 20 : 40),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}
