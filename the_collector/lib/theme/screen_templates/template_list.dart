import 'package:flutter/material.dart';

class ListScreen extends StatelessWidget {
  const ListScreen({
    super.key,
    required this.title,
    required this.description,
    this.footer,
    this.body,
    required this.subpages,
  });

  const ListScreen.runDemo({
    super.key,
    required this.title,
    required this.description,
    this.footer,
    this.body,
    required this.subpages,
  });

  final String title;
  final String description;
  final Widget? body;
  final Widget? footer;
  final List<Widget> subpages;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (footer != null) ...[
                    const SizedBox(height: 16),
                    footer!,
                  ],
                ],
              ),
            ),
          ),
          const Divider(),
          if (subpages.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: subpages,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
