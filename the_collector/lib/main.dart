import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:the_collector/pages/admin/admin.dart';
import 'package:the_collector/pages/collection/collection.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/data/user/app_user.dart';
import 'package:the_collector/utils/data/user/app_user_restricted.dart';
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
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        Widget w = MaterialApp(
          debugShowCheckedModeBanner: false,
          home: snapshot.hasData ? _buildMainApp() : _buildSignInScreen(),
          darkTheme: MyThemeData.themeData(Brightness.dark),
          theme: MyThemeData.themeData(Brightness.light),
          themeMode: _themeMode,
          routes: {
            '/login': (context) => _buildSignInScreen(),
            '/home': (context) => _buildMainApp(),
            '/collection': (context) => const CollectionHub(),
            '/admin': (context) => const AdminHub(),
          },
          onGenerateRoute: (settings) {
            switch (settings.name) {
              case '/login':
                return MaterialPageRoute(builder: (_) => _buildSignInScreen());
              case '/home':
                return MaterialPageRoute(builder: (_) => _buildMainApp());
              case '/collection':
                return MaterialPageRoute(builder: (_) => const CollectionHub());
              case '/admin':
                return MaterialPageRoute(builder: (_) => const AdminHub());
              default:
                return MaterialPageRoute(builder: (_) => _buildSignInScreen());
            }
          },
        );
        return snapshot.hasData
            ? StreamBuilder<AppUser?>(
                stream: Crud.user().streamOrNull(u),
                builder: (context, f) {
                  if (f.hasData) {
                    WidgetsBinding.instance!.addPostFrameCallback((_) {
                      ThemeMode t = _themeMode;
                      _themeMode =
                          f.data!.theme ? ThemeMode.light : ThemeMode.dark;
                      if (t != _themeMode) {
                        setState(() {
                          info("Theme changed to $_themeMode");
                        });
                      }
                    });
                  }
                  return StreamBuilder(
                      stream: Crud.userRestricted(u).streamOrNull("perms"),
                      builder: (context, s) => MultiProvider(
                            providers: [
                              Provider<AppUserRestricted?>.value(value: s.data),
                            ],
                            child: w,
                          ));
                })
            : w;
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
    return const CollectorHub();
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
