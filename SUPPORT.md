# Support

This is a personal fork, maintained by one person for one band. There is no
support commitment. That said, here is the fastest route to an answer.

## Start here

| Question | Where |
|---|---|
| How do I install it? | [docs/SETUP.md](docs/SETUP.md), or [docs/ANDROID.md](docs/ANDROID.md) |
| Can something else do the setup for me? | [docs/SETUP_WITH_CLAUDE.md](docs/SETUP_WITH_CLAUDE.md) |
| Why is this number blank? | [docs/METHODOLOGY.md](docs/METHODOLOGY.md) |
| Why does deep sleep look wrong? | [docs/METHODOLOGY.md#deep-sleep](docs/METHODOLOGY.md#deep-sleep) |
| How does any of this work? | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |

## Before opening an issue

**A blank number is usually correct.** This app abstains rather than showing you
a population average dressed up as your own figure. Correlations need 14 paired
days, bulk quality needs 10 weigh-ins, readiness needs a baseline. Each card
says what it is waiting for.

**Deep sleep reading low is known and documented.** It was investigated
directly, with measurements, and deliberately left unchanged. The reasoning is
in the methodology doc. Please read that section before filing.

## Where to ask

| Topic | Repository |
|---|---|
| This fork: Hevy, nutrition, calendar, prayer times, the UI | [here](https://github.com/isashahid10/edge/issues) |
| Band protocol, opcodes, record decoding | [OpenStrap/protocol](https://github.com/OpenStrap/protocol/issues) |
| Core metrics: HRV, sleep staging, strain | [OpenStrap/analytics](https://github.com/OpenStrap/analytics/issues) |
| Anything about the app upstream already shipped | [OpenStrap/edge](https://github.com/OpenStrap/edge/issues) |

Most of this application is upstream's work. If your question is not about the
additions listed in the README, upstream is both the better source and the place
where a fix helps everyone rather than one person.

## Security

Do not open a public issue. See [SECURITY.md](SECURITY.md).
