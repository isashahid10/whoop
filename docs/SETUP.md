# Setup

A guide for getting this running on your own band. No prior terminal experience assumed —
where a command is needed, it is written out in full and explained.

---

## Before you start

**You need:**

- A **WHOOP 4.0** band (this fork tracks upstream's `main`, which is WHOOP-4 only)
- An **iPhone** running iOS 17 or newer
- A **Mac** to build and install the app
- About **an hour**, most of it waiting on downloads

**You do not need:**

- A WHOOP subscription — the band works without one
- A WHOOP account
- An Apple Developer subscription — free provisioning is enough
- Hevy Pro

---

## ⚠️ Read this first

> [!CAUTION]
> **Once you start using this app, stop opening the official WHOOP app with that band.**
>
> If the band reconnects to WHOOP's app it may pull a firmware update, and there is a
> real chance the events and records this app depends on shift or stop working. Pick a
> lane and stay in it.

Bluetooth also only lets one app own the band at a time, so quit the official app before
pairing regardless.

---

## Step 1 — Install the build tools

Open **Terminal** (press `Cmd + Space`, type "Terminal", press Enter).

Install [Homebrew](https://brew.sh) if you do not have it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install FVM, which manages the exact Flutter version this project needs:

```bash
brew tap leoafarias/fvm
brew install fvm
```

You also need **Xcode** from the Mac App Store. It is a large download — start it now
and read on while it goes. Once installed, open it once and accept the licence prompt.

---

## Step 2 — Get the code

```bash
git clone https://github.com/isashahid10/edge.git whoop
cd whoop
fvm install
fvm flutter pub get
```

> [!IMPORTANT]
> Flutter is pinned to **3.41.6**. Do not upgrade it — the project does not compile on
> newer versions, for a documented reason. Always type `fvm flutter`, never plain
> `flutter`.

---

## Step 3 — Configuration files

Two files hold personal settings and are deliberately **not** in the repository, so
nobody's keys end up on GitHub.

```bash
cp .env.example .env
cp ios/Config/Signing.xcconfig.example ios/Config/Signing.xcconfig
```

### Your Apple Team ID (required)

1. Open Xcode → **Settings** → **Accounts**
2. Sign in with your Apple ID if you have not already
3. Select your account, click **Manage Certificates** — your Team ID is the 10-character
   code shown alongside your personal team

Open `ios/Config/Signing.xcconfig` in any text editor and put it in:

```
APPLE_DEVELOPMENT_TEAM = YOURTEAMID
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.whoop
```

Use your **own** bundle identifier. Two people cannot install the same identifier from
different developer accounts.

### Your AI coach key (optional)

Skip this if you do not want the coach; everything else works without it.

1. Go to [Google AI Studio](https://aistudio.google.com/apikey)
2. Create an API key in a project with **no billing enabled**

> [!WARNING]
> A key from a project **with** billing enabled is not on the free tier and will fail
> with a credits error the first time it generates — while still looking fine in every
> other respect. Create the key in a project with no billing attached.

Put it in `.env`:

```
GEMINI_API_KEY=your-key-here
```

---

## Step 4 — Build and install

Plug your iPhone into the Mac. Unlock it and tap **Trust This Computer**.

Find your device ID:

```bash
xcrun devicectl list devices
```

Copy the long identifier next to your iPhone, then:

```bash
fvm flutter build ios --release --dart-define-from-file=.env

xcrun devicectl device install app \
  --device YOUR-DEVICE-ID-HERE \
  build/ios/iphoneos/Runner.app
```

The first build takes several minutes. Later builds are much faster.

> [!WARNING]
> **Never use `fvm flutter install`.** It prints "Uninstalling old version…" and wipes
> the app's database — every synced night, every logged workout, gone. Always use
> `xcrun devicectl device install app`, which upgrades in place and keeps your data.

---

## Step 5 — Trust the app on your phone

Because this is a free developer account, iOS will not run the app until you approve it:

**Settings → General → VPN & Device Management → your Apple ID → Trust**

Now open the app.

> [!NOTE]
> **A free Apple account signs apps for 7 days.** After that the app stops opening and
> you rebuild with the same command. Your data survives — it is the signature that
> expires, not the app.
>
> [SideStore](https://sidestore.io) can automate the re-signing, or a $99/year Apple
> Developer account extends it to a year. Neither buys any extra capability.

---

## Step 6 — First run

1. **Pair the band.** Make sure the official WHOOP app is fully closed. Put the band on
   the charger to wake it if it has been sitting dead.
2. **Grant permissions** as prompted — Bluetooth, notifications, Health, and location if
   you want weather and prayer times.
3. **Wear it overnight.** This is the part that cannot be rushed.

### What to expect, honestly

Most of the app is **empty on day one**, and that is it working correctly rather than
failing:

| Feature | Needs |
|---|---|
| Sleep, resting HR | 1 night |
| Recovery / readiness | ~7 nights (it is comparing you against *your* baseline) |
| Illness watch | ~7 nights |
| Correlations | 14 paired days |
| Bulk quality | 10 weigh-ins |

The app says what each blank card is waiting for. It abstains rather than showing you a
population average dressed up as your number.

---

## Optional integrations

**Hevy** — Profile → Hevy → Sign in. Pulls every set you log. No Hevy Pro needed. Sign-in
is periodic rather than permanent; when the session expires the app asks again.

**Apple Health** — Profile → Apple Health. Reads steps, nutrition and workouts in;
writes sleep and recovery back out.

**Prayer times** — grant location and they are computed on-device from your coordinates.
No network call, nothing sent anywhere.

**Google Drive backup** — Profile → Backups. Uses a scope that can only see files this
app created; it cannot read anything else in your Drive.

---

## Troubleshooting

**"No code signature found"**
The build was made with `--no-codesign`. Rebuild without that flag.

**App installs but crashes on opening a share sheet**
A simulator build left incompatible frameworks behind. Fix:

```bash
fvm flutter clean && fvm flutter pub get
fvm flutter build ios --release --dart-define-from-file=.env
```

**~22 test files fail to load, other tests pass**
Flutter got upgraded past 3.41.6. Check with `fvm flutter --version` before debugging
anything else.

**Band will not connect**
Confirm the official WHOOP app is fully closed. Charge the band for a few minutes if it
has been flat. Toggle Bluetooth off and on.

**Coach says nothing useful**
It needs data before it can say anything grounded. Give it a few days. If it errors
outright, check the API key is from a project with no billing enabled.

---

## Getting help

This is a personal project with no support promises, but
[open an issue](https://github.com/isashahid10/edge/issues) and include what you tried,
what happened, and what you expected.

For anything about the band protocol or the core analytics, upstream
[OpenStrap/edge](https://github.com/OpenStrap/edge) is the better place to ask — that is
where that work lives.
