import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

class OCRUtilities {
  final ObjectDetector objectDetector = ObjectDetector(
    options: ObjectDetectorOptions(
      classifyObjects: true,
      mode: DetectionMode.single,
      multipleObjects: true,
    ),
  );
  final TextRecognizer textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  Future<List<DetectedObject>> processImageObjects(
      InputImage inputImage) async {
    final objects = await objectDetector.processImage(inputImage);
    debugPrint('Objects found: ${objects.length}');
    return objects;
  }

  Future<String> processTextRecognition(InputImage inputImage) async {
    final recognizedText = await textRecognizer.processImage(inputImage);
    return recognizedText.text;
  }

  Future<void> pickAndProcessImage(BuildContext context) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final InputImage inputImage = InputImage.fromFilePath(image.path);
      final objects = await processImageObjects(inputImage);
      final Map<String, String> objectTexts = {};
      int objectId = 1;

      for (var object in objects) {
        final cropRect = Rect.fromLTWH(
          object.boundingBox.left,
          object.boundingBox.top,
          object.boundingBox.width,
          object.boundingBox.height,
        );
        final croppedInputImage = InputImage.fromFilePath(
          image.path,
          inputImageData: InputImageData(
            size: Size(object.boundingBox.width, object.boundingBox.height),
            inputImageFormat: InputImageFormat.raw,
            imageRotation: InputImageRotation.rotation0deg,
          ),
          region: cropRect,
        );
        final text = await processTextRecognition(croppedInputImage);
        objectTexts['ob$objectId'] = text;
        objectId++;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => DisplayTextsScreen(objectTexts: objectTexts),
        ),
      );
    }
  }
}

class DisplayTextsScreen extends StatelessWidget {
  final Map<String, String> objectTexts;

  const DisplayTextsScreen({Key? key, required this.objectTexts})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detected Texts')),
      body: ListView.builder(
        itemCount: objectTexts.length,
        itemBuilder: (context, index) {
          String key = objectTexts.keys.elementAt(index);
          return ListTile(
            title: Text(key),
            subtitle: Text(objectTexts[key] ?? 'No text detected'),
          );
        },
      ),
    );
  }
}
