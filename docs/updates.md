# Updates

EdLazer does not check for updates.

There is no startup check, no settings action, no GitHub releases request,
and no prompt that sends a fork install to another repository. About still
shows the static version and short commit stamped into the binary
(`EDLAZER_VERSION` and `EDLAZER_COMMIT`, or the pubspec fallback when those
defines are absent).

New builds are downloaded by hand from this fork's GitHub Releases. Installing
one does not go through an in-app downloader.
