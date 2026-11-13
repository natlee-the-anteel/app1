import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:imu_monitor/sensor_service.dart';

void main() {
  test('parses the ADXL343 example output in m/s squared', () {
    final reading = IMUData.tryParse('X: -1.234  Y: 2.5  Z: 9.80665  m/s^2');

    expect(reading, isNotNull);
    expect(reading!.ax, -1.234);
    expect(reading.ay, 2.5);
    expect(reading.az, 9.80665);
    expect(reading.hasGyroscope, isFalse);
    expect(reading.hax, isNull);
  });

  test('converts ESP32 BLE gyro CSV from dps to rad/s', () {
    final reading = IMUData.tryParseEsp32BleCsv(
      '1.00,-2.00,9.81,180.00,-90.00,45.00',
    );

    expect(reading, isNotNull);
    expect(reading!.ax, 1.0);
    expect(reading.ay, -2.0);
    expect(reading.az, 9.81);
    expect(reading.gx, closeTo(pi, 1e-8));
    expect(reading.gy, closeTo(-pi / 2, 1e-8));
    expect(reading.gz, closeTo(pi / 4, 1e-8));
  });

  test('rejects invalid ESP32 BLE CSV', () {
    expect(IMUData.tryParseEsp32BleCsv('1,2,3,4,invalid,6'), isNull);
  });

  test('parses HighG values alongside LowG and gyroscope readings', () {
    final reading = IMUData.tryParse(
      'LowG [g] X:0.01 Y:0.02 Z:0.99 | '
      'HighG [g] X:12.5 Y:-30.0 Z:280.0 | '
      'Gyro [dps] X:0.3 Y:-0.4 Z:-0.1',
    );

    expect(reading, isNotNull);
    expect(reading!.ax, closeTo(0.01 * 9.80665, 1e-8));
    expect(reading.gx, closeTo(0.3 * pi / 180, 1e-8));
    expect(reading.hax, 12.5);
    expect(reading.hay, -30.0);
    expect(reading.haz, 280.0);
  });

  test('keeps HighG optional when parsing existing sensor output', () {
    final reading = IMUData.tryParse(
      'LowG [g] X:0.01 Y:0.02 Z:0.99 | '
      'Gyro [dps] X:0.3 Y:-0.4 Z:-0.1',
    );

    expect(reading, isNotNull);
    expect(reading!.hax, isNull);
    expect(reading.hay, isNull);
    expect(reading.haz, isNull);
  });
}
