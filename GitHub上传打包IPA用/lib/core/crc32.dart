import 'dart:typed_data';

/// Standard IEEE 802.3 CRC32 (matches Python binascii.crc32 & Java java.util.zip.CRC32).
class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c & 0xFFFFFFFF;
    }
    return table;
  }

  static int compute(Uint8List data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    int crc = 0xFFFFFFFF;
    for (int i = start; i < stop; i++) {
      crc = _table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String hex(int crc) => crc.toRadixString(16).toUpperCase().padLeft(8, '0');
}
