# Motion Wallpaper — macOS 26+

![Motion Wallpaper](docs/main-page.png)

Motion Wallpaper is a native macOS 26 (Tahoe) and later utility for live desktop video wallpapers and video on the real macOS lock screen.

This build requires **macOS 26 or later**. The deployment target and `LSMinimumSystemVersion` are both set to `26.0`, and the app checks at runtime that it is running on macOS 26.0 or later.

## Installing an unsigned build

Motion Wallpaper is not signed with a paid Apple Developer certificate, so Gatekeeper will block it by default. Copy `MotionWallpaper.app` to your `Applications` folder, then open Terminal and run:

```bash
xattr -dr com.apple.quarantine "/Applications/MotionWallpaper.app"
codesign --force --deep --sign - "/Applications/MotionWallpaper.app"
open "/Applications/MotionWallpaper.app"
```

Alternatively, try to open Motion Wallpaper once, then go to **System Settings → Privacy & Security** and select **Open Anyway**.

## Desktop wallpaper

The desktop video is rendered by a lightweight hidden instance of the Motion Wallpaper executable launched with:

```text
--desktop-agent
```

The agent owns borderless desktop-level AppKit windows on every display. It remains alive after the main Motion Wallpaper UI quits, so the video keeps playing until you explicitly stop it or log out.

The desktop renderer respects these options:

- Start desktop wallpaper when the app launches
- Launch Motion Wallpaper at login
- Mute desktop video
- Fill screen while preserving aspect ratio

## Lock screen

macOS does not provide a public API for arbitrary lock-screen video. On macOS 26, Motion Wallpaper uses Tahoe's native `WallpaperAerialsExtension` pipeline.

Before using the lock-screen feature for the first time, open **System Settings → Wallpaper** and download at least one Apple Aerial. Tahoe stores downloaded Aerial movies here:

```text
~/Library/Application Support/com.apple.wallpaper/aerials/videos/
```

When you apply a lock-screen video, Motion Wallpaper:

1. Saves the current native wallpaper `Index.plist` before making the first change.
2. Saves the current screen-saver module preference before switching it to the Aerial renderer.
3. Saves the original Apple Aerial movie that will be used as the system playback slot.
4. Converts the selected video to a video-only MOV and repeats it to roughly three minutes.
5. Atomically swaps the converted video into the selected Aerial slot.
6. Selects that Aerial asset in Tahoe's wallpaper store.
7. Configures the screen saver to use `WallpaperAerialsExtension`.
8. Refreshes the lock-screen poster when possible.
9. Clears wallpaper caches and restarts the wallpaper renderer.
10. Restarts only `WallpaperAerialsExtension` after unlock to keep repeated lock/unlock cycles stable.

The original native wallpaper store snapshot is saved under:

```text
~/Library/Application Support/MotionWallpaper/OriginalSystemWallpaper/
```

The original Apple Aerial backup is saved under:

```text
~/Library/Application Support/MotionWallpaper/MacOS26LockScreen/Backups/
```

## Restore behavior

**Stop Desktop Video** stops the detached desktop renderer. If the lock-screen Aerial pipeline is still installed, macOS may still have that Aerial selected as the native wallpaper underneath the desktop renderer.

**Restore Original Lock Screen** restores the original Aerial, native wallpaper store, lock-screen poster (when available), and the previous screen-saver module preference captured before the first lock-screen installation.

**Restore All Original Wallpapers** stops the desktop renderer and restores every saved native wallpaper/screen-saver value that Motion Wallpaper changes.

## Build

Use Xcode with the macOS 26 SDK. Open:

```text
MotionWallpaper.xcodeproj
```

or run:

```bash
./INSTALL.command
```

`INSTALL.command` builds an ad-hoc signed Debug build and opens `MotionWallpaper.app`.

## Diagnostics

The most recent lock-screen installation report is written to:

```text
~/Library/Application Support/MotionWallpaper/macos26-lock-screen-install-report.json
```

## License

Motion Wallpaper is free software, licensed under the [GNU General Public License v3.0](LICENSE). You are free to use, copy, modify, and redistribute this project, provided any distributed version (modified or not) stays open source under the same license and retains attribution to the original authors.
