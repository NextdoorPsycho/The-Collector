import 'package:flutter/foundation.dart';

enum ScanReceiptState { captured, queued, delivered, discarded }

enum ScanReceiptIdentification { processing, needsCheck, ready }

@immutable
class ScanCaptureReceipt {
  const ScanCaptureReceipt({
    required this.id,
    required this.capturedAt,
    this.acceptedAt,
    this.state = ScanReceiptState.captured,
    this.identification = ScanReceiptIdentification.processing,
    this.quantity = 1,
    this.undoUntil,
    this.undone = 0,
    this.discardedAt,
    this.removalPending = false,
    this.archived = false,
  });

  final String id;
  final DateTime capturedAt;
  final DateTime? acceptedAt;
  final ScanReceiptState state;
  final ScanReceiptIdentification identification;
  final int quantity;
  final DateTime? undoUntil;
  final int undone;
  final DateTime? discardedAt;
  final bool removalPending;
  final bool archived;

  bool get added =>
      state == ScanReceiptState.queued || state == ScanReceiptState.delivered;

  ScanCaptureReceipt copyWith({
    DateTime? acceptedAt,
    ScanReceiptState? state,
    ScanReceiptIdentification? identification,
    int? quantity,
    DateTime? undoUntil,
    int? undone,
    DateTime? discardedAt,
    bool? removalPending,
    bool? archived,
  }) => ScanCaptureReceipt(
    id: id,
    capturedAt: capturedAt,
    acceptedAt: acceptedAt ?? this.acceptedAt,
    state: state ?? this.state,
    identification: identification ?? this.identification,
    quantity: quantity ?? this.quantity,
    undoUntil: undoUntil ?? this.undoUntil,
    undone: undone ?? this.undone,
    discardedAt: discardedAt ?? this.discardedAt,
    removalPending: removalPending ?? this.removalPending,
    archived: archived ?? this.archived,
  );

  factory ScanCaptureReceipt.fromMap(Map<String, Object?> value) {
    final String id = value['id'] as String;
    final int quantity = value['quantity'] as int;
    final int undone = value['undone'] as int;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(id) ||
        quantity < 1 ||
        quantity > 1000000 ||
        undone < 0) {
      throw const FormatException('Invalid scan accounting receipt.');
    }
    return ScanCaptureReceipt(
      id: id,
      capturedAt: DateTime.parse(value['capturedAt'] as String),
      acceptedAt: value['acceptedAt'] == null
          ? null
          : DateTime.parse(value['acceptedAt'] as String),
      state: ScanReceiptState.values.byName(value['state'] as String),
      identification: ScanReceiptIdentification.values.byName(
        value['identification'] as String,
      ),
      quantity: quantity,
      undoUntil: value['undoUntil'] == null
          ? null
          : DateTime.parse(value['undoUntil'] as String),
      undone: undone,
      discardedAt: value['discardedAt'] == null
          ? null
          : DateTime.parse(value['discardedAt'] as String),
      removalPending: value['removalPending'] as bool,
      archived: value['archived'] as bool,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'acceptedAt': acceptedAt?.toUtc().toIso8601String(),
    'state': state.name,
    'identification': identification.name,
    'quantity': quantity,
    'undoUntil': undoUntil?.toUtc().toIso8601String(),
    'undone': undone,
    'discardedAt': discardedAt?.toUtc().toIso8601String(),
    'removalPending': removalPending,
    'archived': archived,
  };
}

@immutable
class ScanAccounting {
  const ScanAccounting({
    this.captured = 0,
    this.added = 0,
    this.processing = 0,
    this.needsCheck = 0,
    this.ready = 0,
    this.pendingDelivery = 0,
    this.undone = 0,
    this.discarded = 0,
  });

  final int captured;
  final int added;
  final int processing;
  final int needsCheck;
  final int ready;
  final int pendingDelivery;
  final int undone;
  final int discarded;

  factory ScanAccounting.fromReceipts(Iterable<ScanCaptureReceipt> receipts) {
    int captured = 0;
    int added = 0;
    int processing = 0;
    int needsCheck = 0;
    int ready = 0;
    int pendingDelivery = 0;
    int undone = 0;
    int discarded = 0;
    for (final ScanCaptureReceipt receipt in receipts) {
      if (receipt.acceptedAt != null) captured++;
      undone += receipt.undone;
      if (receipt.discardedAt != null) discarded++;
      if (receipt.added) added += receipt.quantity;
      if (receipt.state == ScanReceiptState.queued) {
        pendingDelivery += receipt.quantity;
      }
      if (receipt.state != ScanReceiptState.captured) continue;
      switch (receipt.identification) {
        case ScanReceiptIdentification.processing:
          processing++;
        case ScanReceiptIdentification.needsCheck:
          needsCheck++;
        case ScanReceiptIdentification.ready:
          ready++;
      }
    }
    return ScanAccounting(
      captured: captured,
      added: added,
      processing: processing,
      needsCheck: needsCheck,
      ready: ready,
      pendingDelivery: pendingDelivery,
      undone: undone,
      discarded: discarded,
    );
  }
}
