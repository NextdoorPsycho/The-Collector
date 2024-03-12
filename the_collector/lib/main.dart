import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:the_collector/pages/screen_templates/template_simple.dart';
import 'package:the_collector/pages/screen_templates/template_splash.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:toastification/toastification.dart';
import 'package:universal_io/io.dart';

final providers = [EmailAuthProvider()];

Future<void> main(List<String> args) async {
  if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseUIAuth.configureProviders([...providers]);
  }
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
        if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
          return ToastificationConfigProvider(
            config: const ToastificationConfig(
              alignment: Alignment.center,
              itemWidth: 440,
              animationDuration: Duration(milliseconds: 500),
            ),
            child: MaterialApp(
              initialRoute: FirebaseAuth.instance.currentUser == null ? '/sign-in' : '/home',
              routes: {
                '/home': (context) {
                  return AutoSignInPage(
                    themeNotifier: themeNotifier,
                  );
                }, // '/home': (context) => const WelcomePage(),
                '/sign-in': (context) {
                  return SignInScreen(
                    providers: providers,
                    actions: [
                      AuthStateChangeAction<SignedIn>((context, state) {
                        Navigator.pushReplacementNamed(context, '/home');
                      }),
                    ],
                  );
                },
              },
              darkTheme: MyThemeData.dark(fontFamily: 'akz'),
              theme: MyThemeData.light(fontFamily: 'akz'),
              themeAnimationCurve: Curves.fastLinearToSlowEaseIn,
              debugShowCheckedModeBanner: false,
              themeMode: currentMode,
            ),
          );
        } else {
          return Center(
            child: Container(
              color: Colors.white,
              child: SimpleScreen(
                image: Padding(
                  padding: const EdgeInsets.only(top: 87),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.rotationZ(pi), // Rotate 180 degrees
                    child: const Icon(
                      Icons.change_history_sharp,
                      color: Colors.black,
                      size: 130, // Set the icon size
                    ),
                  ),
                ),
                title: 'The Collector',
                description: '',
              ),
            ),
          );
        }
      },
    );
  }
}
