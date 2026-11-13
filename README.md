# Nits

A small menu-bar app for macOS that controls the brightness, volume and contrast of external
monitors over DDC/CI, using the keyboard's brightness and volume keys or sliders in the menu.

It is designed to stay out of the system's way:

- A key press is taken over only when it is routed to an external monitor. With the pointer on the
  built-in display, or with sound going to a device macOS can control itself, keys behave exactly
  as they do without the app.
- Keyboard backlight, media keys, and the Option/Control variants of the brightness keys are never touched.
- It does not modify gamma tables, so Night Shift, True Tone and colour profiles are unaffected.
- The key listener is switched off while no external monitor is connected.

## Requirements

- Apple Silicon Mac, macOS 14 or later (the on-screen indicator uses Liquid Glass on macOS 26+)
- A monitor that supports DDC/CI over DisplayPort, HDMI, USB-C or Thunderbolt
- Swift toolchain (Xcode or the Command Line Tools)

## Install from a release

1. Download `Nits-<version>.dmg` from the repository's Releases page and open it.
2. Drag **Nits** onto the **Applications** shortcut.
3. Open Nits from Applications. The app is not notarised by Apple, so the first launch is blocked:
   go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   This is needed once per downloaded copy.

## Build from source

```bash
./Scripts/build.sh --install
```

This builds `build/Nits.app`, copies it to `/Applications` and launches it. Without `--install`
it only builds. `./Scripts/package.sh` builds the release disk image, `build/Nits-<version>.dmg`.

To use the brightness and volume keys, choose **Enable Brightness & Volume Keys…** in the menu and
approve Nits under Accessibility in System Settings. The app is ad-hoc signed, so macOS asks for
this approval again after every rebuild. The sliders work without it.

## Command line

```bash
/Applications/Nits.app/Contents/MacOS/Nits --probe              # list displays and what they report
/Applications/Nits.app/Contents/MacOS/Nits --set brightness 60  # brightness | contrast | volume, 0-100
```

## Keys

| Keys | Effect |
| --- | --- |
| Brightness up/down | Adjusts the display under the pointer (or all displays, selectable in the menu) |
| Shift-Option + brightness/volume | Quarter-size steps |
| Volume up/down/mute | Adjusts the monitor's speakers, only when it is the output and macOS has no volume control for it |

## Notes

- Relies on a few non-public system calls (`IOAVService` for DDC, `DisplayServices` for the
  built-in display's brightness). They are looked up at runtime, so a missing call disables that
  feature rather than breaking the app.
- Intel Macs are not supported.
