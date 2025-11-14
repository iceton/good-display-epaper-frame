#include <WiFi.h>
#include <HTTPClient.h>
#include <Adafruit_NeoPixel.h>
#include <LittleFS.h>
#include <SPI.h>
#include "Display_EPD_W21_spi.h"
#include "Display_EPD_W21.h"

// WiFi credentials
const char* ssid = "z2";
const char* password = "bearblast";

// URL to download from
const char* url = "https://frame.com/frame/image.bin";

// Flash storage files
const char* headerFile = "/image_header.bin";  // First 100 bytes of current image
const char* timestampFile = "/last_update.txt"; // Timestamp of last display update

// Timing constants
const unsigned long CHECK_INTERVAL = 60000;      // Check every 1 minute (60000 ms)
const unsigned long FORCE_UPDATE_TIME = 86400000; // Force update after 24 hours (24 * 60 * 60 * 1000 ms)

// Global timing variable
unsigned long lastCheckTime = 0;

// ESP32-C6 Super Mini onboard RGB LED on GPIO8
#define LED_PIN 8
#define NUM_PIXELS 1

Adafruit_NeoPixel pixel(NUM_PIXELS, LED_PIN, NEO_GRB + NEO_KHZ800);

// LED color definitions
#define COLOR_OFF       0, 0, 0
#define COLOR_BLUE      0, 0, 255     // Initializing
#define COLOR_YELLOW    255, 255, 0   // Connecting to WiFi
#define COLOR_GREEN     0, 255, 0     // Success / Panel OK
#define COLOR_CYAN      0, 255, 255   // Streaming to display
#define COLOR_RED       255, 0, 0     // Error / Checking panel
#define COLOR_PURPLE    128, 0, 128   // WiFi Connected

void setLED(uint8_t r, uint8_t g, uint8_t b) {
  pixel.setPixelColor(0, pixel.Color(r, g, b));
  pixel.show();
}

void blinkLED(uint8_t r, uint8_t g, uint8_t b, int times, int delayMs) {
  for (int i = 0; i < times; i++) {
    setLED(r, g, b);
    delay(delayMs);
    setLED(COLOR_OFF);
    delay(delayMs);
  }
}

bool panelIsAlive() {
  pinMode(EPD_BUSY_PIN, INPUT);
  digitalWrite(EPD_RST_PIN, LOW);
  delay(20);
  digitalWrite(EPD_RST_PIN, HIGH);

  unsigned long t = millis();
  while (digitalRead(EPD_BUSY_PIN) == HIGH && millis() - t < 1000);
  if (millis() - t >= 1000) return false;

  t = millis();
  while (digitalRead(EPD_BUSY_PIN) == LOW && millis() - t < 5000);
  return (millis() - t < 5000);
}

void saveImageHeader(const uint8_t* header, size_t size) {
  File file = LittleFS.open(headerFile, "w");
  if (file) {
    file.write(header, size);
    file.close();
    Serial.println("Saved image header to flash");
  } else {
    Serial.println("Failed to save image header");
  }
}

bool compareImageHeader(const uint8_t* header, size_t size) {
  if (!LittleFS.exists(headerFile)) {
    Serial.println("No previous header found");
    return false;
  }

  File file = LittleFS.open(headerFile, "r");
  if (!file) {
    Serial.println("Failed to open header file");
    return false;
  }

  if (file.size() != size) {
    file.close();
    Serial.println("Header size mismatch");
    return false;
  }

  bool match = true;
  for (size_t i = 0; i < size; i++) {
    if (file.read() != header[i]) {
      match = false;
      break;
    }
  }
  file.close();

  return match;
}

void saveTimestamp() {
  File file = LittleFS.open(timestampFile, "w");
  if (file) {
    unsigned long currentMillis = millis();
    file.print(currentMillis);
    file.close();
    Serial.printf("Saved timestamp: %lu\n", currentMillis);
  } else {
    Serial.println("Failed to save timestamp");
  }
}

unsigned long getTimeSinceLastUpdate() {
  if (!LittleFS.exists(timestampFile)) {
    Serial.println("No timestamp found, forcing update");
    return FORCE_UPDATE_TIME + 1; // Force update if no timestamp exists
  }

  File file = LittleFS.open(timestampFile, "r");
  if (!file) {
    Serial.println("Failed to read timestamp");
    return FORCE_UPDATE_TIME + 1;
  }

  unsigned long savedMillis = file.parseInt();
  file.close();

  unsigned long currentMillis = millis();

  // Handle millis() rollover (happens every ~49 days)
  if (currentMillis < savedMillis) {
    Serial.println("Millis rollover detected, forcing update");
    return FORCE_UPDATE_TIME + 1;
  }

  unsigned long elapsed = currentMillis - savedMillis;
  Serial.printf("Time since last update: %lu ms (%.1f hours)\n", elapsed, elapsed / 3600000.0);
  return elapsed;
}

void streamDownloadToDisplay() {
  HTTPClient http;

  Serial.println("\n=== Checking for image update ===");
  Serial.println("URL: " + String(url));

  // Check if we need to force update due to 24h timeout
  unsigned long timeSinceUpdate = getTimeSinceLastUpdate();
  bool forceUpdate = (timeSinceUpdate >= FORCE_UPDATE_TIME);

  if (forceUpdate) {
    Serial.println("FORCING UPDATE: 24 hours elapsed since last display");
  }

  // Cyan: Downloading and checking
  setLED(COLOR_CYAN);

  http.begin(url);
  http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
  int httpCode = http.GET();

  if (httpCode != HTTP_CODE_OK && httpCode != HTTP_CODE_MOVED_PERMANENTLY && httpCode != HTTP_CODE_FOUND) {
    Serial.printf("HTTP error: %d\n", httpCode);
    http.end();
    blinkLED(COLOR_RED, 3, 500);
    return;
  }

  Serial.printf("HTTP Response code: %d\n", httpCode);

  // Get content length
  int contentLength = http.getSize();
  Serial.printf("Content-Length: %d bytes\n", contentLength);

  if (contentLength < 384000) {
    Serial.printf("Warning: Content size is less than expected (384000 bytes)\n");
  }

  // Get stream
  WiFiClient* stream = http.getStreamPtr();

  // Read first 100 bytes for comparison
  const size_t HEADER_SIZE = 100;
  uint8_t header[HEADER_SIZE];
  size_t headerBytesRead = 0;

  Serial.println("Reading first 100 bytes...");
  unsigned long timeout = millis();
  while (headerBytesRead < HEADER_SIZE && (millis() - timeout < 5000)) {
    if (stream->available()) {
      header[headerBytesRead++] = stream->read();
    }
    delay(1);
  }

  if (headerBytesRead < HEADER_SIZE) {
    Serial.printf("Failed to read header, got only %d bytes\n", headerBytesRead);
    http.end();
    blinkLED(COLOR_RED, 3, 500);
    return;
  }

  Serial.println("Header read successfully");

  // Compare with stored header (unless forcing update)
  if (!forceUpdate && compareImageHeader(header, HEADER_SIZE)) {
    Serial.println("Image unchanged, skipping display update");
    http.end();
    setLED(COLOR_GREEN);
    return;
  }

  Serial.println("New image detected or forced update, proceeding with display...");

  // Initialize display and start data transmission
  Serial.println("Initializing display for fast update...");
  EPD_init_fast();

  // Clear the screen completely before displaying new image
  Serial.println("Clearing screen...");
  PIC_display_Clear();

  Serial.println("Sending display command...");
  EPD_W21_WriteCMD(0x10);  // Start data transmission

  // Streaming variables
  uint8_t buffer[512];  // Read buffer
  size_t totalBytesProcessed = 0;
  unsigned char temp1, temp2;
  unsigned char data_H, data_L, data;
  bool hasCarryByte = false;
  unsigned char carryByte = 0;
  int lastProgress = -1;

  Serial.println("Streaming image data to display...");

  // First, process the header bytes we already read
  size_t i = 0;
  while (i + 1 < HEADER_SIZE) {
    temp1 = header[i++];
    temp2 = header[i++];
    data_H = Color_get(temp1) << 4;
    data_L = Color_get(temp2);
    data = data_H | data_L;
    EPD_W21_WriteDATA(data);
    totalBytesProcessed += 2;
  }

  // Handle odd byte in header if any
  if (i < HEADER_SIZE) {
    carryByte = header[i];
    hasCarryByte = true;
  }

  // Now continue with the rest of the stream
  contentLength -= HEADER_SIZE; // Account for already-read header

  while (http.connected() && (contentLength > 0 || contentLength == -1)) {
    size_t availableSize = stream->available();

    if (availableSize) {
      // Read chunk
      size_t readSize = stream->readBytes(buffer, min(availableSize, sizeof(buffer)));

      size_t i = 0;

      // Handle carry byte from previous chunk
      if (hasCarryByte) {
        temp1 = carryByte;
        temp2 = buffer[i++];
        data_H = Color_get(temp1) << 4;
        data_L = Color_get(temp2);
        data = data_H | data_L;
        EPD_W21_WriteDATA(data);
        totalBytesProcessed += 2;
        hasCarryByte = false;
      }

      // Process pairs of bytes
      while (i + 1 < readSize) {
        temp1 = buffer[i++];
        temp2 = buffer[i++];
        data_H = Color_get(temp1) << 4;
        data_L = Color_get(temp2);
        data = data_H | data_L;
        EPD_W21_WriteDATA(data);
        totalBytesProcessed += 2;
      }

      // If there's an odd byte left, save it for next chunk
      if (i < readSize) {
        carryByte = buffer[i];
        hasCarryByte = true;
      }

      if (contentLength > 0) {
        contentLength -= readSize;
      }

      // Show progress every 10%
      int progress = (totalBytesProcessed * 100) / 384000;
      if (progress / 10 != lastProgress / 10) {
        Serial.printf("Progress: %d%% (%d bytes)\n", progress, totalBytesProcessed);
        lastProgress = progress;
        blinkLED(COLOR_CYAN, 1, 50);
      }
    }

    delay(1);
  }

  http.end();

  Serial.printf("\nTotal bytes processed: %d\n", totalBytesProcessed);

  if (totalBytesProcessed < 384000) {
    Serial.printf("Warning: Processed fewer bytes than expected (384000)\n");
    // Pad with white if needed
    while (totalBytesProcessed < 384000) {
      EPD_W21_WriteDATA(0x11); // White
      totalBytesProcessed += 2;
    }
  }

  Serial.println("Image data sent to display, refreshing...");

  // Refresh display
  EPD_W21_WriteCMD(0x12);   // DISPLAY REFRESH
  EPD_W21_WriteDATA(0x00);
  delay(1);
  lcd_chkstatus();

  Serial.println("Display updated!");

  // Put display to sleep
  EPD_sleep();

  // Save header and timestamp for future comparisons
  Serial.println("Saving image header and timestamp...");
  saveImageHeader(header, HEADER_SIZE);
  saveTimestamp();

  // Green: Success!
  blinkLED(COLOR_GREEN, 5, 300);
  setLED(COLOR_GREEN);

  Serial.println("=== Update complete! ===");
}

void setup() {
  Serial.begin(115200);
  delay(2000); // Give time for serial to initialize

  Serial.println("\n\nESP32-C6 Starting...");

  // Initialize display pins
  pinMode(EPD_CS_PIN,   OUTPUT);
  pinMode(EPD_DC_PIN,   OUTPUT);
  pinMode(EPD_RST_PIN,  OUTPUT);
  pinMode(EPD_BUSY_PIN, INPUT);

  digitalWrite(EPD_CS_PIN,  HIGH);
  digitalWrite(EPD_RST_PIN, HIGH);

  // Initialize LED
  pixel.begin();
  pixel.setBrightness(50); // Set brightness to 20% (0-255)

  // Red: Initializing
  setLED(COLOR_RED);
  delay(1000);

  // Check if display panel is connected
  Serial.println("Checking display panel...");
  if (!panelIsAlive()) {
    Serial.println("Display panel not responding!");
    while (true) {
      blinkLED(COLOR_RED, 3, 300);
      delay(1000);
    }
  }
  Serial.println("Display panel OK!");

  // Green: Panel detected
  setLED(COLOR_GREEN);
  delay(1000);

  // Blue: Initializing
  blinkLED(COLOR_BLUE, 3, 200);

  // Clear screen first
  EPD_init_fast();
  Serial.println("Clearing screen...");
  PIC_display_Clear();
  EPD_sleep();

  // Initialize SPI
  Serial.println("Initializing SPI...");
  SPI.begin(6, -1, 5, 7);  // SCK=6, MISO=-1 (not used), MOSI=5, CS=7
  SPI.beginTransaction(SPISettings(10000000, MSBFIRST, SPI_MODE0));

  // Initialize LittleFS
  Serial.println("Mounting LittleFS...");
  if (!LittleFS.begin(false)) { // Try mounting without formatting first
    Serial.println("LittleFS mount failed, attempting to format...");

    // Explicitly format the filesystem
    if (!LittleFS.format()) {
      Serial.println("LittleFS format failed!");
      while (true) {
        blinkLED(COLOR_RED, 2, 250);
        delay(500);
      }
    }

    Serial.println("LittleFS formatted successfully");

    // Try mounting again after format
    if (!LittleFS.begin(false)) {
      Serial.println("LittleFS mount failed after format!");
      while (true) {
        blinkLED(COLOR_RED, 2, 250);
        delay(500);
      }
    }
  }

  Serial.println("LittleFS Mounted Successfully");
  Serial.printf("Total space: %d bytes\n", LittleFS.totalBytes());
  Serial.printf("Used space: %d bytes\n", LittleFS.usedBytes());

  // Connect to WiFi
  Serial.println("Connecting to WiFi...");
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);

  // Yellow blink: Connecting to WiFi
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 30) {
    blinkLED(COLOR_YELLOW, 1, 500);
    attempts++;
  }

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi connection failed!");
    // Red fast blink: WiFi connection failed
    while (true) {
      blinkLED(COLOR_RED, 5, 100);
      delay(1000);
    }
  }

  Serial.println("WiFi Connected!");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // Purple solid: WiFi connected
  setLED(COLOR_PURPLE);
  delay(1000);

  // Initial check/download
  streamDownloadToDisplay();

  // Set last check time
  lastCheckTime = millis();

  Serial.println("\n=== Setup complete! Will check for updates every minute ===");
}


void loop() {
  // Check WiFi connection
  if (WiFi.status() != WL_CONNECTED) {
    // Red blink: WiFi disconnected
    Serial.println("WiFi disconnected! Attempting to reconnect...");
    blinkLED(COLOR_RED, 2, 200);
    WiFi.reconnect();
    delay(5000);
    return;
  }

  // Check if it's time to check for updates
  unsigned long currentMillis = millis();

  // Handle millis() rollover
  if (currentMillis < lastCheckTime) {
    lastCheckTime = currentMillis;
  }

  if (currentMillis - lastCheckTime >= CHECK_INTERVAL) {
    Serial.println("\n=== Time to check for updates ===");
    streamDownloadToDisplay();
    lastCheckTime = currentMillis;
  }

  delay(1000);
}
