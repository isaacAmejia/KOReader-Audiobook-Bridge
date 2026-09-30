# KOReader Audiobook Bridge

Open audiobook and music files directly from KOReader's file browser with **Audiobook Read-Along**, with optional sidecar cover support for library interfaces such as SimpleUI.

This plugin is a small compatibility layer. It does **not** contain an audio player and does not modify KOReader core files.

## What it does

When you tap a supported audio file in KOReader, the bridge sends it to the installed **Audiobook Read-Along** plugin instead of KOReader's document reader.

Supported file extensions:

- MP3
- M4A
- M4B
- OGG
- OPUS
- FLAC
- WAV
- AAC
- WMA

It also recognizes optional sidecar artwork stored like this:

```text
My Audiobook.m4b
My Audiobook.sdr/
└── cover.jpg
```

If your library UI uses KOReader's BookInfoManager, that `cover.jpg` can be shown as the audiobook cover. This is designed to work with SimpleUI without replacing or editing SimpleUI files.

## Requirements

1. **KOReader**
2. **Audiobook Read-Along** by `stradichenko`
3. KOReader's **Show unsupported files** option enabled if you want audio files to appear in the normal file browser

Audiobook Read-Along is a separate project and must be installed independently.

## Installation

### 1. Install Audiobook Read-Along

Install a current release of `audiobook.koplugin` using that project's instructions.

### 2. Install this bridge

Copy this folder:

```text
audiobooklibrarybridge.koplugin/
```

into your KOReader `plugins` directory.

Common plugin locations include:

| Platform | KOReader plugin directory |
| --- | --- |
| Kindle | `koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |

Restart KOReader after installation.

### 3. Make audio files visible

Open:

```text
Tools → Audiobook Library Bridge
```

and enable:

**Show unsupported files (required for audio)**

The bridge uses KOReader's existing global setting rather than inventing a separate file browser. Be aware that this setting makes **all** unsupported file types visible, not only audio files. You can also change the same setting from KOReader's normal file-browser settings.

## Using it

Once configured:

1. Browse to an audio file in KOReader.
2. Tap the file normally.
3. Audiobook Library Bridge detects the audio extension.
4. Audiobook Read-Along opens the file and handles playback.

There is also an **Audiobook Library Bridge** entry in KOReader's Tools menu that shows basic setup status.

## Sidecar covers

A cover is optional. Place a JPEG at:

```text
<Book filename without extension>.sdr/cover.jpg
```

Example:

```text
Dune.m4b
Dune.sdr/cover.jpg
```

The companion **KOReader Jellyfin Enhanced** plugin can create this sidecar automatically when it downloads an audiobook from Jellyfin.

## Relationship to other projects

- **Audiobook Read-Along** provides the actual playback engine and audiobook UI.
- **KOReader Jellyfin Enhanced** can download audiobooks and their cover art from Jellyfin.
- **SimpleUI** is optional. No SimpleUI source files need to be replaced.

## Compatibility

The current development branch has been source-audited against:

| Component | Verified release |
| --- | --- |
| KOReader | `v2026.07.1` |
| Audiobook Read-Along | `v0.2.11` |
| SimpleUI | `2.7.1` |

The bridge's `ReaderUI:showReader()` hook matches KOReader v2026.07.1's current signature, and Audiobook Read-Along v0.2.11 still exposes the playback and audio-readiness methods used by the bridge. SimpleUI 2.7.1 obtains covers through KOReader's `BookInfoManager`, which is the integration point used here.

The implementation avoids device-specific paths. Actual audio output capabilities still depend on the device and Audiobook Read-Along's platform support. A clean-device runtime test is still recommended before treating a development build as a release.

## Privacy

This plugin stores no server credentials and contains no device-specific configuration.

## License

MIT. See [LICENSE](LICENSE).