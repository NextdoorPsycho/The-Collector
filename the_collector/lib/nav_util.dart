import 'package:flutter/material.dart';

class Nav {
  static void goToLogin(BuildContext context) {
    Navigator.of(context).pushReplacementNamed('/login');
  }

  static void goToHome(BuildContext context) {
    Navigator.of(context).pushReplacementNamed('/home');
  }

  static void goToAdmin(BuildContext context) {
    Navigator.of(context).pushReplacementNamed('/admin');
  }
}
