# Changelog

## Unreleased
- First signed install on the iPhone (2026-11-05). Builds now target the phone itself, so the free team can register it.
- Step 1 (works on the phone, 2026-11-05): live heart rate from the Forerunner 165's Bluetooth broadcast. Finds the remembered watch, one already connected through Garmin Connect, or scans; reconnects by itself; ignores other riders' straps once a watch is remembered; "--" after 5 s without data.
- Step 0: project skeleton (XcodeGen), BikeDashCore package with the heart rate packet parser, Mac build agent, PC helper, placeholder icon.
