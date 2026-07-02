<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!--
  This is the source of truth for the bundle metadata written into
  dist/pi-app.app/Contents/Info.plist. The packaging script
  (script/package_release.sh) substitutes the __TOKEN__ placeholders
  below with the values from its APP_NAME / BUNDLE_IDENTIFIER /
  EXECUTABLE_NAME / VERSION / BUILD_NUMBER environment variables and
  validates the result with plutil -lint. Add a new key here rather
  than duplicating the plist body into another file.
-->
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>__APP_NAME__</string>
    <key>CFBundleExecutable</key>
    <string>__EXECUTABLE_NAME__</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>__BUNDLE_IDENTIFIER__</string>
    <key>CFBundleName</key>
    <string>__APP_NAME__</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD_NUMBER__</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>pi-app launches terminal sessions in project folders you choose, including projects on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>pi-app launches terminal sessions in project folders you choose, including projects in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>pi-app launches terminal sessions in project folders you choose, including projects in Downloads.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>pi-app can record voice prompts and transcribe them into chat messages before sending them to Pi.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>100.100.11.0</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>homelab</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>homelab.ts.net</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>127.0.0.1</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>localhost</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
        </dict>
    </dict>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 ent-ini. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
