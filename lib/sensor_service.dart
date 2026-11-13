import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

// 6-DOF IMU Data Model
class IMUData {
  final double ax, ay, az;
  final double gx, gy, gz;
  final double? hax, hay, haz;

  IMUData({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    this.hax,
    this.hay,
    this.haz,
  });

  static IMUData? tryParse(String input) {
    final parts = input.trim().split(',');
    if (parts.length >= 6) {
      final values = parts.take(6).map(double.tryParse).toList();
      if (values.every((value) => value != null && value.isFinite)) {
        return IMUData(
          ax: values[0]!,
          ay: values[1]!,
          az: values[2]!,
          gx: values[3]!,
          gy: values[4]!,
          gz: values[5]!,
        );
      }
    }

    final labeled = RegExp(
      r'LowG\s*\[g\]\s*X:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
      r'\s*Y:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
      r'\s*Z:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?).*'
      r'Gyro\s*\[dps\]\s*X:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
      r'\s*Y:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
      r'\s*Z:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)',
      caseSensitive: false,
    ).firstMatch(input);
    if (labeled == null) return null;

    final values = List<double>.generate(
      6,
      (index) => double.parse(labeled.group(index + 1)!),
    );
    if (values.any((value) => !value.isFinite)) return null;

    final highGMatch = RegExp(
      r'HighG\s*\[g\]\s*X:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
      r'\s*Y:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
      r'\s*Z:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)',
      caseSensitive: false,
    ).firstMatch(input);
    final highGValues = highGMatch == null
        ? null
        : List<double>.generate(
            3,
            (index) => double.parse(highGMatch.group(index + 1)!),
          );
    if (highGValues != null && highGValues.any((value) => !value.isFinite)) {
      return null;
    }

    const standardGravity = 9.80665;
    const degreesToRadians = pi / 180;
    return IMUData(
      ax: values[0] * standardGravity,
      ay: values[1] * standardGravity,
      az: values[2] * standardGravity,
      gx: values[3] * degreesToRadians,
      gy: values[4] * degreesToRadians,
      gz: values[5] * degreesToRadians,
      hax: highGValues?[0],
      hay: highGValues?[1],
      haz: highGValues?[2],
    );
  }
}

// Common Interface
abstract class SensorService {
  Stream<IMUData> get stream;
  Stream<String> get statusStream;
  String get status;
  void start();
  void stop();
}

// PC Mock Implementation
class MockSensorService implements SensorService {
  final _controller = StreamController<IMUData>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  Timer? _timer;
  String _status = 'Mock sensor is running.';

  @override
  Stream<IMUData> get stream => _controller.stream;

  @override
  Stream<String> get statusStream => _statusController.stream;

  @override
  String get status => _status;

  @override
  void start() {
    _status = 'Mock sensor is running.';
    _statusController.add(_status);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      final time = t.tick * 0.1;
      _controller.add(
        IMUData(
          ax: sin(time),
          ay: cos(time),
          az: 9.81,
          gx: sin(time * 0.5),
          gy: cos(time * 0.5),
          gz: 0.0,
        ),
      );
    });
  }

  @override
  void stop() {
    _timer?.cancel();
  }
}

// Real USB Serial Implementation
class RealSensorService implements SensorService {
  final String portAddress;
  SerialPort? _port;
  SerialPortReader? _reader;
  final _controller = StreamController<IMUData>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  String _buffer = '';
  String _status = 'Waiting to connect to the ESP32...';

  RealSensorService(this.portAddress);

  void _setStatus(String value) {
    _status = value;
    _statusController.add(value);
  }

  // Normalizes port strings to prevent double /dev/ prefixes
  static String formatPortPath(String path) {
    if (path.isEmpty) return '';
    return path.startsWith('/dev/') ? path : '/dev/$path';
  }

  static String findArduinoPort() {
    final available = SerialPort.availablePorts;
    for (final port in available) {
      final name = port.toLowerCase();
      if (name.contains('usb') ||
          name.contains('wch') ||
          name.contains('slab') ||
          name.contains('cp210') ||
          name.contains('ch34') ||
          name.contains('uart')) {
        return formatPortPath(port);
      }
    }
    return '';
  }

  @override
  Stream<IMUData> get stream => _controller.stream;

  @override
  Stream<String> get statusStream => _statusController.stream;

  @override
  String get status => _status;

  @override
  void start() {
    _setStatus('Searching for an ESP32 USB serial port...');
    final target = portAddress.isNotEmpty
        ? formatPortPath(portAddress)
        : findArduinoPort();

    if (target.isEmpty) {
      final ports = SerialPort.availablePorts;
      _setStatus(
        ports.isEmpty
            ? 'No serial ports found. Connect the ESP32 by USB and restart the app.'
            : 'No likely ESP32 port found. Available ports: ${ports.join(', ')}',
      );
      return;
    }

    _setStatus('Opening $target...');
    _port = SerialPort(target);

    if (!_port!.openReadWrite()) {
      final lastErr = SerialPort.lastError;
      _setStatus('Could not open $target: $lastErr');
      return;
    }

    try {
      final config = _port!.config;
      config.baudRate = 115200;
      _port!.config = config;
    } catch (e) {
      _setStatus('Could not configure $target at 115200 baud: $e');
      _port!.close();
      return;
    }

    _setStatus(
      'Connected to $target at 115200 baud; waiting for sensor data...',
    );
    _reader = SerialPortReader(_port!);
    _reader!.stream.listen(
      (Uint8List data) {
        _buffer += utf8.decode(data, allowMalformed: true);
        while (_buffer.contains('\n')) {
          int newlineIndex = _buffer.indexOf('\n');
          String line = _buffer.substring(0, newlineIndex).trim();
          _buffer = _buffer.substring(newlineIndex + 1);

          if (line.isNotEmpty) {
            final parsed = IMUData.tryParse(line);
            if (parsed == null) {
              _setStatus(
                'Received unrecognized sensor data from $target. Expected six CSV '
                'values or labeled LowG/Gyro values with optional HighG [g] data; '
                'got: $line',
              );
            } else {
              _setStatus('Receiving sensor data from $target.');
              _controller.add(parsed);
            }
          }
        }
      },
      onError: (Object err) {
        _setStatus('Serial read error on $target: $err');
      },
      onDone: () {
        _setStatus('Serial connection to $target closed.');
      },
    );
  }

  @override
  void stop() {
    _reader?.close();
    _port?.close();
  }
}
