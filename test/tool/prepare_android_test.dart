import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android generation disables Impeller for legacy Huawei GPUs', () {
    final script = File('tool/prepare_android.sh').readAsStringSync();

    expect(
      script,
      contains('io.flutter.embedding.android.EnableImpeller'),
    );
    expect(script, contains('android:value="false"'));
  });
}
