import AppKit

// Ask only our own native library to quit normally; never force-kill it.
for identifier in ["io.github.deavour31.alchemac", "local.alchemac"] {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
        guard app.terminate() else {
            fputs("Native library did not accept a normal Quit request.\n", stderr)
            exit(1)
        }
    }
}
