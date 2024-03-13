enum StorageUnit { B, KB, MB, GB, TB }

class MathStuff {
  static String humanReadableStorage(int bytes, StorageUnit unit) {
    double value;

    switch (unit) {
      case StorageUnit.B:
        value = bytes.toDouble();
        break;
      case StorageUnit.KB:
        value = bytes / 1024;
        break;
      case StorageUnit.MB:
        value = bytes / (1024 * 1024);
        break;
      case StorageUnit.GB:
        value = bytes / (1024 * 1024 * 1024);
        break;
      case StorageUnit.TB:
        value = bytes / (1024 * 1024 * 1024 * 1024);
        break;
    }

    return '${value.toStringAsFixed(2)} ${unit.toString().split('.').last}';
  }

  static double percentileStorageCompare(int bytes1, int bytes2) {
    if (bytes2 == 0) {
      throw ArgumentError('Cannot divide by zero');
    }

    double percentage = bytes1 / bytes2;
    return double.parse((percentage).toStringAsFixed(3));
  }
}
