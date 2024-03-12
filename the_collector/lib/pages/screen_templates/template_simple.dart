import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';

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
    return Center(
      child: AdwClamp.scrollable(
        child: Column(
          children: [
            if (image != null) ...[
              image!,
              const SizedBox(height: 30),
            ],
            Text(
              title,
              style: Theme.of(context).textTheme.displayLarge,
            ),
            const SizedBox(height: 15),
            Text(description, textAlign: TextAlign.center),
            if (secondDescription != null) ...[
              const SizedBox(height: 20),
              Text(
                secondDescription!,
                style: Theme.of(context).textTheme.displayMedium,
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
