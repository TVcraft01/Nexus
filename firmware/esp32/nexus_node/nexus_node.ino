/*
 * Nexus node — ESP32 firmware
 * ===========================
 * A tiny Nexus peer that lives on a USB cable. It announces itself to the
 * Nexus app (PC or phone), answers pings, and acts on small command payloads
 * ("msg") sent from the app — the app shows it in the device list and never
 * offers it things it can't do (clipboard, file transfer).
 *
 * Wire protocol (see lib/core/serial_protocol.dart): one JSON object per
 * line over 115200 8N1. The node only *generates* fixed-format JSON and
 * *matches* incoming lines by substring — no JSON library needed.
 *
 * Flash with the Arduino IDE (ESP32 core) or:
 *   esptool.py --port /dev/ttyUSB0 write_flash 0x0 nexus_node.bin
 *
 * Default pin: on-board LED blinks once on boot, twice when paired, and
 * once per received "msg" (or long blink if the payload says blink:true).
 */

#include <Arduino.h>

#if defined(ESP32)
#include <WiFi.h>
static String chipId() {
  uint64_t mac = ESP.getEfuseMac();
  char buf[20];
  snprintf(buf, sizeof(buf), "%08x%08x",
           (unsigned int)(mac >> 32), (unsigned int)(mac & 0xFFFFFFFF));
  return String("esp32-") + buf;
}
#else
#include <ESP8266WiFi.h>
static String chipId() {
  return String("esp8266-") + String(ESP.getChipId(), HEX);
}
#endif

#define BAUD 115200
#define ANNOUNCE_MS 5000

// Classic ESP32 dev boards usually have the on-board LED on GPIO2; some
// other boards use a different pin. Override with -DLED_BUILTIN if yours
// differs.
#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif
#define LED LED_BUILTIN

static const char *NODE_NAME = "Nexus ESP32";
static String g_id;
static bool g_paired = false;
static unsigned long g_lastAnnounce = 0;
static String g_line = "";
static bool g_ledOn = false;

void sendAnnounce() {
  Serial.print("{\"t\":\"ann\",\"id\":\"");
  Serial.print(g_id);
  Serial.print("\",\"name\":\"");
  Serial.print(NODE_NAME);
  Serial.print("\",\"caps\":[\"ping\",\"msg\"],\"fw\":\"0.1.0\"}\n");
}

void sendPong() {
  Serial.print("{\"t\":\"pong\",\"id\":\"");
  Serial.print(g_id);
  Serial.print("\"}\n");
}

void blink(int times, int onMs) {
  for (int i = 0; i < times; i++) {
    digitalWrite(LED, HIGH);
    delay(onMs);
    digitalWrite(LED, LOW);
    delay(onMs);
  }
}

void setup() {
  Serial.begin(BAUD);
  pinMode(LED, OUTPUT);
  digitalWrite(LED, LOW);
  g_id = chipId();
  delay(200);
  sendAnnounce();   // identify immediately when the app plugs us in
  blink(1, 150);    // boot blink
}

/* True if `line` contains the JSON key with the given value. */
static bool hasKey(const String &line, const char *key, const char *value) {
  String needle = String("\"") + key + "\":\"" + value + "\"";
  return line.indexOf(needle) >= 0;
}

void handleLine(const String &line) {
  if (line.length() == 0 || line[0] != '{') return;

  if (hasKey(line, "t", "hello")) {
    sendAnnounce();
  } else if (hasKey(line, "t", "ping")) {
    sendPong();
  } else if (hasKey(line, "t", "pair")) {
    // Host confirmed the pairing — persist for this boot and blink twice.
    g_paired = true;
    blink(2, 120);
  } else if (hasKey(line, "t", "msg")) {
    // A small command payload from the app. Default: blink once.
    // The app may send {"t":"msg","data":{"blink":true}} for a long blink.
    int idx = line.indexOf("\"data\":");
    bool longBlink = idx >= 0 && line.indexOf("true", idx) >= 0;
    blink(longBlink ? 1 : 1, longBlink ? 700 : 150);
    // Echo what the host sent, so the app can confirm delivery on screen.
    Serial.print("{\"t\":\"up\",\"id\":\"");
    Serial.print(g_id);
    Serial.print("\",\"data\":{\"echo\":");
    if (idx >= 0) {
      Serial.print(line.substring(idx + 7));
    } else {
      Serial.print("\"ok\"");
    }
    Serial.print("}\n");
  }
}

void loop() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n') {
      handleLine(g_line);
      g_line = "";
    } else if (g_line.length() < 512) {
      g_line += c;
    }
  }

  unsigned long now = millis();
  if (now - g_lastAnnounce >= ANNOUNCE_MS) {
    g_lastAnnounce = now;
    sendAnnounce();
  }
  (void)g_ledOn;
}
