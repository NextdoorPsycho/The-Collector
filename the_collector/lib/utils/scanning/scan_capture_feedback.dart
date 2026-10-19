final class ScanCaptureFeedback {
  static const Duration cueDuration = Duration(milliseconds: 2200);
  static const Duration signalGracePeriod = Duration(milliseconds: 1500);

  int _generation = 0;
  final Set<String> _receipts = <String>{};
  final Set<String> _safeTrackIds = <String>{};
  DateTime? _cueUntil;
  DateTime? _lastSignalAt;
  bool _signalPending = false;

  int get generation => _generation;
  Set<String> get safeTrackIds => Set<String>.unmodifiable(_safeTrackIds);
  bool containsReceipt(String id) => _receipts.contains(id);

  bool cueVisible(DateTime now) =>
      _cueUntil != null && now.isBefore(_cueUntil!);

  bool takeSignal(DateTime now) {
    final bool pending = _signalPending;
    _signalPending = false;
    if (!pending ||
        !cueVisible(now) ||
        (_lastSignalAt != null &&
            now.difference(_lastSignalAt!) < signalGracePeriod)) {
      return false;
    }
    _lastSignalAt = now;
    return true;
  }

  void dismissCue() {
    _cueUntil = null;
    _signalPending = false;
  }

  bool acknowledge({
    required int generation,
    required Iterable<({String receiptId, String? trackId})> receipts,
    required DateTime now,
  }) {
    if (generation != _generation) return false;
    bool added = false;
    for (final ({String receiptId, String? trackId}) receipt in receipts) {
      if (receipt.receiptId.isEmpty) continue;
      added = _receipts.add(receipt.receiptId) || added;
      final String? trackId = receipt.trackId;
      if (trackId != null && trackId.isNotEmpty) _safeTrackIds.add(trackId);
    }
    if (added) {
      _cueUntil = now.add(cueDuration);
      _signalPending = true;
    }
    return added;
  }

  void invalidate({bool forgetReceipts = false}) {
    _generation++;
    _cueUntil = null;
    _signalPending = false;
    _safeTrackIds.clear();
    if (forgetReceipts) _receipts.clear();
  }
}
