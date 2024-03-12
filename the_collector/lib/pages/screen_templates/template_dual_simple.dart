import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';

class SimpleDualScreen extends StatelessWidget {
  const SimpleDualScreen({
    super.key,
    required this.title,
    required this.description,
    this.secondTitle,
    this.secondDescription,
    this.image,
    this.footer,
    this.secondFooter,
  });

  final String title;
  final String description;
  final String? secondTitle;
  final String? secondDescription;
  final Widget? image;
  final Widget? footer;
  final Widget? secondFooter;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AdwClamp.scrollable(
        child: ListView(
          shrinkWrap: true,
          children: [
            _buildSection(
              context,
              image,
              title,
              description,
              footer,
            ),
            const Divider(),
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
              style: Theme.of(context).textTheme.displayLarge,
            ),
          if (description != null) ...[
            const SizedBox(height: 15),
            Text(description, textAlign: TextAlign.center),
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
