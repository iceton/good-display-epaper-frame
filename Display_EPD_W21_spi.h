#ifndef _DISPLAY_EPD_W21_SPI_H_
#define _DISPLAY_EPD_W21_SPI_H_

#include <Arduino.h>

// ==================== USER-DEFINED PINS (ESP32-C6 + DESPI-C73) ====================
#define EPD_CS_PIN    7   // CS
#define EPD_DC_PIN    3   // D/C
#define EPD_RST_PIN   0   // RES
#define EPD_BUSY_PIN  1   // BUSY

// ==================== MACROS FOR SPI CONTROL ====================
#define EPD_W21_CS_0    digitalWrite(EPD_CS_PIN, LOW)
#define EPD_W21_CS_1    digitalWrite(EPD_CS_PIN, HIGH)
#define EPD_W21_DC_0    digitalWrite(EPD_DC_PIN, LOW)
#define EPD_W21_DC_1    digitalWrite(EPD_DC_PIN, HIGH)
#define EPD_W21_RST_0   digitalWrite(EPD_RST_PIN, LOW)
#define EPD_W21_RST_1   digitalWrite(EPD_RST_PIN, HIGH)
#define isEPD_W21_BUSY  digitalRead(EPD_BUSY_PIN)

// ==================== SPI FUNCTIONS ====================
void EPD_W21_WriteCMD(unsigned char command);
void EPD_W21_WriteDATA(unsigned char data);

#endif