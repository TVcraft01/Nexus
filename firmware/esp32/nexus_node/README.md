# Nexus node — ESP32 firmware

A tiny Nexus peer that lives on a USB cable. Plug it into your PC (or your
phone over USB-OTG), and the Nexus app picks it up automatically: it shows
up in **Devices → Over cable** and in the **Pair over cable** flow.

The node:
- announces itself every 5 s (and answers an immediate identify request),
- answers `ping` with `pong`,
- acts on small command payloads — by default it blinks the on-board LED
  (a long blink when the payload has `"blink": true`) and echoes a
  confirmation back,
- advertises only what it can do (`ping`, `msg`) — the app never offers it
  clipboard or file transfer.

## Flash

Arduino IDE (easiest):

1. Install the ESP32 board package: *Tools → Board → Boards Manager* →
   search "esp32" → install **esp32 by Espressif Systems**.
2. Open `nexus_node.ino`, select your board (*ESP32 Dev Module* or your
   exact model), and the right port (`/dev/ttyUSB0`, or `COM3` on Windows).
3. Click **Upload**.

Command line with esptool:

```bash
esptool.py --port /dev/ttyUSB0 write_flash 0x0 nexus_node.bin
```

## Wire protocol

One JSON object per line, 115200 8N1. See `lib/core/serial_protocol.dart`
in the app for the reference — this sketch generates and matches that
format without any JSON library.

| Message | Direction | Meaning |
|---|---|---|
| `{"t":"ann","id":"esp32-…","name":"…","caps":["ping","msg"],"fw":"…"}` | node → host | presence |
| `{"t":"hello"}` | host → node | please announce now |
| `{"t":"ping"}` / `{"t":"pong"}` | both | liveness |
| `{"t":"msg","data":{…}}` | host → node | small command |
| `{"t":"up","data":{…}}` | node → host | small status payload |
| `{"t":"pair","ok":true,"name":"…"}` | host → node | pairing confirmed |

## Extending

To make the node do something useful (a sensor, an LED strip, a button),
add a case in `handleLine()` for the `msg` type and read `data`. Send data
back the same way — emit an `up` line. The app side routes `msg` from the
cable UI (the bolt button sends `{"blink":true}`), and `up` messages are
already parsed by `SerialBridge`.
