#!/bin/bash
# ESP32 Tally LED Test Script
# Tests the tally REST API endpoints directly

ESP32_IP="1.1.1.1"  # Change to your ESP32 IP if different

echo "=========================================="
echo "ESP32 Tally LED Test"
echo "=========================================="
echo "Target: http://$ESP32_IP"
echo

# Test 1: Program (Red LED)
echo "Test 1: Setting PROGRAM tally (red LED)"
curl -X POST "http://$ESP32_IP/api/tally/program" -s | jq .
sleep 2

# Test 2: Preview (Green LED)
echo
echo "Test 2: Setting PREVIEW tally (green LED)"
curl -X POST "http://$ESP32_IP/api/tally/preview" -s | jq .
sleep 2

# Test 3: Both (Amber LED)
echo
echo "Test 3: Setting BOTH tallies (amber - both LEDs)"
curl -X POST "http://$ESP32_IP/api/tally/both" -s | jq .
sleep 2

# Test 4: Off
echo
echo "Test 4: Turning tally OFF"
curl -X POST "http://$ESP32_IP/api/tally/off" -s | jq .
sleep 1

# Test 5: Verify WebSocket includes tally field
echo
echo "Test 5: Checking WebSocket state broadcast"
echo "Setting to PROGRAM and checking status..."
curl -X POST "http://$ESP32_IP/api/tally/program" -s > /dev/null
sleep 1
curl -s "http://$ESP32_IP/api/status" | jq .

echo
echo "=========================================="
echo "✓ Basic tests complete!"
echo
echo "Next steps:"
echo "1. Verify LED colors:"
echo "   - Program: Red LED ON"
echo "   - Preview: Green LED ON"
echo "   - Both: Both LEDs ON (amber color)"
echo "   - Off: Both LEDs OFF"
echo
echo "2. Check ESP32 serial monitor for log messages"
echo "3. Test with dashboard: Cmd+Shift+T to open Tally Settings"
echo "=========================================="
