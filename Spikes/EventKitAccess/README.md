# EventKit access probe

This probe validates full calendar access for the same executable in two contexts: an interactive terminal run and a user LaunchAgent run.

It does not read event contents. Its output is limited to authorization state and aggregate calendar counts. Keep the output local because even aggregate counts are installation-specific.

From the repository root:

```sh
Scripts/build-eventkit-probe.sh
Scripts/run-eventkit-interactive-probe.sh
Scripts/run-eventkit-launch-agent-probe.sh
```

The interactive script starts the app through Launch Services so the permission belongs to the probe, not the terminal or development host. It may display the macOS calendar permission prompt for `Calopod EventKit Probe`. Do not approve a prompt naming any other app.

Only run the LaunchAgent check after the standalone probe has full access. The LaunchAgent script uses the already-built executable, prints its local result, and removes its temporary service and files before exiting.

An exit status of `0` means full calendar access is available. Status `3` means the process does not have full access. Other nonzero statuses indicate a build, launch, or runtime failure.
