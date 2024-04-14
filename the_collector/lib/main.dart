import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:the_collector/pages/admin/admin_home.dart';
import 'package:the_collector/pages/adw_home.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/data/user_manager.dart';
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
                  debugShowCheckedModeBanner: false,
                  home:
                      snapshot.hasData ? _buildMainApp() : _buildSignInScreen(),
                  darkTheme: MyThemeData.themeData(Brightness.dark),
                  theme: MyThemeData.themeData(Brightness.light),
                  themeMode: currentMode,
                  routes: {
                    '/login': (context) => _buildSignInScreen(),
                    '/home': (context) => _buildMainApp(),
                    '/admin': (context) =>
                        TheAdminHomePage(themeNotifier: themeNotifier),
                  },
                  onGenerateRoute: (settings) {
                    switch (settings.name) {
                      case '/login':
                        return MaterialPageRoute(
                            builder: (_) => _buildSignInScreen());
                      case '/home':
                        return MaterialPageRoute(
                            builder: (_) => _buildMainApp());
                      case '/admin':
                        return MaterialPageRoute(
                            builder: (_) =>
                                TheAdminHomePage(themeNotifier: themeNotifier));
                      default:
                        return MaterialPageRoute(
                            builder: (_) => _buildSignInScreen());
                    }
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSignInScreen() {
    return SignInScreen(
      providers: providers,
      actions: [
        AuthStateChangeAction<SignedIn>((context, state) {
          // Directly manage navigation based on auth state
        }),
      ],
    );
  }

  Widget _buildMainApp() {
    return TheCollectorHomePage(themeNotifier: themeNotifier);
  }
}

class SignOutManager {
  static void signOut(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    // Forcibly reload the app or clear navigation stack
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const SignInScreen()),
      (Route<dynamic> route) => false,
    );
  }
}
