import 'package:flutter/material.dart';

class SimpleDualPercentScreen extends StatelessWidget {
  const SimpleDualPercentScreen({
    super.key,
    required this.title,
    required this.description,
    this.secondTitle,
    this.secondDescription,
    this.image,
    this.footer,
    this.secondFooter,
    this.percent,
  });

  final String title;
  final String description;
  final String? secondTitle;
  final String? secondDescription;
  final Widget? image;
  final Widget? footer;
  final Widget? secondFooter;
  final double? percent;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSection(
              context,
              image,
              title,
              description,
              footer,
            ),
            LinearProgressIndicator(
              value: percent ?? 0.01,
              backgroundColor: Theme.of(context).dividerColor,
              valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).textTheme.bodyText1!.color!),
            ),
            _buildSection(
              context,
              null,
              secondTitle,
              secondDescription,
              secondFooter,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    Widget? image,
    String? title,
    String? description,
    Widget? footer,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (image != null) ...[
            image,
            const SizedBox(height: 30),
          ],
          if (title != null)
            Text(
              title,
              style: Theme.of(context).textTheme.headlineLarge,
              textAlign: TextAlign.center,
            ),
          if (description != null) ...[
            const SizedBox(height: 15),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (footer != null) ...[
            SizedBox(height: description != null ? 20 : 40),
            footer,
          ],
        ],
      ),
    );
  }
}
