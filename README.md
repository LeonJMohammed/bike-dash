# Bike Dash

A personal iPhone app for the handlebars. It shows heart rate from the Forerunner 165's Bluetooth broadcast, speed, distance and cadence from two Bluetooth bike sensors (GPS only as a fallback), moving time, and what Spotify is playing. The watch records the official Bike activity and the GPS route; this app is only the display.

It isn't on the App Store. It's signed with a free Apple ID (an Xcode personal team), so each signature lasts 7 days and the Mac re-signs it.

## How it fits together

```
PC (this repo)  --git push-->  MacBook Air (~/bike-dash)  --Wi-Fi-->  iPhone
edit + commit                  LaunchAgent builds and signs           runs Bike Dash
scripts\pc\mac.ps1             (in the logged-in session, so
                               no password is stored)
```

- `project.yml` defines the Xcode project ([XcodeGen](https://github.com/yonaskolb/XcodeGen)). The Mac generates `BikeDash.xcodeproj` before every build; it's never committed.
- `Packages/BikeDashCore` holds the logic that doesn't need a phone: heart rate and speed/cadence sensor packets, the ride maths and the GPS fallback rule. Its tests run with `swift test` on the Mac.
- `BikeDash/` is the SwiftUI app. `Config/Info.plist` is its Info.plist.
- `scripts/` runs on the Mac; `scripts/pc/` runs on the PC.

## Everyday use (from the PC)

```powershell
.\scripts\pc\mac.ps1 build          # pushes, builds, installs over Wi-Fi
.\scripts\pc\mac.ps1 build -Launch  # same, then opens the app (phone unlocked)
.\scripts\pc\mac.ps1 test           # BikeDashCore unit tests on the Mac
.\scripts\pc\mac.ps1 status         # last build result and when the signature expires
.\scripts\pc\mac.ps1 refresh -Force # renew the 7-day signature now
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

## Speed and cadence sensors
- Two Magene S3+ sensors, one on the front hub set to speed and one on the left crank set to cadence. They send ANT+ to the watch and standard Bluetooth (Cycling Speed and Cadence, 0x1816) to the phone at the same time.
- **Pairing:** Settings > Pair sensors scans, connects to what it finds and shows what each one sends, read from the data (wheel or crank) rather than the name. "Use for speed" or "Use for cadence" saves it. Paired sensors reconnect by themselves whenever they wake up (spin the wheel or turn the crank).
- **One connection each:** a sensor takes one Bluetooth connection at a time, so other apps that use it (such as Cadence) must be closed. The watch uses ANT+ and isn't affected.
- **The maths:** speed is wheel turns × circumference ÷ time between the sensor's own event times; cadence is crank turns ÷ time × 60. Repeated packets are ignored, the 64 s event clock and the turn counts wrap correctly, and the speed or cadence reads 0 after 3 s without a new turn. The first turn after a stop or a reconnect counts for distance but gives no speed.
- **Settings:** Speed from Sensor (default) or GPS, and the wheel circumference in mm (2105, for 700x25, by default).
- **GPS fallback:** with Sensor chosen, GPS stays off. During a ride it takes over once the speed sensor has been disconnected for 10 s (GPS FALLBACK at the top), and hands back once the sensor has been connected again for 5 s. While auto-paused it only starts if the cadence sensor shows pedalling, so a long stop with the sensors asleep doesn't switch it on. If the phone is locked or Bike Dash is in the background when the sensor drops, iOS may hold GPS back until Bike Dash is open again.
- **Auto-pause with the sensor:** it pauses as soon as the wheel stops (no turn for 3 s), counted from its last turn, and resumes as soon as it turns again.
- **Sensor data** (Settings) shows the raw values: packets, flags, turn counts, event times, the last interval and what they work out to.

## Ride theme
- **OLED black** (the default) keeps every pixel off except the ones that mean something: the numbers, the status dots and alerts. Buttons are outlines, and the music bar is black unless "Album colour behind the music" is on. **Standard** is the earlier look, with filled buttons and the album-coloured bar.
- **Dimming** (Settings > Display, on by default): during a ride the screen dims after 10 seconds without a touch, to the "Dimmed brightness" level (20% to start; the slider shows the level while you drag it). Any touch anywhere brightens it again, and laps, eating reminders and heart rate zone changes will too as they arrive (`RideController.wakeScreen()`). The brightness goes back to normal when the ride ends, or when Control Center, a call or another app covers Bike Dash. A screen that's already darker than the level is left alone. The screen never locks during a ride.
- **Heart rate zone strip** along the very bottom: five zones (grey, blue, green, orange, red) from the max heart rate in Settings > Heart rate, at 50, 60, 70, 80 and 90% of max. The current zone is lit and the others dimmed, a white marker shows where the heart rate sits inside it, and there are no numbers. The lit zone only moves on once the heart rate is 2 bpm past a boundary, so it doesn't flicker, and a new zone brightens a dimmed screen. Hidden (its space kept) without a heart rate; below 50% of max nothing is lit and the marker waits at the left.
- **Eat / Drink reminders** (Settings > Eating and drinking, off to start; every 15 to 60 minutes in 5-minute steps, 30 to start): count moving time only, so they wait while the ride is paused. When one is due, an orange "EAT / DRINK" banner covers the top of the ride screen with a buzz and the tri-tone chime (no chime with the ringer off), and the screen brightens and stays bright while it's up. A tap dismisses it, or it clears after 15 seconds; either way the countdown starts again from then. Switching reminders on mid-ride starts a full interval from that moment. Simulator: `-demo ride -eatDrinkReminders 1 -eatDrinkInterval 15` shows the banner.
- **Refresh rate:** the ride screen redraws once a second and has no continuous animations, so a ProMotion iPhone drops to its lowest refresh rate by itself. A `CADisplayLink` with a low `preferredFrameRateRange` wasn't added: it can only ask for frames, not cap what other views request, so it would keep the display ticking instead of idling.

## Spotify
- The music bar under the numbers uses the Spotify iOS SDK (App Remote) through the Spotify app. Spotify has to be playing to connect, so **Connect** opens Spotify, starts the music and comes back with a token that's good for an hour.
- The Spotify developer app needs the redirect URI `bikedash://spotify-login-callback` and the iOS bundle ID `com.jlmoh.bikedash`. Development mode requires the owner to have Premium and allows up to 5 users.
- The Client ID goes in `Config/Secrets.xcconfig` on the Mac as `SPOTIFY_CLIENT_ID`.

## Simulator screenshots
`ssh mac 'bash ~/bike-dash/scripts/sim-shot.sh <name> -demo ride|fallback|paused|finished|idle|history [-sheet history|settings] [-page sensors|sensorData]'` builds for the iPhone simulator and saves `/tmp/bike-dash-<name>.png` on the Mac. Demo mode fakes the data and touches no hardware; the ride scenes send the packets the sensors would, so the sensor maths runs as on the bike, and `fallback` has the speed sensor switched off.

## Mac-only files (never in git)
- `~/bike-dash/Config/Secrets.xcconfig`: `DEVELOPMENT_TEAM`, later `SPOTIFY_CLIENT_ID`
- `~/.config/bike-dash/refresh.env` (mode 600): `DEVICE_ID`, `NTFY_SERVER`, `NTFY_TOPIC`, `HC_PING_URL`
- `~/.config/bike-dash/state.json`: when the installed build's signature expires
- Logs: `~/Library/Logs/bike-dash/` (one log per build request, plus `xcodebuild.log`)

## Staying signed (the 7-day limit)
- **When it runs:** the MacBook's LaunchAgent runs `scripts/refresh.sh` at login and every 15 minutes. Until a re-sign is due it only checks every 3 hours (and stays silent in between); once due it tries every time, so it catches a moment when the iPhone is home and unlocked. A run missed while the Mac sleeps happens when it wakes.
- **What it does:** once less than 3 days are left, it first checks what a re-sign needs: Xcode signed in to the Apple ID, the iPhone reachable, and the iPhone's development services up (they only start while it's unlocked). Then it sets Xcode's cached profile aside so Apple issues a fresh 7-day one, and builds and reinstalls over Wi-Fi. A plain rebuild would keep the old expiry. Tested on 5 Nov 2026: a new profile came back, valid 7 days from the renewal.
- **ntfy alerts** (the system monitor's topic):
  - "Bike Dash re-signed" when it works.
  - When it can't, the alert says what to do: "Unlock your iPhone for Bike Dash", "Bike Dash needs re-signing" (the MacBook can't see the iPhone: be home on Wi-Fi), "Bike Dash can't re-sign" (Xcode is signed out: Xcode > Settings > Accounts), "re-sign failed" (with the error) or "didn't extend".
  - Each kind at most every 8 hours, only 7 am to 10 pm unless it runs out within 6 hours, and high priority in the last day.
- **When the MacBook is asleep or off,** it can't re-sign or warn you, so the PC watches too. That's `scripts\pc\resign-watch.ps1`, run every 10 minutes by the task "Bike Dash Re-sign Watch".
  - Whenever it can reach the MacBook, it copies the expiry from `state.json` into `pc-data\resign-watch.json`. That folder is gitignored and also holds its log.
  - When a re-sign is due and it hasn't reached the MacBook for 30 minutes, ntfy says "Bike Dash: open the MacBook". That's only between 7 am and 10 pm, at most every 8 hours, high priority in the last 12 hours, and once a day after it has expired.
  - While the MacBook can be reached it stays quiet, and the alerts above cover the rest.
- **Healthchecks.io:** the "Bike Dash refresh" check is pinged after every run, so days with the MacBook off alert too.
- **By hand:**
  - `mac.ps1 refresh` checks now, and `mac.ps1 refresh -Force` renews now.
  - `mac.ps1 testalert` sends a test alert.
  - `resign-watch.ps1` on the PC:
    - `-Dry` shows what the watch sees; add `-PretendNow '2026-11-11 08:00'` or `-PretendOffline` to try other cases.
    - `-Test` sends a test alert, and `-Register` sets up its task.
    - `-SetExpiry '<date time>'` tells it the expiry while the MacBook can't be reached.
  - Over SSH, `refresh.sh --dry-run [--pretend-expiry <epoch>] [--device <id>]` shows what it would do.
  - `scripts/profiles.sh` lists the cached profiles.
- Profiles that were set aside stay in `~/.config/bike-dash/profile-backup/`. The app's Settings shows "Signed until".

## Free signing limits
- 3 sideloaded apps per phone and 10 App IDs per 7 days: don't add app extensions or test-host targets.
- No push notifications or iCloud.
