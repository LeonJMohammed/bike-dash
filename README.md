# Bike Dash

A personal iPhone app for the handlebars. It shows heart rate from the Forerunner 165's Bluetooth broadcast, GPS speed, distance and moving time, and what Spotify is playing. The watch records the official Bike activity; this app is only the display.

It isn't on the App Store. It's signed with a free Apple ID (an Xcode personal team), so each signature lasts 7 days and the Mac re-signs it.

## How it fits together

```
PC (this repo)  --git push-->  MacBook Air (~/bike-dash)  --Wi-Fi-->  iPhone
edit + commit                  LaunchAgent builds and signs           runs Bike Dash
scripts\pc\mac.ps1             (in the logged-in session, so
                               no password is stored)
```

- `project.yml` defines the Xcode project ([XcodeGen](https://github.com/yonaskolb/XcodeGen)). The Mac generates `BikeDash.xcodeproj` before every build; it's never committed.
- `Packages/BikeDashCore` holds the logic that doesn't need a phone: heart rate packets now, ride maths later. Its tests run with `swift test` on the Mac.
- `BikeDash/` is the SwiftUI app. `Config/Info.plist` is its Info.plist.
- `scripts/` runs on the Mac; `scripts/pc/` runs on the PC.

## Everyday use (from the PC)

```powershell
.\scripts\pc\mac.ps1 build          # pushes, builds, installs over Wi-Fi
.\scripts\pc\mac.ps1 build -Launch  # same, then opens the app (phone unlocked)
.\scripts\pc\mac.ps1 test           # BikeDashCore unit tests on the Mac
.\scripts\pc\mac.ps1 status         # last build result and when the signature expires
```

Only committed code is built. The Mac's copy updates on every push (`receive.denyCurrentBranch updateInstead`), so never edit files there.

## First-time setup

### 1. On the Mac
1. Install Xcode from the App Store and open it once. Then Xcode > Settings > Accounts > + > Apple ID, and sign in.
2. System Settings > General > Sharing > **Remote Login**: on.
3. System Settings > Battery > Options > **Prevent automatic sleeping on power adapter when the display is off**: on.
4. Install Homebrew from <https://brew.sh> (paste its command into Terminal).
5. Let the PC in. In Terminal, with the PC's public key (`C:\Users\Joseph L Mohammed\.ssh\id_ed25519_mac.pub`) between the quotes:
   ```sh
   mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA... bike-dash@DESKTOP-HD72D9S' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   ```
6. Optional: install Tailscale and sign in, so the PC can reach the Mac by name anywhere.

### 2. From the PC
1. Add a `mac` host to `~/.ssh/config` (user name + Tailscale name or LAN address).
2. `.\scripts\pc\mac.ps1 setup` creates `~/bike-dash` on the Mac, installs XcodeGen and generates the project.
3. Put the team ID in `~/bike-dash/Config/Secrets.xcconfig` (copy `Secrets.example.xcconfig`).
4. Load the LaunchAgent with `ssh mac 'bash ~/bike-dash/scripts/install-agents.sh'` (this works over SSH), then run `.\scripts\pc\mac.ps1 check`.

### 3. On the Mac, once, with the iPhone plugged in
1. Unlock the iPhone and tap **Trust**.
2. Open `~/bike-dash/BikeDash.xcodeproj`, pick the iPhone at the top, and press Run. If a keychain prompt asks about `codesign`, type the Mac password and click **Always Allow**.
3. On the iPhone: Settings > Privacy & Security > **Developer Mode** on (it restarts). Then Settings > General > VPN & Device Management > trust the developer app.
4. From the PC: put the phone's identifier (`xcrun devicectl list devices`) in `~/.config/bike-dash/refresh.env` as `DEVICE_ID=...`, then `.\scripts\pc\mac.ps1 build -Launch` with the phone unplugged.

## Spotify
- The Music page uses the Spotify iOS SDK (App Remote) through the Spotify app. Spotify has to be playing to connect, so **Connect** opens Spotify, starts the music and comes back with a token that's good for an hour.
- The Spotify developer app needs the redirect URI `bikedash://spotify-login-callback` and the iOS bundle ID `com.jlmoh.bikedash`. Development mode requires the owner to have Premium and allows up to 5 users.
- The Client ID goes in `Config/Secrets.xcconfig` on the Mac as `SPOTIFY_CLIENT_ID`.

## Simulator screenshots
`ssh mac 'bash ~/bike-dash/scripts/sim-shot.sh <name> -demo ride|paused|finished|idle|history [-tab settings] [-page 1]'` builds for the iPhone simulator and saves `/tmp/bike-dash-<name>.png` on the Mac. Demo mode fakes the data and touches no hardware.

## Mac-only files (never in git)
- `~/bike-dash/Config/Secrets.xcconfig`: `DEVELOPMENT_TEAM`, later `SPOTIFY_CLIENT_ID`
- `~/.config/bike-dash/refresh.env`: `DEVICE_ID`, later `NTFY_TOPIC` and `HC_PING_URL`
- `~/.config/bike-dash/state.json`: when the installed build's signature expires
- Logs: `~/Library/Logs/bike-dash/` (one log per build request, plus `xcodebuild.log`)

## Free signing limits
- A signature lasts 7 days. The re-sign job comes once a test shows whether an early rebuild resets the 7 days.
- 3 sideloaded apps per phone and 10 App IDs per 7 days: don't add app extensions or test-host targets.
- No push notifications or iCloud.
