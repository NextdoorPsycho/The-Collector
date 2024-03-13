import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

class Toast {
  static void infoToast(String message, BuildContext context, String title, String description) {
    ThemeData theme = Theme.of(context);
    toastification.show(
      context: context,
      type: ToastificationType.info,
      style: ToastificationStyle.flatColored,
      title: Text(title),
      description: Text(description),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 2),
      animationBuilder: (
        context,
        animation,
        alignment,
        child,
      ) {
        return FadeTransition(
          opacity: animation,
          child: child,
        );
      },
      primaryColor: theme.primaryColor,
      backgroundColor: theme.focusColor,
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: lowModeShadow,
      showProgressBar: true,
      dragToClose: true,
      pauseOnHover: false,
      applyBlurEffect: true,
    );
  }
}
