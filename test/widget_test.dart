import 'package:flutter_test/flutter_test.dart';

import 'package:cut_video/main.dart';

void main() {
  test('splits by 2000 MiB Telegram limit', () {
    const gb = 1000000000;
    expect(partsFor(1 * gb), 1);
    expect(partsFor(2 * gb), 1);
    expect(partsFor(2500000000), 2);
    expect(partsFor(3 * gb), 2);
    expect(partsFor(6 * gb), 3);
    expect(partsFor(0), 1);
  });
}
