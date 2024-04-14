import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:universal_io/io.dart';

final providers = [EmailAuthProvider()];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseUIAuth.configureProviders(
        [...providers]); // Define your providers array
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(), // Define your light theme here
      darkTheme: ThemeData.dark(), // Define your dark theme here
      themeMode: themeNotifier.value, // Use themeNotifier to switch themes
      routes: {
        '/': (context) => AuthenticationWrapper(themeNotifier: themeNotifier),
        '/home': (context) => Splashsc(themeNotifier: themeNotifier),
        '/login': (context) => SignInScreen(
              providers: providers,
              actions: [
                AuthStateChangeAction<SignedIn>((context, state) =>
                    Navigator.pushReplacementNamed(context, '/home'))
              ],
            ),
      },
    );
  }
}

class AuthenticationWrapper extends StatelessWidget {
  final ValueNotifier<ThemeMode> themeNotifier;

  AuthenticationWrapper({required this.themeNotifier});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // Check the connection state
        if (snapshot.connectionState == ConnectionState.active) {
          if (snapshot.hasData) {
            // User is signed in, navigate to '/home'
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.pushReplacementNamed(context, '/home');
            });
          } else {
            // No user is signed in, navigate to '/login'
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.pushReplacementNamed(context, '/login');
            });
          }
          // Return a placeholder widget until navigation is complete
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        } else {
          // Return loading screen while checking the auth state
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
      },
    );
  }
}

class SignOutManager {
  static void signOut(BuildContext context) async {
    await FirebaseAuth.instance.signOut().then((value) => {
          Navigator.pushReplacementNamed(context, '/login'),
        });
  }
}
