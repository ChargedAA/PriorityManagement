# PriorityManagement

A small macOS app that lets you choose how much CPU each app gets, with simple sliders. It also turns your dock icon into a party parrot that can dance to your music.

## What it does

**Priority sliders.** Every running app gets a slider from 0% to 100%. Everything starts at 50%, which is normal priority. Lower means the app yields to others, higher means it gets more attention from the CPU. You can drag the slider, type a number in the box next to it, or double-click the slider to snap back to 50%. The dot changes color from green to red as the value changes.

**Search.** The bar at the top filters the list as you type.

**Reset All.** Sets every app back to 50%.

**Deprioritize Background.** Drops every background process to 0% in one click, so the apps you are using get more of the CPU.

**Quit and Force Quit.** Hover over a row to quit or force quit that app.

**Parrot.** The slider at the bottom chooses what the dock icon does:
- **Off:** a still icon.
- **Dancing:** the parrot dances at a steady pace.
- **Music sync:** the parrot follows whatever your Mac is playing. It finds the tempo and the bar lines, switches its moves on the first beat of a bar, and speeds up or slows down with the energy of the song.

## First launch: the permission prompt

Changing priority needs administrator rights. The first time you open the app, it explains this and offers a one-time setup. If you click **Set Up**, macOS asks for your password once, and the app adds a rule to your Mac that lets your account run `/usr/bin/renice` without a password. That is all the rule allows. It cannot run any other command.

If you click **Not Now**, the app still works, but priority changes will fail until you set it up. The prompt returns the next time a change fails.

To undo it, click the **trash button** in the bottom bar. It asks you to confirm, then removes the rule. (The button only appears while the rule is installed.)

## Music sync permission

Music sync listens to your Mac's audio output, not your microphone, and nothing is recorded or sent anywhere. macOS asks you to allow audio capture the first time you pick Music sync. The other two parrot modes never use audio. After rebuilding the app yourself, macOS may ask again.

## Install

Download the installer for your Mac from the Releases page:

- **Apple silicon (M1 and newer):** `PriorityManagement-1.0-arm64.dmg` or `.zip`
- **Intel:** `PriorityManagement-1.0-x86_64.dmg` or `.zip`

Open the .dmg and drag the app into Applications (or unzip the .zip and move the app there). The app is not notarized, so the first time you open it, right-click it and choose **Open**. If macOS still blocks it, run `xattr -dr com.apple.quarantine /Applications/PriorityManagement.app`.

Requires macOS 14.4 or later.

## Build it yourself

You need the Xcode command line tools.

    ./build.sh          # builds and installs to /Applications
    ./package.sh 1.0    # builds the .zip and .dmg installers into dist/

## Troubleshooting

Debug logging is off by default. To turn it on:

    defaults write com.example.prioritymanagement debugLog -bool true

The log is written to `~/Library/Logs/PriorityManagement/beatengine.log`.

## License

MIT
