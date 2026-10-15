# System media integration

The app has one queue and one audio engine. `LazerMediaHandler` adapts the existing
`AppState` to system controls, rather than creating another player.

| Platform | Integration |
| --- | --- |
| Android | `audio_service`, foreground media playback service, MediaSession and notification |
| iOS | `audio_service`, MPNowPlayingInfoCenter and MPRemoteCommandCenter; background audio enabled |
| macOS | `audio_service`, MediaPlayer framework |
| Linux | `audio_service_mpris`, session D-Bus / MPRIS |
| Windows | App-owned C++/WinRT SMTC bridge, with timeline and seek support |

Playback position is sampled every **100 ms**. The media handler also publishes
every **100 ms**, and immediately after a structural change. Screens consume the
position notifier without rebuilding the app or the navigation tree.

The exposed transport is previous track, play/pause, next track and absolute
seek. In particular, iOS receives track commands, not the podcast-style 30-second
skip controls. System commands share the same playlist, repeat and shuffle state
as the Flutter UI. Artwork is cached locally using the CDN's required headers.

Windows events are posted to the window thread before using Flutter's method
channel. Shutdown revokes the WinRT event handlers and drains pending events.

Completion uses the player's terminal event, with a fallback based on the native
duration and position. Catalogue durations and estimated clocks never advance an
unavailable or buffering song. A source generation guard discards errors from
superseded play requests.

## Verification

`test/system_media_test.dart` covers completion, the fallback, repeat-one,
interrupted requests, media commands, position cadence, stale artwork and the
Windows channel contract. Responsive and accessibility tests cover the visible
controls and route changes. Apple and Linux native builds require their own OS
toolchains; they cannot be compiled or exercised by the Windows build host.

References: [audio_service](https://pub.dev/packages/audio_service),
[MPRIS adapter](https://pub.dev/packages/audio_service_mpris),
[Microsoft SMTC timeline](https://learn.microsoft.com/en-us/uwp/api/windows.media.systemmediatransportcontrols.updatetimelineproperties).
