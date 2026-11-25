import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

// 6-DOF IMU Data Model
class IMUData {
  final double ax, ay, az;
  final double gx, gy, gz;
  final double? hax, hay, haz;

  /// False when the source only provided accelerometer values.
  final bool hasGyroscope;

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
    this.hasGyroscope = true,
  });

  /// Parses a BLE notification. The BLE firmware sends `ax,ay,az,gx,gy,gz`
  /// with acceleration in m/s² and gyroscope in degrees/second, so the
  /// gyroscope values are converted to radians/second here. It may append
  /// `hax,hay,haz`: the High-G accelerometer in g.
  static IMUData? tryParseEsp32BleCsv(String input) {
    final parts = input.trim().split(',');
    if (parts.length >= 6) {
      final values = parts.take(9).map((p) => double.tryParse(p.trim())).toList();
      bool valid(double? value) => value != null && value.isFinite;
      if (values.take(6).every(valid)) {
        const degreesToRadians = pi / 180;
        final hasHighG = values.length == 9 && values.skip(6).every(valid);
        return IMUData(
          ax: values[0]!,
          ay: values[1]!,
          az: values[2]!,
          gx: values[3]! * degreesToRadians,
          gy: values[4]! * degreesToRadians,
          gz: values[5]! * degreesToRadians,
          hax: hasHighG ? values[6] : null,
          hay: hasHighG ? values[7] : null,
          haz: hasHighG ? values[8] : null,
        );
      }
    }
    return null;
  }

  /// Parses accelerometer-only output such as the ADXL343 example sketch:
  /// `X: -1.234  Y: 2.5  Z: 9.80665  m/s^2`. Values are already in m/s².
  static IMUData? _tryParseAccelerometerOnly(String input) {
    const number = r'([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)';
    final match = RegExp(
      '^\\s*X:\\s*$number\\s*Y:\\s*$number\\s*Z:\\s*$number',
      caseSensitive: false,
    ).firstMatch(input);
    if (match == null) return null;
    final values = List<double>.generate(
      3,
      (index) => double.parse(match.group(index + 1)!),
    );
    if (values.any((value) => !value.isFinite)) return null;
    return IMUData(
      ax: values[0],
      ay: values[1],
      az: values[2],
      gx: 0,
      gy: 0,
      gz: 0,
      hasGyroscope: false,
    );
  }

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
    if (labeled == null) return _tryParseAccelerometerOnly(input);

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
  final int baudRate;

  RealSensorService(this.portAddress, {this.baudRate = 115200});

  void _setStatus(String value) {
    _status = value;
    _statusController.add(value);
  }

  // Normalizes port strings to prevent double /dev/ prefixes
  static String formatPortPath(String path) {
    if (path.isEmpty) return '';
    // Windows ports are plain names like COM3.
    if (Platform.isWindows) return path;
    return path.startsWith('/dev/') ? path : '/dev/$path';
  }

  static const _usbSerialKeywords = [
    'usb',
    'wch',
    'slab',
    'cp210',
    'ch34',
    'uart',
    'jtag',
  ];

  static String findArduinoPort() {
    final available = SerialPort.availablePorts;
    for (final port in available) {
      final name = port.toLowerCase();
      // On Windows the name is just COMx, so also check the port's
      // description and transport type.
      var description = '';
      var isUsb = false;
      final info = SerialPort(port);
      try {
        description = (info.description ?? '').toLowerCase();
        isUsb = info.transport == SerialPortTransport.usb;
      } catch (_) {
        // Metadata is optional; fall back to the name check.
      } finally {
        info.dispose();
      }
      if (isUsb ||
          _usbSerialKeywords.any(
            (k) => name.contains(k) || description.contains(k),
          )) {
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
      config.baudRate = baudRate;
      _port!.config = config;
    } catch (e) {
      _setStatus('Could not configure $target at $baudRate baud: $e');
      _port!.close();
      return;
    }

    _setStatus(
      'Connected to $target at $baudRate baud; waiting for sensor data...',
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

// Bluetooth LE Implementation
//
// Scans for the ESP32 advertising [serviceUuid], connects, and subscribes to
// notifications on [characteristicUuid]. Each notification (or each
// newline-terminated line, if the firmware sends newlines) should be
// `ax,ay,az,gx,gy,gz` — see README.md.
class BleSensorService implements SensorService {
  static final serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
  static final characteristicUuid = Guid(
    'beb5483e-36e1-4688-b7f5-ea07361b26a8',
  );
  static const _scanTimeout = Duration(seconds: 15);

  final _controller = StreamController<IMUData>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  BluetoothDevice? _device;
  String _buffer = '';
  bool _stopped = false;
  String _status = 'Waiting to connect to the ESP32 over Bluetooth LE...';

  @override
  Stream<IMUData> get stream => _controller.stream;

  @override
  Stream<String> get statusStream => _statusController.stream;

  @override
  String get status => _status;

  void _setStatus(String value) {
    if (_stopped) return;
    _status = value;
    _statusController.add(value);
  }

  @override
  void start() {
    _stopped = false;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    try {
      if (!await FlutterBluePlus.isSupported) {
        _setStatus('Bluetooth LE is not supported on this device.');
        return;
      }

      _setStatus('Waiting for Bluetooth to turn on...');
      try {
        await FlutterBluePlus.adapterState
            .firstWhere((s) => s == BluetoothAdapterState.on)
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _setStatus(
          'Bluetooth is off or unavailable. Turn it on, then reselect '
          'Bluetooth LE from the connection menu.',
        );
        return;
      }
      if (_stopped) return;

      _setStatus('Scanning for the ESP32...');
      final found = Completer<BluetoothDevice>();
      final scanSub = FlutterBluePlus.onScanResults.listen((results) {
        if (found.isCompleted) return;
        // Check the advertised services here too: the Windows plugin ignores
        // the withServices filter and reports every nearby device.
        for (final result in results) {
          if (result.advertisementData.serviceUuids.contains(serviceUuid)) {
            found.complete(result.device);
            return;
          }
        }
      });
      _subscriptions.add(scanSub);
      await FlutterBluePlus.startScan(
        withServices: [serviceUuid],
        timeout: _scanTimeout,
      );

      final BluetoothDevice device;
      try {
        device = await found.future.timeout(_scanTimeout);
      } on TimeoutException {
        _setStatus(
          'No ESP32 found advertising service $serviceUuid. Check that it is '
          'powered on and nearby, then reselect Bluetooth LE.',
        );
        return;
      } finally {
        await scanSub.cancel();
        _subscriptions.remove(scanSub);
        await FlutterBluePlus.stopScan();
      }
      if (_stopped) return;

      _device = device;
      final name = device.platformName.isNotEmpty
          ? device.platformName
          : device.remoteId.str;
      _setStatus('Connecting to $name...');

      final connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            _status.startsWith('Receiving')) {
          _setStatus(
            'Disconnected from $name. Reselect Bluetooth LE to reconnect.',
          );
        }
      });
      _subscriptions.add(connectionSub);

      // Personal / nonprofit / educational license tier (see README.md).
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      if (_stopped) {
        await device.disconnect();
        return;
      }

      _setStatus('Connected to $name; discovering services...');
      final services = await device.discoverServices();
      BluetoothCharacteristic? characteristic;
      for (final service in services) {
        if (service.uuid != serviceUuid) continue;
        for (final c in service.characteristics) {
          if (c.uuid == characteristicUuid) characteristic = c;
        }
      }
      if (characteristic == null) {
        _setStatus(
          'Connected to $name, but it has no sensor characteristic '
          '$characteristicUuid.',
        );
        await device.disconnect();
        return;
      }

      final valueSub = characteristic.onValueReceived.listen(
        (value) => _handleValue(value, name),
      );
      device.cancelWhenDisconnected(valueSub);
      _subscriptions.add(valueSub);
      await characteristic.setNotifyValue(true);
      _setStatus('Connected to $name; waiting for sensor data...');
    } catch (e) {
      _setStatus('Bluetooth error: $e');
    }
  }

  void _handleValue(List<int> value, String name) {
    final text = utf8.decode(value, allowMalformed: true);

    // Firmware without newlines sends one complete record per notification.
    if (!text.contains('\n') && _buffer.isEmpty) {
      _handleRecord(text, name);
      return;
    }

    _buffer += text;
    var newlineIndex = _buffer.indexOf('\n');
    while (newlineIndex >= 0) {
      final line = _buffer.substring(0, newlineIndex);
      _buffer = _buffer.substring(newlineIndex + 1);
      _handleRecord(line, name);
      newlineIndex = _buffer.indexOf('\n');
    }
  }

  void _handleRecord(String record, String name) {
    final line = record.trim();
    if (line.isEmpty) return;
    final parsed = IMUData.tryParseEsp32BleCsv(line) ?? IMUData.tryParse(line);
    if (parsed == null) {
      _setStatus(
        'Received unrecognized data from $name. Expected ax,ay,az,gx,gy,gz; '
        'got: $line',
      );
      return;
    }
    if (!_status.startsWith('Receiving')) {
      _setStatus('Receiving sensor data from $name over Bluetooth LE.');
    }
    _controller.add(parsed);
  }

  @override
  void stop() {
    _stopped = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _buffer = '';
    FlutterBluePlus.stopScan().catchError((_) {});
    _device?.disconnect().catchError((_) {});
    _device = null;
  }
}
