# air-spot-pi-2w

Turn a fresh Raspberry Pi Zero 2 W into an **AirPlay 2** target with a
**customisable loudness EQ**, outputting over USB to a **Fosi Audio ZD3**.

Three steps:

1. Flash Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager — [docs/IMAGER.md](docs/IMAGER.md)
2. `ssh big@big.local`, `sudo apt install -y git`, clone this repo, `sudo ./bootstrap.sh`
3. Play to **big** from any Apple device

```
  iPhone ──AirPlay 2──> shairport-sync ──> snd-aloop ──> CamillaDSP ──USB──> ZD3 ──> amp
                              ▲                          (loudness EQ)
                              └── nqptp (AP2 timing)            ▲
                                                          camillagui :5005
```

Design rationale, risks and open questions: **[DESIGN.md](DESIGN.md)**.
Tuning and troubleshooting: **[docs/TUNING.md](docs/TUNING.md)**.

---

## Before you tune anything

You have three volume controls in series, and **the loudness filter can only
see one of them**:

```
phone → CamillaDSP → ZD3 knob → amp knob → speakers
        ^^^^^^^^^^
        the only one it knows about
```

Set the ZD3 and amp knobs once to a normal listening level, mark them, and
leave them alone. Change volume from the phone. Otherwise the loudness curve is
compensating for a level you aren't at.

Full explanation in [docs/TUNING.md](docs/TUNING.md).

---

## Usage

```bash
sudo ./bootstrap.sh                  # full install; idempotent, re-run freely
sudo ./bootstrap.sh --reconfigure    # apply config changes, skip builds (seconds)
sudo ./bootstrap.sh --dry-run        # show what would happen
sudo ./bootstrap.sh --skip-gui       # no web UI; tune by editing filters.yml
sudo ./bootstrap.sh --keep-wifi      # don't disable the Wi-Fi radio
```

From your laptop:

```bash
make pull-config    # bring GUI tuning back into git  <- don't skip this
make push-config    # apply repo tuning to the Pi
make status         # one-screen health check
make volume-test    # verify the AirPlay volume bridge is firing
make soak           # play under network load, print only problems
make logs           # follow everything
```

---

## What you tune

Two files. Everything else is plumbing.

**[`config/camilladsp/filters.yml`](config/camilladsp/filters.yml)** — the EQ.

**[`config/settings.env`](config/settings.env)** — AirPlay name, sample rate,
volume mode, GUI port.

`filters.yml` ships with a loudness curve and an empty PEQ list. The PEQ is
empty on purpose: there are no room measurements for this system, and invented
filters would be worse than none.

The pipeline runs at **48 kHz / S32** so AirPlay 2's lossless tier
(ALAC/S24/48000) passes through without being downsampled — there is no 44.1
lossless tier, so 48k is the right pin. Details in DESIGN.md §3.2.

The one parameter that matters is `reference_level` — your normal listening
level, the point where the curve goes flat. It has to be set by ear;
[docs/TUNING.md](docs/TUNING.md) walks through it.

---

## Status

**Running on hardware.** AirPlay 2 target works, audio plays through the ZD3,
and the volume bridge tracks the phone's slider.

Resolved on first contact:

- **The volume bridge works** with `ignore_volume_control = "yes"` — the hook
  does still fire in that mode, so CamillaDSP owns all attenuation and there's
  no double-attenuation. This was the design's main open question. DESIGN.md §8.

Still outstanding:

- **USB contention** — the ethernet adapter and the DAC share one USB 2.0 bus.
  No dropouts observed yet, but the long soak hasn't been run. `make soak`.
  DESIGN.md §9.1.
- **CamillaGUI** — crash-looping on first install; being diagnosed. Not in the
  audio path, so it doesn't affect playback.
- **Surround** — a sender choosing 5.1/7.1 has nowhere to go in a stereo
  pipeline. Unverified. DESIGN.md §3.2.

Acceptance criteria are listed in DESIGN.md §12.

## Scope

AirPlay only. Despite the repo name, Spotify Connect isn't here yet — but the
loopback architecture means adding librespot later is a second systemd unit
writing to the same loopback, with no change to the DSP stage.

## Licence

MIT — see [LICENSE](LICENSE).
