# Android

Android is the **easier** platform for this app, and it is worth saying why before
anything else: an iPhone build signed with a free Apple account stops working after
**7 days** and has to be rebuilt. An Android APK installs once and keeps working.

---

## Just install it

1. Download the latest `.apk` from
   [**Releases**](https://github.com/isashahid10/whoop/releases)
2. Open it on your phone. Android asks permission to install from this source — allow it
3. Open the app and pair your band

That is the whole process. No computer, no toolchain, no account.

> [!IMPORTANT]
> **Close the official WHOOP app before pairing.** Bluetooth only lets one app own the
> band at a time.
>
> And once you start using this app with a band, **stop opening the official WHOOP app
> with it**. If the band reconnects to WHOOP it may pull a firmware update, and there is
> a real chance the records this app depends on shift or stop working.

### About the security warning

The APK is **debug-signed**, so Android will say the developer is unknown. That is
expected for an app installed outside the Play Store and does not affect how it runs. A
Play Store release would need a registered developer account and a review process, which
is not what this is for.

---

## What works on Android

Nearly everything. All of this fork's additions are pure Dart with no platform gating.

| Feature | Android |
|---|---|
| Band sync, sleep, recovery, strain, HRV | ✅ |
| Hevy training sync | ✅ |
| Strength analysis, bulk quality, overreaching | ✅ |
| Naps, readiness breakdown, correlations | ✅ |
| Weather, calendar, caffeine | ✅ |
| Prayer times, Ramadan mode | ✅ |
| Nutrition and steps | ✅ via **Health Connect** |
| Band alarm | ✅ (runs off the band's own clock) |
| Google Drive backup | ✅ |
| AlarmKit backup alarm | ❌ iOS only |
| Siri phrases | ❌ iOS only |
| Find-my-phone on double tap | ❌ iOS only |

### Health Connect

Android routes nutrition, steps and workouts through
[Health Connect](https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata)
rather than Apple Health. Install it from the Play Store if your phone does not have it
already (Android 14 and later include it), then grant access when the app asks.

Your nutrition tracker needs to write to Health Connect for that data to appear here.
Most major ones do.

---

## Building it yourself

Only worth doing if you want to change something. Otherwise use the release APK.

### What you need

- **Java 17** — `brew install openjdk@17` on macOS, or your distribution's package
- **Android SDK** — easiest via [Android Studio](https://developer.android.com/studio),
  which installs it on first launch
- **FVM** — `brew tap leoafarias/fvm && brew install fvm`

### Build

```bash
git clone https://github.com/isashahid10/whoop.git whoop
cd whoop
git checkout isa/customisations

fvm install
fvm flutter pub get

cp .env.example .env
echo "ENABLE_HEALTH_DATA_CONTRIBUTION=false" >> .env

fvm flutter test
fvm flutter build apk --release --dart-define-from-file=.env
```

The APK lands at `build/app/outputs/flutter-apk/app-release.apk`.

> [!WARNING]
> Flutter is **pinned to 3.41.6**. On 3.44.x this project does not compile — the symptom
> is ~22 test files failing at *load* while logic tests still pass, which reads as a test
> bug and is not. Always use `fvm flutter`, never bare `flutter`.

### Install to a connected phone

Enable **Developer options** (tap Build number seven times in Settings → About phone),
turn on **USB debugging**, plug in, then:

```bash
fvm flutter install
```

> [!NOTE]
> `flutter install` is safe on Android and dangerous on iOS. On iOS it uninstalls first
> and wipes the database; on Android it performs a normal package upgrade and your data
> survives. The iOS guide says never to use it for that reason.

### Signing

`android/app/build.gradle.kts` falls back to debug signing when no release key is
configured, which is why the build above needs no setup. If you want a properly signed
build, create `android/key.properties`:

```properties
storeFile=/absolute/path/to/keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

That file and `*.jks` are gitignored. **Do not commit either.**

---

## Cutting a release

Releases are built by CI, so no local toolchain is involved:

```bash
git tag android-v1.0.0
git push origin android-v1.0.0
```

[`.github/workflows/android-release.yml`](../.github/workflows/android-release.yml) runs
the tests, builds the APK, and attaches it to a GitHub Release with install instructions.
It needs **no repository secrets**.

It also forces `ENABLE_HEALTH_DATA_CONTRIBUTION=false`. Upstream's own release builds set
that flag true — their call for their backend — but a fork must not ship a build flagged
to contribute to someone else's data collection.

---

## Troubleshooting

**"App not installed"**
Usually an older copy signed with a different key. Uninstall the existing app first.

**Health Connect shows nothing**
Confirm the app has permission (Settings → Apps → Health Connect → app permissions), and
that your nutrition or fitness app is actually writing to it.

**Band will not connect**
Confirm the official WHOOP app is fully closed. Grant nearby-device permission. Android
12+ requires location permission for Bluetooth scanning, which is an OS requirement
rather than something this app wants.

**Background sync stops**
Android battery optimisation. Settings → Apps → Whoop → Battery → **Unrestricted**.

---

## Reporting problems

[Open an issue](https://github.com/isashahid10/whoop/issues) and say which Android version
and phone. For anything about the band protocol itself, upstream
[OpenStrap/edge](https://github.com/OpenStrap/edge) is the better place — that is where
that work lives.
