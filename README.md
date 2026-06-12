# wallpaperd

**A video wallpaper daemon for macOS that is completely invisible to Screen Time.**

## The Problem

If you use any dynamic wallpaper app on macOS — [Plash](https://github.com/sindresorhus/Plash), Dynamic Wallpaper, [Pap.er](https://paper.meiyuan.in/), [我的壁纸](https://apps.apple.com/app/id1552826194), or any of the dozens on the App Store — check your Screen Time. You'll find it recording **24 hours of daily usage** for that app. Every. Single. Day.

This isn't a bug in those apps. It's a fundamental flaw in how macOS Screen Time works:

- **iOS Screen Time** tracks foreground (active) app usage
- **macOS Screen Time** tracks any app with a visible window — even if that window is behind everything else on your desktop
- All dynamic wallpaper apps work by creating a **full-screen borderless window** at desktop level. To macOS, this looks like the app is "open" 24/7
- **There is no way to exclude specific apps.** Apple has [acknowledged this](https://discussions.apple.com/thread/255498028) and has not provided a fix since Catalina (2019)

This makes your Screen Time data essentially useless if you use a wallpaper app — your total "screen time" is inflated by 24 hours, and the wallpaper app dominates your usage charts.

## The Solution

`wallpaperd` solves this by being a **bare Mach-O binary** — not a `.app` bundle. No `CFBundleIdentifier` means Screen Time literally cannot record it. Zero workarounds, zero hacks on the data layer. It simply doesn't exist in Screen Time's world.

## Why It Works

macOS Screen Time tracks app usage via `CFBundleIdentifier`:

```
usaged → NSRunningApplication.bundleIdentifier → knowledgeC.db (ZVALUESTRING = bundle ID)
```

A bare Mach-O binary has no `.app` bundle, no `Info.plist` with `CFBundleIdentifier`, and returns `nil` for `bundleIdentifier`. Screen Time has no key to file a record under — so it doesn't.

```
$ file .build/release/wallpaperd
.build/release/wallpaperd: Mach-O 64-bit executable arm64

$ sqlite3 ~/Library/Application\ Support/Knowledge/knowledgeC.db \
    "SELECT DISTINCT ZVALUESTRING FROM ZOBJECT
     WHERE ZSTREAMNAME = '/app/usage'
     AND ZCREATIONDATE > (strftime('%s','now') - 978307200 - 1800);"
# wallpaperd does NOT appear. Verified.
```

## Features

- **Invisible to Screen Time** — bare Mach-O binary, no bundle identifier
- **< 1% CPU, ~15 MB RAM** — single AVPlayer shared across screens, hardware-decoded
- **Multi-monitor** — one window per screen, auto-adapts to plug/unplug and resolution changes
- **Seamless looping** — video preprocessing (crossfade) + AVMutableComposition (50x repeat) eliminates visible loop stutter
- **Hot-reload config** — edit `~/.config/wallpaperd/config.json`, changes apply instantly
- **Signal control** — `SIGUSR1` = next video, `SIGUSR2` = reload config
- **Auto-start** — LaunchAgent with `KeepAlive`, survives crashes and logouts

## How It Looks

The video plays at desktop level — above the system wallpaper, below your desktop icons and all app windows. Click-through, no Dock icon, no menu bar item. You just see a living desktop.

## Install

### Build from source

```bash
git clone https://github.com/WhenMelancholy/wallpaperd.git
cd wallpaperd
swift build -c release
```

### Install binary + LaunchAgent

```bash
# Install binary
mkdir -p ~/agent/bin
cp .build/release/wallpaperd ~/agent/bin/
codesign -s - ~/agent/bin/wallpaperd  # ad-hoc sign for Apple Silicon

# Install LaunchAgent (auto-start on login)
sed "s|/usr/local/bin/wallpaperd|$HOME/agent/bin/wallpaperd|" LaunchAgent/com.wallpaperd.plist \
    > ~/Library/LaunchAgents/com.wallpaperd.plist

# Start
launchctl load ~/Library/LaunchAgents/com.wallpaperd.plist
```

## Quick Start with Sample Video

A sample wallpaper video is included in `assets/`:

```bash
mkdir -p ~/.config/wallpaperd
echo '{
  "videoPaths": ["'"$(pwd)"'/assets/wallpaper_seamless.mp4"],
  "videoGravity": "fill",
  "muted": true
}' > ~/.config/wallpaperd/config.json
```

## Configure

Edit `~/.config/wallpaperd/config.json` (auto-created on first run):

```json
{
  "videoPaths": ["/path/to/your/video.mp4"],
  "videoGravity": "fill",
  "muted": true
}
```

| Option | Values | Description |
|--------|--------|-------------|
| `videoPaths` | Array of file paths | Videos to play (first one starts) |
| `videoGravity` | `fill` / `fit` / `stretch` | Fill = crop to fill, Fit = letterbox, Stretch = distort |
| `muted` | `true` / `false` | Audio playback |

Config changes are detected automatically — no restart needed.

## Prepare Videos for Seamless Looping

Raw videos will have a brief stutter at the loop point. To eliminate this:

```bash
# Requires ffmpeg: brew install ffmpeg

# 1. Crossfade the last 1s into the first 1s for visual continuity
# 2. Re-encode with closed GOP + faststart for fast seeking
bash scripts/prepare_wallpaper_video.sh input.mp4 output.mp4 1
```

`wallpaperd` also internally repeats the video 50x using `AVMutableComposition`, so even residual decode latency only occurs every ~6 minutes instead of every loop.

## Control

```bash
# Next video in playlist
kill -USR1 $(pgrep wallpaperd)

# Reload config
kill -USR2 $(pgrep wallpaperd)

# Restart (auto-restarts via KeepAlive)
launchctl stop com.wallpaperd

# Disable auto-start
launchctl unload ~/Library/LaunchAgents/com.wallpaperd.plist

# Uninstall
launchctl unload ~/Library/LaunchAgents/com.wallpaperd.plist
rm ~/Library/LaunchAgents/com.wallpaperd.plist
rm ~/agent/bin/wallpaperd
rm -rf ~/.config/wallpaperd
```

## Architecture

```
launchd
  └── wallpaperd (LaunchAgent, bare Mach-O, no .app bundle)
        ├── NSApplication (.accessory policy — no Dock, no menu bar)
        ├── ScreenManager
        │     ├── DesktopWindow[screen0] → AVPlayerLayer ─┐
        │     ├── DesktopWindow[screen1] → AVPlayerLayer ─┤── shared AVPlayer
        │     └── DesktopWindow[screenN] → AVPlayerLayer ─┘
        ├── VideoPlayerManager
        │     ├── AVMutableComposition (video × 50 repeats)
        │     └── AVPlayer (single instance, muted, hardware-decoded)
        ├── ConfigWatcher (GCD file descriptor monitor)
        └── Signal handlers (SIGUSR1 = next, SIGUSR2 = reload)
```

### Window Stack

```
┌─────────────────────────────────┐
│  Normal app windows             │  ← NSWindow.Level.normal (0)
├─────────────────────────────────┤
│  Desktop icons (Finder)         │  ← kCGDesktopIconWindowLevel
├─────────────────────────────────┤
│  wallpaperd DesktopWindow       │  ← kCGDesktopWindowLevel + 1
├─────────────────────────────────┤
│  System wallpaper               │  ← kCGDesktopWindowLevel
└─────────────────────────────────┘
```

## Comparison

| | wallpaperd | Plash | Dynamic Wallpaper | Backdrop |
|---|---|---|---|---|
| Screen Time pollution | **None** | 24h/day | 24h/day | None (system process) |
| CPU usage | < 1% | 3-5% | 3-5% | < 0.3% |
| Memory | ~15 MB | ~80 MB | ~50 MB | Unknown |
| Video wallpaper | Yes | Web only | Yes | Yes |
| Multi-monitor | Yes | Per-screen URL | Yes | Yes |
| Seamless loop | Yes (preprocessed) | N/A | Varies | Yes |
| Price | Free / MIT | Free | Paid | Paid ($9.99) |
| Open source | **Yes** | No (was, now closed) | No | No |
| Approach | Bare Mach-O | .app (LSUIElement) | .app (LSUIElement) | Reverse-engineered system API |

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel
- `ffmpeg` (optional, for video preprocessing)

## How I Discovered This

The full investigation — from "why does my wallpaper app show 24h in Screen Time?" to reverse-engineering macOS's internal `WallpaperAgent` architecture to discovering that bare Mach-O binaries are invisible to Screen Time — is documented in [`docs/investigation.md`](docs/investigation.md).

## License

MIT
