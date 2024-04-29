import 'package:flutter/material.dart';
import 'package:the_collector/theme/screen_templates/template_animate_simple.dart';

class CollectionPrices extends StatefulWidget {
  const CollectionPrices({super.key});

  @override
  _CollectionPricesState createState() => _CollectionPricesState();
}

class _CollectionPricesState extends State<CollectionPrices> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // add a back arrow in the app bar
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        title: const Text('Leave Collections'),
      ),
      body: const AnimatedSimpleScreen(
        title: 'The Placeholder',
        description: 'Im ready to die!',
      ),
    );
  }
}
