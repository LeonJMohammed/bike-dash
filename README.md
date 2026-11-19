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
   - And System Settings > Lock Screen > **Require password after screen saver begins or display is turned off: Never** (18 Nov 2026; the MacBook stays home). Locked, the Mac keeps Xcode's saved sign-in out of reach, so a re-sign build that runs then can't read it and Xcode drops the Apple ID (see "Why Xcode signed out" below). The option is greyed out while iPhone Mirroring is set to authenticate automatically: switch that to Ask Every Time first (iPhone Mirroring > Settings). Check with `sysadminctl -screenLock status` ("screenLock is off").
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
- **Laps:** auto lap every 5 km to start (Settings > Ride > Auto lap: off, 1, 2, 5, 10 or 20 km, counted from the last lap), and a LAP button while riding (History's button waits until the ride is over, to make room). When a lap ends, its distance, moving time, average speed, heart rate and cadence (while pedalling) replace the ride numbers for 5 seconds (a tap goes back sooner), and a dimmed screen brightens. Moving time only. Every lap, with the last stretch as the final one, is saved with the ride; the ride summary and History list the splits when there are two or more. Simulator: `-demo lap` shows a lap, `-demo finished` the splits.
- **Live Activity** (the `BikeDashWidgets` extension, App ID `com.jlmoh.bikedash.widgets`): starts with the ride and ends when it stops. The lock screen shows speed, heart rate, ride time and distance; the Dynamic Island shows speed and heart rate, and its expanded view adds ride time, distance and cadence. Paused shows PAUSED in yellow with the time frozen. The ride clock counts up on its own; everything else updates at most every 5 seconds and only when a number changes (a pause or resume at once), from the app itself while it runs during the ride, so no push. A tap opens the ride screen (`bikedash://ride`). The data lives in `RideActivityState` and the throttle in `LiveActivityThrottle` (BikeDashCore); `Shared/` is compiled into both targets. The re-sign job sets aside and checks both targets' profiles.
- **Refresh rate:** the ride screen redraws once a second and has no continuous animations, so a ProMotion iPhone drops to its lowest refresh rate by itself. A `CADisplayLink` with a low `preferredFrameRateRange` wasn't added: it can only ask for frames, not cap what other views request, so it would keep the display ticking instead of idling.

## Spotify
- The music bar under the numbers uses the Spotify iOS SDK (App Remote) through the Spotify app. Spotify has to be running to connect; **Connect** / **Reconnect** opens Spotify, starts the music and comes back.
- **Signing in once** (Settings > Spotify > Sign in, or SIGN IN on the music bar) opens Spotify's sign-in page in a sheet. The code that comes back is swapped for tokens by the **token service on the home PC**, which holds the client secret. The refresh token (sealed by the service, useless without it) is kept in the iOS Keychain with the current access token; before connecting, Bike Dash refreshes an access token that has under 5 minutes left. If the PC can't be reached it keeps the refresh token and tries later; only Spotify refusing it ("invalid_grant") signs Bike Dash out. Logic and tests: `BikeDashCore/SpotifyAuth.swift`.
- **Retries**: when App Remote fails or drops while Bike Dash is in front, it tries again after 2, 5 and 15 seconds, then every 30 seconds; after the quick tries the music bar says **Reconnect Spotify**. Nothing retries in the background (Spotify asks apps to let go there), and coming back to the front starts the 2-5-15 again.
- Demo: `-demo ride -spotifyDemo reconnect` shows the prompt.

### Spotify token service (home PC)
- `server/spotify-token-service.js`, plain Node (no packages), port 3010, at `https://jlmoh.com/bike-dash/spotify/` through the Cloudflare Tunnel: `POST swap` (`code`), `POST refresh` (`refresh_token`), `GET health`. Tests: `node --test server/spotify-token-service.test.js server/strava-routes.test.js`. The same service also serves the Strava routes (below).
- Secrets in `server/.env` (git-ignored; see `server/.env.example`): `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `TOKEN_KEY` (32 random bytes, base64; a new key signs the app out). `health` answers `{"ok":false}` until all three are set.
- Started by the Landing Hub (`landing\startup.ps1`, launcher `landing\bike-dash-spotify.ps1`, window "Bike Dash Spotify"); stopped by `restart.ps1`; watched by the System Monitor ("Bike Dash Spotify", recovers by running Home Startup). Tunnel route in `.cloudflared\config.yml`.
- Cloudflare Access covers jlmoh.com, so `jlmoh.com/bike-dash/spotify` needs a **Bypass** Access application, like `/funnies`. Without it the app gets Access's login redirect, which it treats as "try later".
- It never logs codes or tokens; 30 requests a minute per address; 4 KB bodies.
- The Spotify developer app needs the redirect URI `bikedash://spotify-login-callback` and the iOS bundle ID `com.jlmoh.bikedash`. Development mode requires the owner to have Premium and allows up to 5 users.
- The Client ID goes in `Config/Secrets.xcconfig` on the Mac as `SPOTIFY_CLIENT_ID`.

## Routes
- **Opening it:** the **map** button next to History opens Routes. Like History, it's only there when no ride is under way. The button turns cyan while a route is picked for the next ride.
- **What's listed:**
  - The route picked for the next ride.
  - The routes saved **on this phone**.
  - Your **Strava bike routes**, then your run routes, from the home PC (below).
  - Pull down to refresh.
- **The preview:** tapping a route shows its line on a dark map, its distance and climb (Strava's figures) and an elevation profile from the GPX. **USE FOR NEXT RIDE** saves the GPX in `Application Support/routes/` with an `index.json` and picks the route.
- **Without signal:** a saved route opens with no connection at all, so it still works with Airplane mode on. The Strava list then explains it can't reach the PC.
- **The map itself can't be saved.** MapKit has no way to download map tiles ahead of time, and apps can't use the maps downloaded in Apple Maps. Without signal, the route line, your position and the warnings still work, but the map underneath may be blank. The preview says so.
- **One ride only (Leon's choice):** the pick clears when the ride ends, so the next ride is a normal one with GPS off unless a route is picked again. The route stays saved on the phone.
- **Core logic:** `BikeDashCore` has `Route` (the GPX reader, length, climb with a 2 m threshold, profile, the point at a distance), `RouteTracker` and `StravaRoute`.
- **How `RouteTracker` follows the rider:**
  - It works out how far along the route the rider is and how far off it, and looks near the last position first. That keeps the way out and the way back of an out-and-back apart, and starts a loop at its start.
  - It looks over the whole route only when nothing nearby fits, for example after a shortcut.
  - It compares only the places where the route passes closest to the rider, not every segment's end. Otherwise the end of the segment just behind always looks like a tie.
  - Between parts of the route that are about as close, it picks the one nearest the last progress. Going backwards counts three times over.
  - A part pointing against the rider's heading counts as 100 m further away. The heading comes from the phone's GPS course, or from the last fixes 8 m or more apart. Strava draws the way back of an out-and-back on the very same line, so without this, GPS error along the road at the turnaround could make it follow the way out backwards. It's a cost, not a filter, so a wrong heading from GPS noise can't throw progress far along the route.
  - **Checked against a real route:** Leon's Brian Lara Cricket Academy Loop (23.2 km, 358 points, several out-and-backs), ridden in simulation with 8 m of GPS error in each direction, a drifting error and random jitter. Progress stays within about 35 m (within 27 m with the GPS course) and never runs backwards.
- **Demo:** `-demo idle -sheet routes [-page routePreview]` shows four listed routes and a picked Savannah loop.

### Routes service (home PC)
The same PC service, the same port 3010 and the same launcher also serve your saved Strava routes for the Routes screen, at `https://jlmoh.com/bike-dash/routes/`. The code is in `server/strava-routes.js` and the tests are in `server/strava-routes.test.js`.
- **Endpoints:**
  - `GET list` returns `{ routes: [{ id, name, kind (ride/run), distance_m, elevation_gain_m, updated_at, private, starred, summary_polyline, … }], private_hidden }`, newest first.
  - `GET <id>/gpx` returns the route as GPX.
  - `GET health` returns `{ ok, configured, read_all[, error] }`.
- **Route ids are strings.** Strava's numeric ids are too big for JSON numbers, so the service passes on `id_str`.
- **Strava access comes from Race Tracker.** Race Tracker holds the only Strava connection: Strava allows one API app per account, and a refresh can swap the refresh token for a new one, which two copies wouldn't survive. The service borrows a short-lived access token from Race Tracker over localhost (`POST /race-tracker/api/strava/token` with `x-bike-dash-secret`). It caches the token until a minute before it runs out.
- **Private routes need the `read_all` scope** on that connection. Without it, `list` shows only public routes and says `private_hidden: true`, and `health` says `needs_read_all`. To add it, run `npm run setup-strava -- --reauth` in `race-tracker` and approve on Strava's page.
- **Only Bike Dash can call `list` and `gpx`.** They need `Authorization: Bearer <app key>`. The key is sealed with `TOKEN_KEY` like Spotify's refresh token, and holds `ROUTES_KEY_ID`. Make one with `node server/spotify-token-service.js mint-routes-key`; it adds `ROUTES_KEY_ID` to `.env` the first time. It goes on the Mac in `Config/Secrets.xcconfig` as `BIKE_DASH_ROUTES_KEY`. A new `ROUTES_KEY_ID` retires every old key.
- **Secrets in `server/.env`:**
  - `RACE_TRACKER_SECRET`: the same value as `BIKE_DASH_SECRET` in Race Tracker's `.env`.
  - `ROUTES_KEY_ID`.
- **Access and monitoring:**
  - The tunnel route is in `.cloudflared\config.yml`.
  - `jlmoh.com/bike-dash/routes` needs the Cloudflare Access **Bypass**, like the Spotify path.
  - The System Monitor check is "Bike Dash Routes" (`health` must say `"ok":true`). It isn't marked for recovery, because a restart can't fix a Strava permission.
- **Logging and limits:**
  - It never logs the app key or Strava tokens.
  - It shares the Spotify paths' limit of 30 requests a minute per address.
  - GPX files are capped at 15 MB.

## Simulator screenshots
`ssh mac 'bash ~/bike-dash/scripts/sim-shot.sh <name> -demo ride|fallback|paused|finished|idle|history [-sheet history|settings] [-page sensors|sensorData]'` builds for the iPhone simulator and saves `/tmp/bike-dash-<name>.png` on the Mac. Demo mode fakes the data and touches no hardware; the ride scenes send the packets the sensors would, so the sensor maths runs as on the bike, and `fallback` has the speed sensor switched off.

## Mac-only files (never in git)
- `~/bike-dash/Config/Secrets.xcconfig`: `DEVELOPMENT_TEAM`, `SPOTIFY_CLIENT_ID`, `BIKE_DASH_ROUTES_KEY` (the routes app key from the PC)
- `~/.config/bike-dash/refresh.env` (mode 600): `DEVICE_ID`, `NTFY_SERVER`, `NTFY_TOPIC`, `HC_PING_URL`
- `~/.config/bike-dash/state.json`: when the installed build's signature expires
- Logs: `~/Library/Logs/bike-dash/` (one log per build request, plus `xcodebuild.log`)

## Staying signed (the 7-day limit)
- **When it runs (evenings, since 18 Nov 2026):** the MacBook's LaunchAgent starts every 15 minutes on the quarter hour (`StartCalendarInterval`) and at login, and `scripts/refresh.sh --scheduled` decides whether to do anything:
  - **Evenings:** at most once in each hour from 20:00 to 23:59, so 20:00 with 21:00, 22:00 and 23:00 as the retries when the iPhone wasn't home or unlocked. A slot missed while the Mac slept is taken when it wakes if that's still the evening (a wake at 21:30 tries then, and again at 22:00). Until a re-sign is due, the first run each evening only checks (silently unless something's wrong).
  - **The night before it runs out** (under 28 hours left, 8 pm to 8 am): every run tries, so every 15 minutes through the night, and each one that can't re-sign sends its reminder at high priority, until it's re-signed or has run out. 28 hours covers the whole night before an evening expiry.
  - **Any other time** it does nothing, so launchd catching up at a morning wake waits for the evening.
- **Tailscale** (18 Nov 2026): every agent run first checks that Tailscale is on (`Tailscale status`) and turns it back on with `Tailscale up` if it's off, starting the app if needed; `refresh.log` says when it did. An app update on 15 Nov had left it switched off for three days, so the PC couldn't reach the MacBook. If Tailscale needs signing in, it can't fix that and says so in the log.
- **What it does:** from the evening of day 5 (under 3.5 days left), so the evenings of days 5, 6 and 7 come before it runs out and none of them is a morning, it first checks what a re-sign needs: Xcode signed in to the Apple ID, the iPhone reachable, and the iPhone's development services up (they only start while it's unlocked). Then it sets Xcode's cached profile aside so Apple issues a fresh 7-day one, and builds and reinstalls over Wi-Fi. A plain rebuild would keep the old expiry. Tested on 5 Nov 2026: a new profile came back, valid 7 days from the renewal.
- **ntfy alerts** (the system monitor's topic), only from 8 pm to midnight, or through the night before it runs out, whatever starts the run (a run by hand during the day holds them for the evening; `mac.ps1 testalert` is the exception):
  - "Bike Dash re-signed" when it works.
  - When it can't, the alert says what to do: "Unlock your iPhone for Bike Dash", "Bike Dash needs re-signing" (the MacBook can't see the iPhone: be home on Wi-Fi), "Bike Dash can't re-sign" (Xcode is signed out: Xcode > Settings > Accounts), "re-sign failed" (with the error) or "didn't extend".
  - Each kind at most every 8 hours (so once an evening), and high priority in the last day; the night before it runs out, every 15 minutes at high priority.
- **Xcode's sign-in, checked early** (13 Nov 2026, after Xcode lost the Apple ID twice in a week): the evening check also looks at Xcode's sign-in while no re-sign is due. Signed out, ntfy says "Xcode signed out: Bike Dash can't re-sign", with the evening the re-sign starts, under the same rules (it shares the "signedout" kind). Once it's signed in again, a quiet "Xcode is signed in again". `~/.config/bike-dash/xcode-signed-out` marks the signed-out state between runs.
- **Why Xcode signed out** (found 18 Nov 2026): it lost the Apple ID whenever a build needed Apple while the Mac was locked (display off, or a DarkWake with the lid shut). Xcode's saved sign-in is in the keychain, which macOS keeps out of reach while locked; xcodebuild then logged "DVTDeveloperAccountManager: Failed to load credentials … Invalid credentials in keychain" (11 Nov) or "No Accounts" (16 Nov, `classALocked == 1` in the system log) and dropped the account. Builds with the Mac unlocked (14 and 18 Nov) were fine. The fix is in Mac setup step 3: no password after the display turns off, so it never counts as locked. If it signs out again, check that setting first (a macOS update or iPhone Mirroring can turn it back on).
- **When the MacBook is asleep or off,** it can't re-sign or warn you, so the PC watches too. That's `scripts\pc\resign-watch.ps1`, run every 10 minutes by the task "Bike Dash Re-sign Watch".
  - Whenever it can reach the MacBook, it copies the expiry from `state.json` into `pc-data\resign-watch.json`. That folder is gitignored and also holds its log.
  - When a re-sign is due (the same 3.5 days) and it hasn't reached the MacBook for 30 minutes, ntfy says "Bike Dash: open the MacBook". That's only between 8 pm and midnight, at most every 8 hours, high priority in the last 12 hours, and once a day after it has expired. The night before it runs out (under 28 hours left, 8 pm to 8 am) it repeats every 15 minutes through the night at high priority (every 20 in practice, since it runs every 10).
  - While the MacBook can be reached it stays quiet, and the alerts above cover the rest.
- **Healthchecks.io:** the "Bike Dash refresh" check is pinged after every run, so days with the MacBook off alert too.
- **By hand:**
  - `mac.ps1 refresh` checks now, and `mac.ps1 refresh -Force` renews now.
  - `mac.ps1 testalert` sends a test alert.
  - `resign-watch.ps1` on the PC:
    - `-Dry` shows what the watch sees; add `-PretendNow '2026-11-11 08:00'` or `-PretendOffline` to try other cases.
    - `-Test` sends a test alert, and `-Register` sets up its task.
    - `-SetExpiry '<date time>'` tells it the expiry while the MacBook can't be reached.
  - Over SSH, `refresh.sh --dry-run [--scheduled] [--pretend-expiry <epoch>] [--pretend-signed-out] [--pretend-hour <0-23>] [--device <id>]` shows what it would do.
  - `scripts/profiles.sh` lists the cached profiles.
- Profiles that were set aside stay in `~/.config/bike-dash/profile-backup/`. The app's Settings shows "Signed until".

## Free signing limits
- 3 sideloaded apps per phone and 10 App IDs per 7 days. Bike Dash uses two App IDs (the app and its Live Activity extension); don't add more extensions or test-host targets without a reason.
- No push notifications or iCloud.
