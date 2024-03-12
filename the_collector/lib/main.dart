import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/data/user_manager.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:the_collector/pages/screen_templates/template_splash.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:universal_io/io.dart';

final providers = [EmailAuthProvider()];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseUIAuth.configureProviders([...providers]);
  }
  runApp(MyAdwApp());
}

class MyAdwApp extends StatefulWidget {
  @override
  _MyAdwAppState createState() => _MyAdwAppState();
}

class _MyAdwAppState extends State<MyAdwApp> {
  final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        return StreamBuilder<bool>(
          stream: UserManager.streamTheme(),
          initialData: false,
          builder: (context, themeSnapshot) {
            final isDark = themeSnapshot.data ?? false;
            themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
            return ValueListenableBuilder<ThemeMode>(
              valueListenable: themeNotifier,
              builder: (_, ThemeMode currentMode, __) {
                return MaterialApp(
                  home: snapshot.hasData
                      ? AutoSignInPage(themeNotifier: themeNotifier)
                      : SignInScreen(
                          providers: providers,
                          actions: [
                            AuthStateChangeAction<SignedIn>((context, state) {
                              // Directly manage navigation based on auth state
                            }),
                          ],
                        ),
                  darkTheme: MyThemeData.dark(fontFamily: 'akz'),
                  theme: MyThemeData.light(fontFamily: 'akz'),
                  themeMode: currentMode,
                );
              },
            );
          },
        );
      },
    );
  }
}
