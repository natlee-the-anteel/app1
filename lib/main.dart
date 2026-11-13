import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'sensor_service.dart';

void main() {
  runApp(const IMUApp());
}

class IMUApp extends StatelessWidget {
  const IMUApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

enum _ConnectionMode { ble, usb }

class _DashboardScreenState extends State<DashboardScreen> {
  late SensorService sensorService;
  _ConnectionMode _connectionMode = _ConnectionMode.ble;
  final List<_TimedReading> _readings = [];
  StreamSubscription<IMUData>? _readingSubscription;
  int _sampleCount = 0;
  static const _historyDuration = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    sensorService = _createSensorService();
    _listenForReadings();
    sensorService.start();
  }

  SensorService _createSensorService() {
    return switch (_connectionMode) {
      _ConnectionMode.ble => BleSensorService(),
      _ConnectionMode.usb => RealSensorService('', baudRate: 115200),
    };
  }

  void _listenForReadings() {
    _readingSubscription = sensorService.stream.listen((data) {
      final now = DateTime.now();
      if (!mounted) return;
      setState(() {
        _sampleCount++;
        _readings.add(_TimedReading(now, data));
        _readings.removeWhere(
          (reading) => now.difference(reading.time) > _historyDuration,
        );
      });
    });
  }

  void _changeConnectionMode(_ConnectionMode mode) {
    if (mode == _connectionMode) return;
    _readingSubscription?.cancel();
    sensorService.stop();
    setState(() {
      _connectionMode = mode;
      _readings.clear();
      _sampleCount = 0;
      sensorService = _createSensorService();
    });
    _listenForReadings();
    sensorService.start();
  }

  @override
  void dispose() {
    _readingSubscription?.cancel();
    sensorService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('STEVAL-MKI251A + ESP32 SuperMini 6-DoF Monitor'),
        actions: [
          PopupMenuButton<_ConnectionMode>(
            tooltip: 'Connection type',
            initialValue: _connectionMode,
            onSelected: _changeConnectionMode,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ConnectionMode.ble,
                child: Text('Bluetooth LE'),
              ),
              PopupMenuItem(
                value: _ConnectionMode.usb,
                child: Text('USB serial'),
              ),
            ],
            icon: Icon(
              _connectionMode == _ConnectionMode.ble
                  ? Icons.bluetooth
                  : Icons.usb,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: StreamBuilder<String>(
              stream: sensorService.statusStream,
              initialData: sensorService.status,
              builder: (context, snapshot) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(snapshot.data ?? sensorService.status),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _readings.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No readings received yet. Check that the ESP32 is connected '
                        'and sending sensor data.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        'Samples received: $_sampleCount  •  '
                        'Last update: ${_formatTime(_readings.last.time)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      _buildCard(
                        'Current acceleration (m/s²)',
                        'X: ${_readings.last.data.ax.toStringAsFixed(2)}',
                        'Y: ${_readings.last.data.ay.toStringAsFixed(2)}',
                        'Z: ${_readings.last.data.az.toStringAsFixed(2)}',
                        Colors.blue,
                      ),
                      if (_readings.last.data.hasGyroscope)
                        _buildCard(
                          'Current rotation (rad/s)',
                          'X: ${_readings.last.data.gx.toStringAsFixed(2)}',
                          'Y: ${_readings.last.data.gy.toStringAsFixed(2)}',
                          'Z: ${_readings.last.data.gz.toStringAsFixed(2)}',
                          Colors.orange,
                        ),
                      const SizedBox(height: 12),
                      _buildChartCard(
                        'Accelerometer (m/s²)',
                        acceleration: true,
                      ),
                      const SizedBox(height: 12),
                      if (_readings.last.data.hasGyroscope) ...[
                        _buildChartCard('Gyroscope (rad/s)'),
                        const SizedBox(height: 12),
                      ],
                      _buildChartCard('High-G accelerometer (g)', highG: true),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartCard(
    String title, {
    bool acceleration = false,
    bool highG = false,
  }) {
    final colors = [
      Colors.redAccent,
      Colors.greenAccent,
      Colors.lightBlueAccent,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: List.generate(3, (index) {
                final axis = ['X', 'Y', 'Z'][index];
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 12, height: 3, color: colors[index]),
                    const SizedBox(width: 4),
                    Text(axis),
                  ],
                );
              }),
            ),
            const SizedBox(height: 8),
            if (highG &&
                !_readings.any((reading) => _highGValues(reading.data) != null))
              const Text(
                'Waiting for HighG [g] X/Y/Z values from the ESP32.',
                style: TextStyle(fontSize: 12),
              ),
            if (highG &&
                !_readings.any((reading) => _highGValues(reading.data) != null))
              const SizedBox(height: 8),
            SizedBox(
              height: 180,
              width: double.infinity,
              child: CustomPaint(
                painter: _SensorChartPainter(
                  readings: List.of(_readings),
                  acceleration: acceleration,
                  highG: highG,
                  colors: colors,
                  gridColor: Theme.of(context).colorScheme.outlineVariant,
                  labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Time before latest sample (seconds)',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(String title, String x, String y, String z, Color color) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text(x, style: const TextStyle(fontSize: 16)),
                Text(y, style: const TextStyle(fontSize: 16)),
                Text(z, style: const TextStyle(fontSize: 16)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final localTime = time.toLocal();
    final hour = localTime.hour.toString().padLeft(2, '0');
    final minute = localTime.minute.toString().padLeft(2, '0');
    final second = localTime.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  List<double>? _highGValues(IMUData data) {
    final x = data.hax;
    final y = data.hay;
    final z = data.haz;
    if (x == null || y == null || z == null) return null;
    return [x, y, z];
  }
}

class _TimedReading {
  final DateTime time;
  final IMUData data;

  const _TimedReading(this.time, this.data);
}

class _SensorChartPainter extends CustomPainter {
  final List<_TimedReading> readings;
  final bool acceleration;
  final bool highG;
  final List<Color> colors;
  final Color gridColor;
  final Color labelColor;

  const _SensorChartPainter({
    required this.readings,
    required this.acceleration,
    required this.highG,
    required this.colors,
    required this.gridColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftInset = 52.0;
    const rightInset = 8.0;
    const topInset = 10.0;
    const bottomInset = 26.0;
    final chart = Rect.fromLTWH(
      leftInset,
      topInset,
      size.width - leftInset - rightInset,
      size.height - topInset - bottomInset,
    );
    if (chart.width <= 0 || chart.height <= 0) return;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.6;
    final chartReadings = readings
        .where((reading) => _axisValues(reading) != null)
        .toList();
    var minValue = 0.0;
    var maxValue = 1.0;
    if (chartReadings.isNotEmpty) {
      final values = chartReadings
          .map((reading) => _axisValues(reading)!)
          .expand((value) => value)
          .toList();
      minValue = values.reduce(math.min);
      maxValue = values.reduce(math.max);
      final range = maxValue - minValue;
      final padding = range < 0.01 ? 0.5 : range * 0.1;
      minValue -= padding;
      maxValue += padding;
    }

    final valueRange = maxValue - minValue;
    final decimals = valueRange < 0.1 ? 3 : (valueRange < 10 ? 2 : 1);
    for (var i = 0; i <= 4; i++) {
      final y = chart.top + chart.height * i / 4;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      final value = maxValue - valueRange * i / 4;
      _paintLabel(
        canvas,
        value.toStringAsFixed(decimals),
        Offset(chart.left - 6, y),
        textAlign: TextAlign.right,
        centerVertically: true,
      );
    }
    for (var i = 0; i <= 5; i++) {
      final x = chart.left + chart.width * i / 5;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), gridPaint);
      final secondsAgo = 10 - i * 2;
      _paintLabel(
        canvas,
        i == 5 ? '0 s' : '-$secondsAgo',
        Offset(x, chart.bottom + 5),
        textAlign: TextAlign.center,
      );
    }
    if (chartReadings.isEmpty) return;

    final now = readings.last.time;
    final start = now.subtract(_DashboardScreenState._historyDuration);

    for (var axis = 0; axis < 3; axis++) {
      final path = Path();
      Offset? lastPoint;
      for (var i = 0; i < chartReadings.length; i++) {
        final reading = chartReadings[i];
        final values = _axisValues(reading)!;
        final elapsed = reading.time.difference(start).inMicroseconds;
        final x =
            chart.left +
            chart.width *
                (elapsed /
                        _DashboardScreenState._historyDuration.inMicroseconds)
                    .clamp(0.0, 1.0);
        final y =
            chart.bottom -
            chart.height * ((values[axis] - minValue) / (maxValue - minValue));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        lastPoint = Offset(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[axis]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
      if (chartReadings.length == 1 && lastPoint != null) {
        canvas.drawCircle(lastPoint, 3, Paint()..color = colors[axis]);
      }
    }
  }

  void _paintLabel(
    Canvas canvas,
    String text,
    Offset anchor, {
    required TextAlign textAlign,
    bool centerVertically = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: labelColor, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
    )..layout();
    final x = textAlign == TextAlign.right
        ? anchor.dx - painter.width
        : (textAlign == TextAlign.center
              ? anchor.dx - painter.width / 2
              : anchor.dx);
    final y = centerVertically ? anchor.dy - painter.height / 2 : anchor.dy;
    painter.paint(canvas, Offset(x, y));
  }

  List<double>? _axisValues(_TimedReading reading) {
    final data = reading.data;
    if (highG) {
      final x = data.hax;
      final y = data.hay;
      final z = data.haz;
      if (x == null || y == null || z == null) return null;
      return [x, y, z];
    }
    return acceleration
        ? [data.ax, data.ay, data.az]
        : [data.gx, data.gy, data.gz];
  }

  @override
  bool shouldRepaint(covariant _SensorChartPainter oldDelegate) => true;
}
