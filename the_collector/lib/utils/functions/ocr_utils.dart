import 'dart:io';
import 'dart:ui' as ui;

import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:magic_card/magic_card.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/nav_util.dart';
import 'package:the_collector/theme/animation/spinning_triangle.dart';
import 'package:the_collector/utils/data/card/card_rarity.dart';
import 'package:the_collector/utils/data/card/card_type.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

class OCRUtilities {
  static mapToCardRarity(Rarity rarity) {
    switch (rarity) {
      case Rarity.common:
        return CardRarity.common;
      case Rarity.uncommon:
        return CardRarity.uncommon;
      case Rarity.rare:
        return CardRarity.rare;
      case Rarity.special:
        return CardRarity.special;
      case Rarity.mythic:
        return CardRarity.mythic;
      case Rarity.bonus:
        return CardRarity.bonus;
      default:
        return CardRarity.unknown;
    }
  }

  final ObjectDetector _objectDetector = ObjectDetector(
    options: ObjectDetectorOptions(
      classifyObjects: true,
      mode: DetectionMode.single,
      multipleObjects: true,
    ),
  );

  Future<List<DetectedObject>> _processImageObjects(
      InputImage inputImage) async {
    Stopwatch stopwatch = Stopwatch()..start();
    final objects = await _objectDetector.processImage(inputImage);
    stopwatch.stop();
    info('Processing time: ${stopwatch.elapsedMilliseconds} ms');
    info('Objects found: ${objects.length}');
    return objects;
  }

  Future<void> pickAndProcessImage(BuildContext context) async {
    Stopwatch stopwatch = Stopwatch()..start();
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera);
    if (image != null) {
      final InputImage inputImage = InputImage.fromFilePath(image.path);
      final objects = await _processImageObjects(inputImage);
      await _objectDetector.close();
      stopwatch.stop();
      info('Total operation time: ${stopwatch.elapsedMilliseconds} ms');
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

class DisplayPictureScreen extends StatefulWidget {
  final String imagePath;
  final List<DetectedObject> objects;

  const DisplayPictureScreen(
      {super.key, required this.imagePath, required this.objects});

  @override
  _DisplayPictureScreenState createState() => _DisplayPictureScreenState();
}

class _DisplayPictureScreenState extends State<DisplayPictureScreen> {
  List<MtgCard> _cardList = [];
  final List<MtgCard> _selectedCards = [];
  Future<List<MtgCard>>? _cardsFuture;

  @override
  void initState() {
    super.initState();
    _cardsFuture = _loadCards();
  }

  Future<List<MtgCard>> _loadCards() async {
    final croppedImages =
        await cropImages(File(widget.imagePath), widget.objects);
    return _processCards(croppedImages);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cards Found'),
        actions: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 16, 0),
            child: TextButton(
              onPressed: () {},
              child: Text('Selected (${_selectedCards.length})'),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<MtgCard>>(
        future: _cardsFuture,
        builder: (context, cardSnapshot) {
          if (cardSnapshot.connectionState == ConnectionState.done &&
              cardSnapshot.hasData) {
            _cardList = cardSnapshot.data!;
            return GridView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.85,
              ),
              itemCount: _cardList.length,
              itemBuilder: (context, index) {
                final card = _cardList[index];
                final isSelected = _selectedCards.contains(card);
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedCards.remove(card);
                      } else {
                        _selectedCards.add(card);
                      }
                    });
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? Colors.green : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: TradingCard(
                      card: card.imageUris!.normal.toString(),
                      height: 30,
                      padding: const EdgeInsets.all(0),
                    ),
                  ),
                );
              },
            );
          } else {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showSelectedCardsDialog,
        child: const Icon(Icons.save),
      ),
    );
  }

  void _showSelectedCardsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Selected Cards"),
          content: SingleChildScrollView(
            child: ListBody(
              children: _selectedCards.map((card) => Text(card.name)).toList(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Add Cards to Collection'),
              onPressed: () {
                for (final card in _selectedCards) {
                  verbose('Adding card to collection: $card');
                  Crud.card(u).set(
                      card.id,
                      MTGCard(
                          name: card.name,
                          setId: card.setId,
                          description: card.printedText ?? "",
                          flavorText: card.flavorText ?? "",
                          cardType: CardType.generic,
                          rarity: OCRUtilities.mapToCardRarity(card.rarity),
                          manaCost: card.manaCost ?? ""));
                  success('Card added to collection: ${card.name}');
                }
                Nav.goToCollection(context);
              },
            ),
          ],
        );
      },
    );
  }

  Future<List<MtgCard>> _processCards(List<File> croppedImages) async {
    final cardFutures = croppedImages.map((image) async {
      final extractedLines = await _performTextOCR(image);
      return CardSearch.searchMostConfidentCard(extractedLines);
    });

    final cards = await Future.wait(cardFutures);
    return cards.whereType<MtgCard>().toList();
  }

  Future<List<String>> _performTextOCR(File image) async {
    final inputImage = InputImage.fromFilePath(image.path);
    final textRecognizer = TextRecognizer();
    try {
      final RecognizedText recognizedText =
          await textRecognizer.processImage(inputImage);

      List<String> extractedLines = [];
      for (TextBlock block in recognizedText.blocks) {
        for (TextLine line in block.lines) {
          String lineText =
              line.elements.map((element) => element.text).join(' ');
          extractedLines.add(lineText);
        }
      }
      return extractedLines;
    } finally {
      textRecognizer.close();
    }
  }

  Future<List<File>> cropImages(
      File image, List<DetectedObject> objects) async {
    final ui.Image originalImage = await loadImage(image);
    final tempDir = await getTemporaryDirectory();

    Future<File> cropAndSaveImage(DetectedObject object) async {
      final rect = Rect.fromLTWH(
        object.boundingBox.left,
        object.boundingBox.top,
        object.boundingBox.width,
        object.boundingBox.height,
      );

      final pictureRecorder = ui.PictureRecorder();
      final canvas = Canvas(pictureRecorder);
      final paint = Paint();
      canvas.drawImageRect(
        originalImage,
        rect,
        Rect.fromLTWH(0, 0, rect.width, rect.height),
        paint,
      );
      final picture = pictureRecorder.endRecording();
      final croppedImage =
          await picture.toImage(rect.width.toInt(), rect.height.toInt());
      final byteData =
          await croppedImage.toByteData(format: ui.ImageByteFormat.png);
      croppedImage.dispose(); // Dispose of the cropped image to free up memory

      final filePath = '${tempDir.path}/cropped_${objects.indexOf(object)}.png';
      final file = await File(filePath).create();
      await file.writeAsBytes(byteData!.buffer.asUint8List());
      return file;
    }

    final croppedImageFutures = objects.map(cropAndSaveImage);
    return Future.wait(croppedImageFutures);
  }
}

Future<ui.Image> loadImage(File image) async {
  final data = await image.readAsBytes();
  return await decodeImageFromList(data);
}

class CardDetailsScreen extends StatelessWidget {
  final List<String> lines;

  const CardDetailsScreen({super.key, required this.lines});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Card Details')),
      body: FutureBuilder<MtgCard?>(
        future: CardSearch.searchMostConfidentCard(lines),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasData) {
              final card = snapshot.data!;
              return Center(
                child: CardView(
                  id: card.id,
                  flat: true,
                  size: ImageVersion.small,
                  foil: false,
                ),
              );
            } else {
              return const Center(
                child: Text('No matching card found.'),
              );
            }
          } else {
            return Center(
              child: SpinningTriangle(
                iconColor: Theme.of(context).textTheme.bodyLarge!.color!,
              ),
            );
          }
        },
      ),
    );
  }
}
