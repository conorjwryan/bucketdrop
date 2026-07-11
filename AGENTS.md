# ShareMaster repository guidance

## Installing the macOS app

- Never install an unsigned or ad-hoc-signed build over `/Applications/ShareMaster.app`. Ad-hoc signing changes the app's identity and can remove its sandbox and keychain entitlements, making the existing destinations and accounts appear to be missing even though their data still exists in the sandbox container.
- Build the installable macOS app with the configured Apple Development team and automatic provisioning, for example: `xcodebuild -project ShareMaster.xcodeproj -scheme ShareMaster -configuration Release -derivedDataPath /tmp/sharemaster-signed-build -allowProvisioningUpdates build`.
- Before replacing the installed app, verify the new bundle with `codesign --verify --deep --strict --verbose=2` and inspect its entitlements. It must include `com.apple.security.app-sandbox`, the `HU9TH52NNC.com.cjwr.ShareMaster` application identifier, and the configured keychain access group.
- Confirm that `~/Library/Containers/com.cjwr.ShareMaster/Data/Library/Preferences/com.cjwr.ShareMaster.plist` still contains `config_accounts` and `config_destinations` before and after installation. Do not initialize, migrate, delete, or overwrite configuration while diagnosing an empty destination list.
- Keep the previous installed bundle as a temporary backup until the replacement has launched and the real `/Applications/ShareMaster.app` UI visibly shows the existing destinations.

## iOS development provisioning

- This project currently uses Xcode local provisioning for physical-device builds. Those profiles have a seven-day lifetime. A previously working iPhone build can stop launching when its embedded profile expires even though the Apple Development certificate, source, entitlements, and the user's earlier trust approval have not changed.
- Before diagnosing an **Untrusted Developer** or launch-signature error, decode the embedded and current profiles and compare their `CreationDate`, `ExpirationDate`, UUID, developer-certificate fingerprint, application identifier, entitlements, and provisioned device UDID.
- Do not restore an older build until its embedded profile has been checked; installing a known build whose profile has expired cannot recover the app.
- When Xcode replaces an expired local profile, iOS may require the newly provisioned developer app to be explicitly trusted again under **Settings → General → VPN & Device Management**, even if the user trusted an earlier profile. This approval must be performed on the iPhone and cannot be granted through Xcode or `devicectl`.
