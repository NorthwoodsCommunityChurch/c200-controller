#!/usr/bin/env python3
"""
TSL UMD 3.1 Protocol Test Script
Sends test tally packets to the C200 Controller dashboard for testing
"""

import socket
import time
import sys

TSL_PORT = 5201  # Default port (matches iPhone Tally app)
HOST = 'localhost'

def send_tsl31_packet(address, tally1=0, tally2=0, text="TestCamera"):
    """
    Send TSL 3.1 packet (18 bytes)

    Args:
        address: TSL address (0-126), TSL index will be address+1
        tally1: Program/Red tally (0=off, 1-3=brightness)
        tally2: Preview/Green tally (0=off, 1-3=brightness)
        text: Display text (16 chars max)
    """
    # Build control byte
    control = (tally1 & 0x03) | ((tally2 & 0x03) << 2)

    # Build text field (exactly 16 bytes, padded with spaces)
    text_bytes = text.ljust(16)[:16].encode('ascii')

    # Build packet: [address] [control] [16 bytes text]
    packet = bytes([address, control]) + text_bytes

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect((HOST, TSL_PORT))
        sock.send(packet)
        sock.close()

        tsl_index = address + 1
        status = []
        if tally1 > 0:
            status.append("PROGRAM")
        if tally2 > 0:
            status.append("PREVIEW")
        if not status:
            status.append("OFF")

        print(f"✓ Sent TSL 3.1: Index={tsl_index}, Status={' + '.join(status)}, Text='{text}'")
        return True
    except Exception as e:
        print(f"✗ Error sending packet: {e}")
        return False


def test_sequence():
    """Run a test sequence demonstrating all tally states"""
    print("=" * 60)
    print("TSL UMD 3.1 Test Sequence")
    print("=" * 60)
    print(f"Target: {HOST}:{TSL_PORT}")
    print()

    tests = [
        # (address, tally1, tally2, text, description)
        (0, 1, 0, "Camera 1", "Camera 1 → PROGRAM (red)"),
        (1, 0, 1, "Camera 2", "Camera 2 → PREVIEW (green)"),
        (2, 1, 1, "Camera 3", "Camera 3 → BOTH (amber)"),
        (0, 0, 0, "Camera 1", "Camera 1 → OFF"),
        (1, 0, 0, "Camera 2", "Camera 2 → OFF"),
        (2, 0, 0, "Camera 3", "Camera 3 → OFF"),
    ]

    for i, (addr, t1, t2, text, desc) in enumerate(tests, 1):
        print(f"Test {i}/6: {desc}")
        if send_tsl31_packet(addr, t1, t2, text):
            time.sleep(1)
        else:
            print("Test failed, stopping.")
            return False
        print()

    print("=" * 60)
    print("✓ All tests completed successfully!")
    print()
    print("Next steps:")
    print("1. Check dashboard log: tail -f ~/Library/Logs/c200_debug.log")
    print("2. Open Tally Settings (Cmd+Shift+T) to assign cameras")
    print("3. Verify tally borders appear on camera tiles")
    return True


def interactive_mode():
    """Interactive mode for manual testing"""
    print("=" * 60)
    print("TSL Interactive Mode")
    print("=" * 60)
    print()

    while True:
        try:
            print("Enter TSL index (1-127), or 'q' to quit:")
            inp = input("> ").strip()

            if inp.lower() in ['q', 'quit', 'exit']:
                print("Exiting.")
                break

            try:
                index = int(inp)
                if index < 1 or index > 127:
                    print("Error: Index must be 1-127")
                    continue
            except ValueError:
                print("Error: Invalid number")
                continue

            print("Enter state (program/preview/both/off):")
            state = input("> ").strip().lower()

            if state == 'program':
                t1, t2 = 1, 0
            elif state == 'preview':
                t1, t2 = 0, 1
            elif state == 'both':
                t1, t2 = 1, 1
            elif state == 'off':
                t1, t2 = 0, 0
            else:
                print("Error: Unknown state")
                continue

            address = index - 1  # TSL address is 0-based
            send_tsl31_packet(address, t1, t2, f"Camera {index}")
            print()

        except KeyboardInterrupt:
            print("\nExiting.")
            break


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--interactive":
        interactive_mode()
    else:
        print("Usage:")
        print("  python3 test_tsl.py              # Run automated test sequence")
        print("  python3 test_tsl.py --interactive # Interactive mode")
        print()

        if len(sys.argv) == 1:
            test_sequence()
