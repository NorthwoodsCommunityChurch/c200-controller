/*
 * EXAMPLE WiFi credentials template.
 *
 * Copy this file to `wifi_config.h` in the same directory and fill in your
 * own WiFi SSID and password. The real `wifi_config.h` is gitignored so
 * your credentials never get committed to the public repo.
 *
 *   cp wifi_config.example.h wifi_config.h
 *   # edit wifi_config.h with your real network credentials
 *   idf.py build
 */

#pragma once

#define WIFI_SSID      "YourNetworkName"
#define WIFI_PASSWORD  "YourNetworkPassword"
