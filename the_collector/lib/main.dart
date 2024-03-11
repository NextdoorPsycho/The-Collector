import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:the_collector/pages/transitory/auto_sign_in_page.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1000, 600),
    minimumSize: Size(400, 450),
    center: true,
    skipTaskbar: false,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true, // remove this later
    title: '▽',
  );

  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (Platform.isLinux || Platform.isMacOS) {
        await windowManager.setAsFrameless();
      }
      await windowManager.show();
      await windowManager.focus();
    }),
  );

  runApp(MyAdwApp());
}

String googleCloudToken = '';
bool enableGoogleCloud = false;

class MyAdwApp extends StatelessWidget {
  MyAdwApp({
    super.key,
  });

  final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          builder: (context, child) {
            final virtualWindowFrame = VirtualWindowFrameInit();
            return ToastificationConfigProvider(
              config: const ToastificationConfig(
                alignment: Alignment.center,
                itemWidth: 440,
                animationDuration: Duration(milliseconds: 500),
              ),
              child: virtualWindowFrame(context, child),
            );
          },
          darkTheme: MyThemeData.dark(fontFamily: 'akz'),
          theme: MyThemeData.light(fontFamily: 'akz'),
          themeAnimationCurve: Curves.fastLinearToSlowEaseIn,
          debugShowCheckedModeBanner: false,
          home: AutoSignInPage(
            themeNotifier: themeNotifier,
          ),
          themeMode: currentMode,
        );
      },
    );
  }
}
