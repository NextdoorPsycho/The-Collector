import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:the_collector/pages/adw_home.dart';
import 'package:the_collector/pages/screen_templates/template_simple.dart';
import 'package:the_collector/theme/theme.dart';
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

class MyAdwApp extends StatelessWidget {
  MyAdwApp({super.key});

  final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
      return StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return ValueListenableBuilder<ThemeMode>(
              valueListenable: themeNotifier,
              builder: (_, ThemeMode currentMode, __) {
                return MaterialApp(
                  debugShowCheckedModeBanner: false,
                  initialRoute: '/home',
                  routes: {
                    '/home': (context) => AdwHomePage(themeNotifier: themeNotifier),
                  },
                  darkTheme: MyThemeData.dark(fontFamily: 'akz'),
                  theme: MyThemeData.light(fontFamily: 'akz'),
                  themeMode: currentMode,
                );
              },
            );
          } else {
            return MaterialApp(
              initialRoute: '/sign-in',
              routes: {
                '/sign-in': (context) => SignInScreen(
                      providers: providers,
                      actions: [
                        AuthStateChangeAction<SignedIn>((context, state) {
                          Navigator.pushReplacementNamed(context, '/home');
                        }),
                      ],
                    ),
              },
              theme: MyThemeData.light(fontFamily: 'akz'),
            );
          }
        },
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
                transform: Matrix4.rotationZ(pi),
                child: const Icon(
                  Icons.change_history_sharp,
                  color: Colors.black,
                  size: 130,
                ),
              ),
            ),
            title: 'The Collector',
            description: '',
          ),
        ),
      );
    }
  }
}
