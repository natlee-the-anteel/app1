# IMU Monitor

The app connects to the ESP32 over Bluetooth LE by default. Use the connection
menu in the app bar to switch to USB serial; USB serial uses 115200 baud for the
current ESP32 sketch.

The BLE connection scans for service
`4fafc201-1fb5-459e-8fcc-c5c9c331914b` and subscribes to characteristic
`beb5483e-36e1-4688-b7f5-ea07361b26a8`. The characteristic should notify a
comma-separated record in this order:

```text
ax,ay,az,gx,gy,gz[,hax,hay,haz]
```

Acceleration is displayed in m/s². Gyroscope values from the sketch are
transmitted in degrees/second and converted to radians/second for display.
The optional last three values are the High-G accelerometer in g; without
them the High-G graph stays empty.

The ESP32 sketch that sends this format is
[`firmware/esp_imu/esp_imu.ino`](firmware/esp_imu/esp_imu.ino). Open it in
Arduino IDE with the Espressif esp32 boards package installed.
The BLE package is configured for its personal, nonprofit, or educational
license tier; commercial use requires the package's commercial license.

## High-G serial data

The app's High-G graph reads values in g from `HighG [g] X:... Y:... Z:...`
within each newline-terminated serial record. For example:

```text
LowG [g] X:0.01 Y:0.02 Z:0.99 | HighG [g] X:12.5 Y:-30.0 Z:280.0 | Gyro [dps] X:0.3 Y:-0.4 Z:-0.1
```

Over BLE, High-G values arrive as the optional last three CSV fields described
above. The ESP32 firmware must initialize and read the LSM6DSV320X dedicated
High-G accelerometer; the app cannot configure that sensor channel over BLE.
# app1
# app1
