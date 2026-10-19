import 'dart:io';

import 'package:integration_test/integration_test.dart';

import '../test/helpers/scan_workflow_audit.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerScanWorkflowAudit(
    physical: true,
    checkpoint: const bool.fromEnvironment('SCAN_WORKFLOW_SCREENSHOTS')
        ? (String name) async {
            final List<int> bytes = await binding.takeScreenshot(
              'scan-workflow-$name',
            );
            final Directory output = Directory(
              '${Directory.systemTemp.path}/collector-workflow-screenshots',
            );
            await output.create(recursive: true);
            await File('${output.path}/$name.png').writeAsBytes(bytes);
          }
        : null,
  );
}
