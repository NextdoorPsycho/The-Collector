import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image_picker/image_picker.dart';

class OCRUtilities {
  final ObjectDetector objectDetector = ObjectDetector(
    options: ObjectDetectorOptions(
      classifyObjects: true,
      mode: DetectionMode.single,
      multipleObjects: true,
    ),
  );

  Future<List<DetectedObject>> processImageObjects(
      InputImage inputImage) async {
    final objects = await objectDetector.processImage(inputImage);
    debugPrint('Objects found: ${objects.length}');
    return objects;
  }

  Future<void> pickAndProcessImage(BuildContext context) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final InputImage inputImage = InputImage.fromFilePath(image.path);
      final objects = await processImageObjects(inputImage);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              DisplayPictureScreen(imagePath: image.path, objects: objects),
        ),
      );
    }
  }
}

class DisplayPictureScreen extends StatelessWidget {
  final String imagePath;
  final List<DetectedObject> objects;

  const DisplayPictureScreen(
      {Key? key, required this.imagePath, required this.objects})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Detected Objects')),
      body: FutureBuilder<ui.Image>(
        future: loadImage(File(imagePath)),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            return Center(
              child: CustomPaint(
                foregroundPainter: ObjectPainter(snapshot.data!, objects),
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            );
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }

  Future<ui.Image> loadImage(File image) async {
    final data = await image.readAsBytes();
    return await decodeImageFromList(data);
  }
}

class ObjectPainter extends CustomPainter {
  final ui.Image image;
  final List<DetectedObject> objects;

  ObjectPainter(this.image, this.objects);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (var object in objects) {
      final rect = Rect.fromLTWH(
        object.boundingBox.left * size.width / image.width,
        object.boundingBox.top * size.height / image.height,
        object.boundingBox.width * size.width / image.width,
        object.boundingBox.height * size.height / image.height,
      );
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
