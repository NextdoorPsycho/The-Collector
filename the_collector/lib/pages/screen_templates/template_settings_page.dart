import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';

class BlankListingPage extends StatefulWidget {
  final List<Widget> groups;

  const BlankListingPage({super.key, required this.groups});

  @override
  _BlankListingPageState createState() => _BlankListingPageState();
}

class _BlankListingPageState extends State<BlankListingPage> {
  @override
  Widget build(BuildContext context) {
    return AdwClamp.scrollable(
      child: Column(
        children: widget.groups,
      ),
    );
  }
}
