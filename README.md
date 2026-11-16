# AlpineiOS

<img src="ios/Sources/Resources/Brand.xcassets/AlpineMark.imageset/AlpineMark.png" alt="AlpineiOS app icon" width="112">

AlpineiOS runs a local ARM64 postmarketOS virtual machine inside an iPhone app. The guest boots Phosh and sends VirtIO GPU frames to Metal.

<img src="docs/images/phosh-app-grid.png" alt="Phosh application grid in the AlpineiOS guest" width="240">

## Requirements

- **Tested device:** iPhone 14 Pro with iOS 27.0. The app targets iOS 17. VM and JIT compatibility on other devices and OS versions is unverified.
- **Build and launch:** Apple silicon Mac, Xcode with support for the connected iPhone (tested with Xcode 27.2), Homebrew, an Apple development team for signing and Developer Mode on the iPhone.
- **Storage and network:** Allow at least 5 GB of free space on the phone for the roughly 1.9 GB download, unpacking and apps. The initial setup and package installs need internet access.

The VM uses one CPU and a display sized to match the app window, with automatic Phosh scaling and landscape support on iPad. RAM is selected from the host capacity, with 2 GB on devices in the 6 GB class or higher and 1.5 GB on smaller devices or if the larger preallocation fails. The local experimental graphics path uses VirGL, ANGLE and Metal. Audio output uses VirtIO Sound and the iOS audio session.

The experimental build bundles a Mesa 26.1.6 guest driver with VirGL enabled. The build script prepares it in a separate ARM64 QEMU VM on the Mac; the first build needs internet access, about 4 GB of available RAM and several minutes. Guest installation uses the bundled archive through the internal shared-files service. Native Metal scanout copies frames on the GPU and avoids the CPU readback path when supported. Desktop animations remain enabled.

The download includes Phosh and Settings. Firefox, Files (Nautilus), and GNOME Console are selected by default. Telegram Desktop, Mousepad, and htop are optional.

## Running without a Mac, and the JIT requirement

Building needs macOS, but running does not: a sideloaded development-signed build
can enable JIT on the phone itself with StikDebug. See
[docs/NO-MAC.ru.md](docs/NO-MAC.ru.md) (Russian).

The VM cannot run without JIT. The engine translates guest ARM64 code into host
ARM64 code and needs executable pages, so a debugger-blessed JIT region is part
of the execution model, not an optional accelerator. A true no-JIT build would
require an ARM64 interpreter backend; [docs/NO-JIT.ru.md](docs/NO-JIT.ru.md)
explains the scope and why Kernarium's UML approach is not a drop-in
replacement.

## Download and install from the app

On the first launch, choose the apps you want and tap **Download and install**. The default image is hosted on GitHub Releases. [Phosh image downloads](https://github.com/Lumid-Off/AlpineiOS-images/releases/tag/phosh-26.06-r1) AlpineiOS verifies the assets with SHA-256, unpacks the disk, then boots when JIT is available. The guest downloads the selected apps after boot. You can choose a local password for `user` and `doas`, or leave it blank to generate one. The current password is in **Help**.

Open **Installation log** to see download stages, transferred bytes and Linux package output. The log stays available after errors and can be shared from its toolbar. During Linux setup, tap the installation status at the bottom of the screen to open it.

Set `ALPINE_IMAGE_MANIFEST_URL` at build time to use a different default URL. To create and stage the assets for your own server, run these commands on an Apple silicon Mac with QEMU and Python installed.

```sh
bash scripts/prepare_phosh.sh --downloadable work/PhoshRelease
python3 scripts/publish_phosh_image.py work/PhoshRelease work/PhoshAssets
```

Host the contents of `work/PhoshAssets` together and use the URL ending in `phosh.json`. For a test on your own Wi-Fi, serve that directory with `python3 -m http.server 8765 --directory work/PhoshAssets` and use `http://YOUR-MAC.local:8765/phosh.json` in the app. A published build should use an HTTPS URL.

## Build and manual import

Omit `ALPINE_IMAGE_MANIFEST_URL` to use the default GitHub image. Local VM preparation is optional when using an already hosted image.

1. Install the build dependencies and provision a machine.

   ```sh
   brew install qemu xcodegen meson ninja pkg-config python
   bash scripts/prepare_phosh.sh
   ```

2. Pair your iPhone with Xcode and enable Developer Mode. Build with your Apple development team and choose a unique bundle ID. [Apple Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

   ```sh
   export ALPINE_BUNDLE_ID=com.example.alpineios
   ALPINE_IMAGE_MANIFEST_URL=https://example.com/phosh.json \
     ALPINE_DEVELOPMENT_TEAM=YOUR_TEAM_ID bash scripts/build_alpine_ios.sh

   xcrun devicectl list devices
   xcrun devicectl device install app --device YOUR_IPHONE_UDID \
     build/DerivedData/Build/Products/Release-iphoneos/WindowsiOS.app
   ```

3. Open the app once. In the iPhone Files app or Finder File Sharing, open **AlpineiOS** and create `Machines/PostmarketOS-Native` if needed. Copy `code.fd`, `vars.fd`, `seed.img` and either `alpine.hvsparse` or `alpine.img` from `work/PostmarketOS-Native`. Keep `login.txt` private. It contains the generated console password for `user`.
4. Unlock the paired iPhone and run the launch script. The app can boot once JIT is active and the VM files are present. Repeat this command after iOS terminates the app.

   ```sh
   bash scripts/launch_on_iphone.sh YOUR_IPHONE_UDID "$ALPINE_BUNDLE_ID"
   ```

Run the build script without `ALPINE_DEVELOPMENT_TEAM` to produce an unsigned `build/AlpineiOS.ipa`. The release IPA is unsigned. Build and development-sign it with your own Apple team to use the debugger-assisted launch above. The release includes the dependency sources used to build the IPA.

If a signer cannot read the normal IPA, the release also provides an experimental `unsigned-compat.ipa` with equivalent XML plists and the main `Info.plist` first in the ZIP. GBox import is awaiting device verification. To create this variant from an unsigned app:

```sh
python3 scripts/package_ipa.py path/to/WindowsiOS.app build/AlpineiOS-compat.ipa --xml-plists
```

Do not convert plists after signing; the packager rejects XML conversion when a code signature is present.

## Controls

- **Phosh app grid** — swipe up with two fingers from inside the desktop, or tap with three fingers and choose **Apps**.
- **App controls** — tap with three fingers. The panel includes the serial console, iOS keyboard, touch orientation and Linux shutdown.
- **Linux tools** — open the three-finger controls, then choose **…** for display profiles, desktop restart, text clipboard transfer or file import. Imported files appear in **Shared/Files**, accessible from Linux Files at `dav://10.0.2.4/Files`.
- **Disk snapshot** — shut down Linux and use the setup screen to save or restore one disk snapshot. Restoring replaces the active Linux disk.
- **Keyboard** — use Option–Command–A for the Linux app grid and Option–Command–L for the controls when the Linux view has keyboard focus.
- **Pause and resume** — switching away pauses the running guest. Returning resumes it while iOS keeps AlpineiOS in memory.
- **Rotate in Phosh** — if taps are offset, match the touch orientation to the guest display from the controls.
- **Return to iOS** — swipe up from the bottom edge. Use the power button in the controls to shut down Linux first if you're done with the VM.

Linux exposes the iPhone model through SMBIOS and DMI. Read /sys/class/dmi/id/product_name for the iPhone identifier and product_version for the chip when known. The processor is also described in SMBIOS type 4. Battery percentage and charging status are available through the standard ACPI power_supply interface, including /sys/class/power_supply/BAT0 and AC0, for UPower and desktop applications.

The host also supplies JSON at http://10.0.2.4/.henge/host and http://10.0.2.4/.henge/battery. These endpoints expose the iPhone identifier, known chip name, physical core count, iOS version, display capability and battery state.

On ProMotion devices the presenter requests up to the screen’s maximum refresh rate, and the VirtIO display advertises 120 Hz and 60 Hz modes. The actual display cadence and guest frame rate depend on iOS scheduling, power state and VM load. The app updates the guest tools after login, including a libgtop fallback that lets GNOME Settings read the Apple chip name from DMI.

## Development, credits and licenses

Run `make test-core` on an Apple silicon Mac. The guest image, firmware and personal signing material are prepared locally.

This project is a fork of the WindowsiOS VM engine. [Upstream WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) · [License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [Инструкция на русском](POSTMARKETOS-RU.md)
