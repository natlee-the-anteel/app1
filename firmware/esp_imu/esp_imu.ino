// ESP32 firmware for the IMU Monitor app.
//
// Reads the LSM6DSV320X over SPI and sends one Bluetooth LE notification per
// reading in the format the app expects:
//
//   ax,ay,az,gx,gy,gz,hax,hay,haz
//
// Low-g acceleration in m/s^2, gyroscope in degrees/second, high-g
// acceleration in g. The high-g values are the strongest sample since the
// previous notification, so short impacts are not missed between sends.

#include <SPI.h>
#include <math.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Set to 1 to print every reading to Serial Monitor (leave 0 on battery).
#define DEBUG_SERIAL 0

// ---------- Bluetooth (must match BleSensorService in the app) ----------
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

const uint32_t SEND_INTERVAL_MS = 20;  // 50 readings per second

BLECharacteristic* imuChar = nullptr;
volatile bool deviceConnected = false;
bool wasConnected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { deviceConnected = true; }
  void onDisconnect(BLEServer*) override { deviceConnected = false; }
};

// ---------- Sensor (LSM6DSV320X over SPI) ----------
const int CS_PIN = 7;

const uint8_t WHO_AM_I    = 0x0F;
const uint8_t CTRL1       = 0x10;
const uint8_t CTRL2       = 0x11;
const uint8_t CTRL3       = 0x12;
const uint8_t CTRL6       = 0x15;
const uint8_t CTRL8       = 0x17;
const uint8_t OUTX_L_G    = 0x22;   // gyro, then low-g accel
const uint8_t OUTX_L_A_HG = 0x34;   // high-g accel
const uint8_t CTRL2_XL_HG = 0x4D;
const uint8_t CTRL1_XL_HG = 0x4E;

const float STANDARD_GRAVITY = 9.80665f;

void writeRegister(uint8_t reg, uint8_t value) {
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  digitalWrite(CS_PIN, LOW);
  SPI.transfer(reg & 0x7F);
  SPI.transfer(value);
  digitalWrite(CS_PIN, HIGH);
  SPI.endTransaction();
}

uint8_t readRegister(uint8_t reg) {
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  digitalWrite(CS_PIN, LOW);
  SPI.transfer(reg | 0x80);
  uint8_t value = SPI.transfer(0x00);
  digitalWrite(CS_PIN, HIGH);
  SPI.endTransaction();
  return value;
}

void readRegisters(uint8_t startReg, uint8_t* buffer, int count) {
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  digitalWrite(CS_PIN, LOW);
  SPI.transfer(startReg | 0x80);
  for (int i = 0; i < count; i++) buffer[i] = SPI.transfer(0x00);
  digitalWrite(CS_PIN, HIGH);
  SPI.endTransaction();
}

int16_t toInt16(uint8_t lowByte, uint8_t highByte) {
  return (int16_t)((highByte << 8) | lowByte);
}

void setupSensor() {
  pinMode(CS_PIN, OUTPUT);
  digitalWrite(CS_PIN, HIGH);
  SPI.begin(4, 5, 6, CS_PIN);  // SCK=4, MISO=5, MOSI=6, CS=7

  uint8_t id = readRegister(WHO_AM_I);
  Serial.print("WHO_AM_I = 0x");
  Serial.println(id, HEX);
  if (id != 0x73) {
    Serial.println("Sensor not detected! Check wiring.");
    while (1) delay(1000);
  }

  writeRegister(CTRL3, 0x44);        // BDU + auto-increment
  writeRegister(CTRL8, 0x00);        // low-g accel +/-2 g
  writeRegister(CTRL6, 0x0C);        // gyro +/-2000 dps
  writeRegister(CTRL1, 0x06);        // low-g accel 120 Hz, high-performance
  writeRegister(CTRL2, 0x06);        // gyro 120 Hz, high-performance
  writeRegister(CTRL2_XL_HG, 0x00);  // high-g self-test off
  writeRegister(CTRL1_XL_HG, 0xA4);  // high-g on, 960 Hz, +/-320 g
  delay(100);
  Serial.println("Sensor configured.");
}

// Low-g acceleration in m/s^2, gyroscope in degrees/second.
void readImu(float& ax, float& ay, float& az,
             float& gx, float& gy, float& gz) {
  uint8_t d[12];
  readRegisters(OUTX_L_G, d, 12);

  // Gyro: +/-2000 dps => 0.070 dps/LSB
  gx = toInt16(d[0], d[1]) * 0.070f;
  gy = toInt16(d[2], d[3]) * 0.070f;
  gz = toInt16(d[4], d[5]) * 0.070f;

  // Low-g accel: +/-2 g => 0.000061 g/LSB, then g -> m/s^2
  const float accelScale = 0.000061f * STANDARD_GRAVITY;
  ax = toInt16(d[6],  d[7])  * accelScale;
  ay = toInt16(d[8],  d[9])  * accelScale;
  az = toInt16(d[10], d[11]) * accelScale;
}

// High-g acceleration in g. +/-320 g => 0.010417 g/LSB
void readHighG(float& hx, float& hy, float& hz) {
  uint8_t d[6];
  readRegisters(OUTX_L_A_HG, d, 6);
  hx = toInt16(d[0], d[1]) * 0.010417f;
  hy = toInt16(d[2], d[3]) * 0.010417f;
  hz = toInt16(d[4], d[5]) * 0.010417f;
}

// Strongest high-g sample since the last send, so short impacts aren't missed.
float peakHx = 0, peakHy = 0, peakHz = 0, peakMag2 = -1;

void trackHighGPeak() {
  float hx, hy, hz;
  readHighG(hx, hy, hz);
  float mag2 = hx * hx + hy * hy + hz * hz;
  if (mag2 > peakMag2) {
    peakHx = hx; peakHy = hy; peakHz = hz; peakMag2 = mag2;
  }
}

// ---------- Setup ----------
void setup() {
  Serial.begin(115200);
  delay(2000);

  setupSensor();

  BLEDevice::init("ESP32");  // short name so the 128-bit UUID fits in the ad
  BLEDevice::setMTU(185);    // room for the 9-value record (~70 bytes)
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);
  imuChar = service->createCharacteristic(
      CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  imuChar->addDescriptor(new BLE2902());
  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(false);
  adv->setMinPreferred(0x0);
  BLEDevice::startAdvertising();
  Serial.println("Advertising - open the app to connect.");
}

// ---------- Main loop ----------
void loop() {
  static uint32_t lastSend = 0;

  trackHighGPeak();

  if (deviceConnected && millis() - lastSend >= SEND_INTERVAL_MS) {
    lastSend = millis();

    float ax, ay, az, gx, gy, gz;
    readImu(ax, ay, az, gx, gy, gz);

    // ax,ay,az (m/s^2), gx,gy,gz (dps), hax,hay,haz (g)
    char buf[96];
    int len = snprintf(buf, sizeof(buf),
                       "%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f",
                       ax, ay, az, gx, gy, gz, peakHx, peakHy, peakHz);
    imuChar->setValue((uint8_t*)buf, len);
    imuChar->notify();
    peakMag2 = -1;  // start a new peak window

#if DEBUG_SERIAL
    Serial.println(buf);
#endif
  }

  // Start advertising again after the app disconnects so it can reconnect.
  if (!deviceConnected && wasConnected) {
    delay(500);
    BLEDevice::startAdvertising();
    Serial.println("Disconnected - advertising again.");
  }
  wasConnected = deviceConnected;
}
