import 'package:flutter/material.dart';
import 'package:the_collector/theme/color.dart';
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
      primaryColor: MyColors.dark4,
      backgroundColor: theme.colorScheme.background,
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

  static void successToast(BuildContext context, String title, String description) {
    toastification.show(
      context: context,
      type: ToastificationType.success,
      style: ToastificationStyle.flatColored,
      title: Text(title),
      description: Text(description),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 2),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: lowModeShadow,
      backgroundColor: MyColors.green01,
      foregroundColor: MyColors.green3,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }
}
