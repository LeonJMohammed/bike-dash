# Changelog

## Unreleased
- Step 3 (not yet tested on a ride): ride timer. Start, Pause/Resume and Hold to stop (1 s), auto-pause below 3.6 km/h for 4 s and auto-resume above 6.5 km/h for 2 s, moving time, a summary at the end (distance, times, average/max speed and heart rate). The ride is saved every 10 s and picked up again if the app closes. GPS warms up while the app is open and runs in the background only during a ride; the screen stays on during a ride. Replaces the Step 2 test buttons.
- Step 2 (not yet tested on a ride): GPS speed (km/h, 3 s average) and distance under the heart rate, with Start/Stop and Reset. Drops fixes worse than 20 m and GPS jumps; jitter while stopped adds no distance. Keeps tracking with the screen locked, and keeps the screen on while tracking.
- Installs over Wi-Fi work (2026-11-05).
- First signed install on the iPhone (2026-11-05). Builds now target the phone itself, so the free team can register it.
- Step 1 (works on the phone, 2026-11-05): live heart rate from the Forerunner 165's Bluetooth broadcast. Finds the remembered watch, one already connected through Garmin Connect, or scans; reconnects by itself; ignores other riders' straps once a watch is remembered; "--" after 5 s without data.
- Step 0: project skeleton (XcodeGen), BikeDashCore package with the heart rate packet parser, Mac build agent, PC helper, placeholder icon.
