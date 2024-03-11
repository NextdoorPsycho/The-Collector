import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/adw_home.dart';
import 'package:the_collector/pages/transitory/toast_functions.dart';

class AutoSignInPage extends StatefulWidget {
  const AutoSignInPage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<AutoSignInPage> createState() => _AutoSignInPageState();
}

class _AutoSignInPageState extends State<AutoSignInPage> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _opacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(_animationController);
    _autoSignIn();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _autoSignIn() async {
    // Simulate a delay to show the loading screen
    await Future.delayed(const Duration(milliseconds: 500));

    // Retrieve device information (you can use this for further authentication if needed)
    final deviceInfo = DeviceInfoPlugin();
    final deviceData = await deviceInfo.deviceInfo;

    // Start the fade-out animation
    _animationController.forward();

    // Wait for the animation to complete
    await Future.delayed(const Duration(milliseconds: 500));

    // Navigate to the home page after the animation
    Navigator.of(context)
        .pushReplacement(
          MaterialPageRoute(builder: (context) => AdwHomePage(themeNotifier: widget.themeNotifier)),
          //then print a toast that is a success!
        )
        .then((value) => ToastFunctions.successToast(context, t: "Success!", st: "Auto Sign-In Successful"));
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      body: Center(
        child: FadeTransition(
          opacity: _opacityAnimation,
          child: const Center(
            child: Text(
              '▽',
              style: TextStyle(fontSize: 150, fontFamily: 'itc'),
            ),
          ),
        ),
      ),
    );
  }
}
