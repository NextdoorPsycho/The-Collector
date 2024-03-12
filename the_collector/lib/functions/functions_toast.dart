import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

class ToastFunctions {
  static successToast(BuildContext context, {required String t, required String st}) async {
    info('Toast: $t - $st');
    ThemeData theme = Theme.of(context);
    toastification.show(
      context: context,
      type: ToastificationType.success,
      style: ToastificationStyle.minimal,
      title: Text(t, style: theme.textTheme.titleLarge),
      description: Text(st, style: theme.textTheme.bodySmall),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 2),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: highModeShadow,
      showProgressBar: true,
      pauseOnHover: false,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }

  static errorToast(BuildContext context, {required String t, required String st}) async {
    info('Toast: $t - $st');
    ThemeData theme = Theme.of(context);
    toastification.show(
      context: context,
      type: ToastificationType.error,
      style: ToastificationStyle.minimal,
      title: Text(t, style: theme.textTheme.titleLarge),
      description: Text(st, style: theme.textTheme.bodySmall),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 3),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: highModeShadow,
      showProgressBar: true,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }

  static warning(BuildContext context, {required String t, required String st}) async {
    info('Toast: $t - $st');
    ThemeData theme = Theme.of(context);
    toastification.show(
      context: context,
      type: ToastificationType.info,
      style: ToastificationStyle.minimal,
      title: Text(t, style: theme.textTheme.titleLarge),
      description: Text(st, style: theme.textTheme.bodySmall),
      alignment: Alignment.topCenter,
      autoCloseDuration: const Duration(seconds: 2),
      borderRadius: BorderRadius.circular(4.0),
      boxShadow: highModeShadow,
      showProgressBar: true,
      dragToClose: true,
      applyBlurEffect: true,
    );
  }
}
