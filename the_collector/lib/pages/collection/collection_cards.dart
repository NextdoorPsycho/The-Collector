import 'package:flutter/material.dart';
import 'package:the_collector/theme/screen_templates/template_animate_simple.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class CollectionCards extends StatefulWidget {
  const CollectionCards({super.key});

  @override
  _CollectionCardsState createState() => _CollectionCardsState();
}

class _CollectionCardsState extends State<CollectionCards> {
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
    return UserManager.streamAdminStatus().build((admin) {
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
    });
  }
}
