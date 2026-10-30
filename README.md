# Rokid Screen

Your Mac's desktop in Rokid Max 2 glasses as a screen that stays put in the
room while you turn your head (3DoF head tracking from the glasses' own
motion sensor).

- **Head-tracked screen**: the glasses' IMU is read over USB HID (no driver,
  no root) and the captured desktop is drawn as a floating screen that turns
  against your head. The screen never gets bigger than the glasses can show.
- **Taps on the frame**: double tap holds the screen still in view, triple
  tap recenters it. It also recenters by itself when the glasses reconnect.
- **Curved Wide Screen**: switches the glasses to 3D mode, which gives a
  3840×1080 desktop, and wraps it around you as a curved screen (82° × 23°).
- **Spatial photos and videos**: Apple spatial video (MV-HEVC) and spatial
  HEIC photos play in 3D, each eye its own picture. Open them with
  Open With → Rokid Screen or from the menu. Esc closes, Space pauses,
  ← → skip 10 s.
- The real Mac pointer is drawn on the floating screen.
- Everything else is in the menu bar icon (glasses).

## Install

Download the DMG from Releases, open it and drag **Rokid Screen** to
Applications. Until the app is signed with a Developer ID, open it the first
time with right-click → Open. Allow it under System Settings → Privacy &
Security → Screen & System Audio Recording when asked.

## Build

Needs Xcode (for `actool`, which compiles the Icon Composer icon) and
Homebrew's `libusb` (linked statically into the 2D/3D switch helper).

```bash
./build.sh      # builds build/Rokid Screen.app and copies it to ~/Applications
./make-dmg.sh   # also packages build/RokidScreen-<version>.dmg
```

Log: `~/Library/Logs/RokidScreen.log`.

## Layout

- `app/imu.swift`: IMU reader, orientation fusion, tap detection
- `app/main.swift`: desktop capture, rendering (flat and curved, per-eye in 3D), menu, app
- `app/media.swift`: spatial photo and video decoding
- `tools/rokid-mode.c`: switches the glasses between 2D and 3D (vendor USB request); bundled in the app
- `tools/rokid-probe.c`, `tools/rokid-hid.c`: USB and HID probes used to find the IMU
- `icon/`: the icon (`AppIcon.icon`) and the drawn concepts it came from (`concepts.swift`)

## Notes

The Max 2 sends 64-byte HID input reports (id 17) on its vendor HID
interface at about 430 Hz: device time (ns), accelerometer (m/s²), gyro
(rad/s) and magnetometer as float32 in OpenXR axes, the layout Monado's
Rokid driver uses. The glasses' own button changes brightness and display
mode and isn't reported to the Mac.

## License

MIT, see [LICENSE](LICENSE). Rokid and Rokid Max are trademarks of Rokid
Corporation; this project isn't affiliated with Rokid.
