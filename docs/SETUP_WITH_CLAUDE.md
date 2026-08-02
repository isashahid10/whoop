# Setup, with Claude doing the work

If you would rather not follow a step-by-step guide, you can hand this whole job to
[Claude Code](https://claude.com/claude-code) and answer questions as they come.

This page is written so that **copying one block of text is enough**.

---

## Is this the right page for you?

| You want | Go here |
|---|---|
| **Android, easiest possible** | [Download the APK](https://github.com/isashahid10/whoop/releases) — no setup at all. Skip this page. |
| **Android, built yourself** | This page → [Android prompt](#android) |
| **iPhone** | This page → [iPhone prompt](#iphone) |
| **To understand each step** | [SETUP.md](SETUP.md) instead |

> [!TIP]
> **If you just want it working on Android, do not use this page.** Download the APK from
> [Releases](https://github.com/isashahid10/whoop/releases), open it on your phone, done.
> Building from source is only worth it if you want to change something.

---

## First: install Claude Code

On **macOS** or **Linux**, open Terminal and run:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

On **Windows**, install [WSL](https://learn.microsoft.com/windows/wsl/install) first, then
run the same command inside it.

Then start it:

```bash
claude
```

It will ask you to sign in the first time.

---

## Android

Paste this entire block into Claude Code and press Enter.

```text
I want to build and install an Android app from source. I am not a developer,
so please explain what you are doing in plain language and ask me before
anything that needs a decision from me.

The project is https://github.com/isashahid10/whoop — a personal fork of
OpenStrap Edge that makes a WHOOP 4.0 band work without a subscription.

Please do all of this:

1. Check whether I have git, Java 17 and the Android SDK. Install whatever is
   missing, telling me what each one is for.

2. Install FVM and use it for every Flutter command. This project is PINNED to
   Flutter 3.41.6 and genuinely does not compile on newer versions. Never run
   bare `flutter`, and never upgrade past 3.41.6.

3. Clone the repo and check out the `isa/customisations` branch, which is the
   fork's branch. Then run `fvm install` and `fvm flutter pub get`.

4. Read docs/SETUP.md in the repo and follow anything Android-specific there.

5. Create a `.env` file from `.env.example`. Ask me whether I want the AI
   coach. If yes, walk me through getting a free Gemini API key from
   https://aistudio.google.com/apikey and make sure I create it in a project
   with NO BILLING enabled — a key from a billing-enabled project is not on the
   free tier and fails with a confusing credits error later.
   Also set ENABLE_HEALTH_DATA_CONTRIBUTION=false.

6. Run `fvm flutter test` and confirm the tests pass before building anything.
   If they fail, check the Flutter version first: this project's known failure
   mode is ~22 test files failing to LOAD on a too-new Flutter, which looks
   like a test bug and is not.

7. Build the release APK:
   fvm flutter build apk --release --dart-define-from-file=.env

8. Tell me where the APK file is and how to get it onto my phone. Explain that
   Android will warn about installing from an unknown source and that this is
   expected.

Important things to tell me at the end:
- I must close the official WHOOP app before pairing. Bluetooth only lets one
  app own the band at a time.
- Once I use this app with my band, I should stop opening the official WHOOP
  app with it, because the band may pull a firmware update that breaks things.
- Most of the app will be empty for the first several days. That is correct
  behaviour, not a bug: it compares me against my own baseline and needs about
  a week before recovery means anything.
```

---

## iPhone

You need a **Mac** for this. There is no way around that — Apple only allows iPhone apps
to be built on macOS.

Paste this entire block into Claude Code and press Enter.

```text
I want to build and install an iPhone app from source. I am not a developer, so
please explain what you are doing in plain language and ask me before anything
that needs a decision from me.

The project is https://github.com/isashahid10/whoop — a personal fork of
OpenStrap Edge that makes a WHOOP 4.0 band work without a subscription.

Please do all of this:

1. Check whether I have Homebrew, git and Xcode. Install what is missing. If
   Xcode is missing, tell me to install it from the Mac App Store and that it
   is a large download, then wait for me.

2. Install FVM and use it for every Flutter command. This project is PINNED to
   Flutter 3.41.6 and genuinely does not compile on newer versions. Never run
   bare `flutter`, and never upgrade past 3.41.6.

3. Clone the repo and check out the `isa/customisations` branch. Then run
   `fvm install` and `fvm flutter pub get`.

4. Read docs/SETUP.md in the repo and follow it.

5. Help me find my Apple Team ID (Xcode > Settings > Accounts > Manage
   Certificates). Create ios/Config/Signing.xcconfig from the .example file and
   put in my Team ID plus a bundle identifier that is unique to me, like
   com.myname.whoop. Explain that two people cannot install the same bundle
   identifier from different Apple accounts.

6. Create a `.env` file from `.env.example`. Ask me whether I want the AI
   coach. If yes, walk me through getting a free Gemini API key from
   https://aistudio.google.com/apikey and make sure I create it in a project
   with NO BILLING enabled — a key from a billing-enabled project is not on the
   free tier and fails with a confusing credits error later.

7. Run `fvm flutter test` and confirm the tests pass before building.

8. Ask me to plug in my iPhone and trust the computer. Find the device ID with
   `xcrun devicectl list devices`.

9. Build and install:
   fvm flutter build ios --release --dart-define-from-file=.env
   xcrun devicectl device install app --device <MY-DEVICE-ID> build/ios/iphoneos/Runner.app

   CRITICAL: never use `fvm flutter install`. It uninstalls the old version
   first and wipes the app's database — every synced night and every logged
   workout. Always use `xcrun devicectl device install app`, which upgrades in
   place and keeps the data.

   Also: never build for the iOS Simulator in this checkout without running
   `fvm flutter clean` afterwards. A simulator build leaves incompatible
   framework slices behind that a later device build does not reliably replace,
   and the app then crashes at runtime rather than failing to build.

10. Walk me through trusting the app on my phone: Settings > General > VPN &
    Device Management > my Apple ID > Trust.

Important things to tell me at the end:
- A free Apple account signs apps for only 7 DAYS. After that the app stops
  opening and I need to run the build command again. My data survives; it is
  the signature that expires. Mention SideStore as a way to automate this.
- I must close the official WHOOP app before pairing.
- Once I use this app with my band, I should stop opening the official WHOOP
  app with it.
- Most of the app will be empty for the first several days, and that is correct
  behaviour rather than a bug.
```

---

## If something goes wrong

Tell Claude what happened. It has the repo checked out and can read
[SETUP.md](SETUP.md), which has a troubleshooting section covering the common failures.

The two that catch almost everyone:

| Symptom | Cause |
|---|---|
| ~22 test files fail to *load*, others pass | Flutter got upgraded past 3.41.6 |
| App installed fine, then crashed later | A simulator build poisoned the frameworks — `fvm flutter clean` and rebuild |

---

## A word on what Claude should not do

If Claude offers to "fix" any of the following, say no. Each is deliberate and documented:

- **Upgrading Flutter past 3.41.6.** The project will not compile.
- **Changing pinned commit SHAs to branch refs.** A floating ref lets an upstream commit
  silently change the behaviour of a build you already checked.
- **Using `flutter install` because it is shorter.** It wipes your database.
- **Reformatting the whole repository.** It makes future updates from upstream painful.
