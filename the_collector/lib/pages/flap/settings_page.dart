import 'dart:async' show Future;

import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/functions/cloud_functions.dart';
import 'package:the_collector/pages/transitory/toast_functions.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
  }

  Future<void> _clearAccount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("google-cloud-service-account");
    await prefs.remove("bucket-name");
    //setstate
    setState(() {});
    info('Google Cloud Service Account cleared');
  }

  @override
  Widget build(BuildContext context) {
    return AdwClamp.scrollable(
      child: Column(
        children: [
          const SizedBox(height: 12),
          AdwPreferencesGroup(
            title: 'Connections',
            children: [
              AdwActionRow(
                title: 'Connect Google Cloud Service Account (Json)',
                onActivated: () => connectGoogleCloudJson(context: context),
              ),
              AdwActionRow(
                title: 'Clear Account',
                onActivated: _clearAccount,
              ),
              AdwActionRow(
                title: 'Test Account',
                onActivated: () async {
                  info('Google Cloud Service Account: ${getGSA()}');
                  info('Google Cloud Bucket Name: ${getBN()}');
                },
              ),
              FutureBuilder<String>(
                future: getBN(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const CircularProgressIndicator();
                  }
                  return AdwTextField(
                    initialValue: snapshot.data,
                    onSubmitted: (value) async {
                      setBN(value);
                      ToastFunctions.successToast(context, t: "Updated Bucket", st: "Bucket Name Updated to $value");
                    },
                    onChanged: (value) {
                      setBN(value);
                    },
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
