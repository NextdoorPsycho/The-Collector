import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';

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
    return AdwClamp.scrollable(
      child: Column(
        children: [
          const SizedBox(height: 12),
          AdwPreferencesGroup(
            title: title,
            description: description,
            children: [
              footer ?? const SizedBox(),
            ],
          ),
          const Divider(),
          AdwPreferencesGroup(
            children: subpages.isNotEmpty ? subpages : [const SizedBox()],
          ),
        ],
      ),
    );
  }
}
