import 'package:fast_log/fast_log.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:scryfall_api/scryfall_api.dart';

class OCRUtilities {
  Future<List<String>> processImageText(InputImage inputImage) async {
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    // This is where its calling every time it has text to detect
    final recognizedText = await textRecognizer.processImage(inputImage);
    final apiClient = ScryfallApiClient();
    apiClient.close();
    return recognizedText.blocks.map((e) => e.text).toList();
  }

  Future<List<DetectedObject>> processImageObjects(
      InputImage inputImage) async {
    ObjectDetector? objectDetector = ObjectDetector(
        options: ObjectDetectorOptions(
      classifyObjects: true,
      mode: DetectionMode.single,
      multipleObjects: true,
    ));

    final objects = await objectDetector.processImage(inputImage);
    info('Objects found: ${objects.length}\n\n');

    return objects;
  }
}
