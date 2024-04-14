import 'package:flutter/material.dart';

class BlankListingPage extends StatefulWidget {
  final List<Widget> groups;

  const BlankListingPage({super.key, required this.groups});

  @override
  _BlankListingPageState createState() => _BlankListingPageState();
}

class _BlankListingPageState extends State<BlankListingPage> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: widget.groups,
        ),
      ),
    );
  }
}
