on run arguments
    set volumeFolder to (POSIX file (item 1 of arguments)) as alias
    set appName to item 2 of arguments
    set pictureFile to (POSIX file ((item 1 of arguments) & "/.background/Installer.png")) as alias

    tell application "Finder"
        open volumeFolder
        set installWindow to container window of volumeFolder
        try
            set current view of installWindow to icon view
            set toolbar visible of installWindow to false
            set statusbar visible of installWindow to false
            set bounds of installWindow to {180, 160, 860, 590}
            set viewOptions to icon view options of installWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set label position of viewOptions to bottom
            set background picture of viewOptions to pictureFile
            set position of item appName of volumeFolder to {174, 132}
            set position of item "Applications" of volumeFolder to {506, 132}
            update volumeFolder without registering applications
        on error errorMessage number errorNumber
            close installWindow
            error errorMessage number errorNumber
        end try
        close installWindow
    end tell
end run
