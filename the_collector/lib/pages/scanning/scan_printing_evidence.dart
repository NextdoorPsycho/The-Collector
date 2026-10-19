import 'package:arcane/arcane.dart';

import '../../utils/scanning/scan_recognition.dart';
import '../../utils/scanning/scan_resolver.dart';

class ScanPrintingEvidence extends StatelessWidget {
  final ScanResolution? initialResolution;
  final ScanCandidate candidate;
  final ScanCrop crop;

  const ScanPrintingEvidence({
    super.key,
    required this.initialResolution,
    required this.candidate,
    required this.crop,
  });

  String _label(ScanEvidence evidence) => switch (evidence) {
    ScanEvidence.footerMatch => 'Set and collector number match',
    ScanEvidence.nameMatch => 'Name matches',
    ScanEvidence.nameMismatch => 'Name differs',
    ScanEvidence.fuzzyName => 'Similar name only',
    ScanEvidence.rulesTextMatch => 'Rules text matches',
    ScanEvidence.rulesKeywordMatch => 'Rules keywords match',
    ScanEvidence.rulesTextMismatch => 'Rules text differs',
    ScanEvidence.collectorNumberMatch => 'Collector number matches',
    ScanEvidence.collectorNumberSimilar =>
      'Collector number is similar · Needs review',
    ScanEvidence.printingMismatch => 'Set or collector number differs',
    ScanEvidence.languageMatch => 'Language matches',
    ScanEvidence.languageMismatch => 'Language differs',
    ScanEvidence.typeLineMatch => 'Card type matches',
    ScanEvidence.artworkCompared => 'Artwork compared',
    ScanEvidence.symbolCompared => 'Set symbol compared',
    ScanEvidence.illustratorMatch => 'Illustrator matches',
    ScanEvidence.copyrightYearMatch => 'Copyright year matches',
    ScanEvidence.cloudSuggestion =>
      'Cloud suggestion · Uncalibrated; needs review',
  };

  Widget _evidence(ScanCandidate match) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('Match score: ${match.score} points'),
      if (match.evidence.isEmpty) const Text('No matching scan evidence.'),
      for (final ScanEvidence evidence in ScanEvidence.values)
        if (match.evidence.contains(evidence)) Text(_label(evidence)),
      if (match.artworkDistance != null)
        Text('Artwork distance: ${match.artworkDistance!.toStringAsFixed(3)}'),
      if (match.symbolDistance != null)
        Text('Symbol distance: ${match.symbolDistance!.toStringAsFixed(3)}'),
      if (match.artworkDistance != null || match.symbolDistance != null)
        const Text('Lower distance means a closer visual match.'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ScanCandidate? initial = initialResolution?.candidates.firstOrNull;
    final String confidence = initial == null
        ? 'No initial match'
        : initial.hasContradiction
        ? 'Conflicting evidence'
        : initialResolution!.status == ScanResolutionStatus.exactPrinting
        ? 'Exact printing evidence'
        : initialResolution!.status == ScanResolutionStatus.noMatch
        ? 'No confident match'
        : 'Printing needs review';
    final ScanHints? hints = initialResolution?.hints;
    return Container(
      key: const ValueKey<String>('review-printing-evidence'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.card,
        border: Border.all(color: Theme.of(context).colorScheme.border),
      ),
      child: SingleChildScrollView(
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Initial suggestion',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              if (initial != null) ...<Widget>[
                Text(initial.card.name),
                Text(
                  '${initial.card.set.toUpperCase()} · ${initial.card.collectorNumber}',
                ),
              ],
              const SizedBox(height: 8),
              Text('Confidence: $confidence'),
              const Text('Scores rank matches; they are not probabilities.'),
              if (initial != null)
                Text(
                  'Initial rank: 1 of ${initialResolution!.candidates.length} loaded printings',
                ),
              if ((initialResolution?.candidates.length ?? 0) > 1)
                Text(
                  initial!.score == initialResolution!.candidates[1].score
                      ? 'Equal text scores; name, visual comparisons or catalog order break the tie.'
                      : 'Score lead over next printing: ${initial.score - initialResolution!.candidates[1].score} points',
                ),
              if (initial != null) ...<Widget>[
                const SizedBox(height: 8),
                _evidence(initial),
                if (!initial.evidence.contains(ScanEvidence.footerMatch))
                  const Text(
                    'Set and collector number were not jointly verified.',
                  ),
              ],
              if (initialResolution?.hasMore == true)
                const Text('More catalog printings remain to be checked.'),
              if (initialResolution?.historicalBodyIdentityProof != null)
                Text(
                  'Identity recovered from literal rules text: ${initialResolution!.historicalBodyIdentityProof!.name}',
                ),
              if (initial != null &&
                  initial.card.id != candidate.card.id) ...<Widget>[
                const SizedBox(height: 12),
                const Text(
                  'Selected printing',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${candidate.card.set.toUpperCase()} · ${candidate.card.collectorNumber}',
                ),
                _evidence(candidate),
              ],
              if (hints != null &&
                  (hints.names.isNotEmpty ||
                      hints.setCode != null ||
                      hints.collectorNumber != null)) ...<Widget>[
                const SizedBox(height: 8),
                if (hints.names.isNotEmpty)
                  Text('Read name: ${hints.names.join(' / ')}'),
                if (hints.setCode != null) Text('Read set: ${hints.setCode}'),
                if (hints.collectorNumber != null)
                  Text('Read number: ${hints.collectorNumber}'),
              ],
              if (crop.warnings.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text('Capture flags: ${crop.warnings.join(', ')}'),
              ],
              const SizedBox(height: 8),
              const Text('Tap to return to artwork.'),
            ],
          ),
        ),
      ),
    );
  }
}
