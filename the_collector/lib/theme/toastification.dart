import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

class Toast {
  static void infoToast(BuildContext context, String title, String description) {
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

  static void warningToast(BuildContext context, String title, String description) {
    toastification.show(
      context: context,
      type: ToastificationType.warning,
      style: ToastificationStyle.flatColored,
      title: Text(title),
      description: Text(description),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 2),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: highModeShadow,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }

  static void scaryToast(BuildContext context, String title, String description) {
    toastification.show(
      context: context,
      type: ToastificationType.error,
      style: ToastificationStyle.flatColored,
      title: Text(title),
      description: Text(description),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 2),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: highModeShadow,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }

  static void permatoast(BuildContext context, String title, String description) {
    toastification.show(
      context: context,
      type: ToastificationType.info,
      style: ToastificationStyle.flatColored,
      title: Text(title),
      description: Text(description),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 10),
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
      primaryColor: const Color(0xff5d8cb0),
      backgroundColor: const Color(0xffffffff),
      icon: const Icon(
        Icons.insert_drive_file_sharp,
      ),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: lowModeShadow,
      showProgressBar: true,
      dragToClose: true,
      pauseOnHover: false,
      applyBlurEffect: true,
    );
  }
}
