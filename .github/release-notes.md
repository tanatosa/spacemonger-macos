Download **SpaceMonger-<version>.zip** below, unzip it and move **SpaceMonger.app** to Applications. Requires macOS 13 or later; runs natively on Apple Silicon and Intel.

**First launch:** this build is signed ad hoc, not notarized, so macOS blocks it the first time. Try to open it, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway** — or run once in Terminal:

```
xattr -dr com.apple.quarantine /Applications/SpaceMonger.app
```

The `.dSYM.zip` holds debug symbols for reading crash reports of this build; you don't need it to run the app.
