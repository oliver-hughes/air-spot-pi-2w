# air-spot-pi-2w — Design & Spec

Turn a fresh Raspberry Pi Zero 2 W into an AirPlay 2 target that applies a
customisable loudness EQ and outputs over USB to a Fosi Audio DAC.

Status: **implemented, not yet run on hardware.** Config generation, the volume
bridge protocol, the GUI round trip and DAC detection are covered by tests that
pass locally; everything requiring an actual Pi and DAC is untested. §10 lists
what's resolved, §12 the acceptance criteria still to meet.

---

## 1. Goal

Three user-facing steps, no more:

1. Flash Raspberry Pi OS with Raspberry Pi Imager (hostname `big`, SSH key, and Wi-Fi
   configured as a first-boot fallback even though Ethernet is the real link — see §9.1a).
2. `ssh` in, `git clone` this repo, run `./bootstrap.sh`.
3. Reboot. The Pi appears as an AirPlay 2 target; audio comes out of the DAC with EQ applied.

### In scope

- AirPlay 2 receiver
- Configurable parametric EQ + volume-tracking loudness compensation
- USB audio output to an external DAC
- Web UI for tuning the EQ live, with the canonical config version-controlled here

### Explicitly out of scope (for now)

- Spotify Connect / librespot — despite the repo name. See §11.
- Bluetooth, UPnP/DLNA, Roon
- Local file playback, display, physical controls

---

## 2. Baseline

| Item | Choice | Why |
|---|---|---|
| Board | Raspberry Pi Zero 2 W | Given. Quad A53, **512 MB RAM** — the binding constraint. |
| OS | Raspberry Pi OS **Trixie** (Debian 13) **Lite, 64-bit** | 64-bit so CamillaDSP's prebuilt `aarch64` binary works — no Rust toolchain on a 512 MB box. Lite because there is no display. |
| Kernel | 6.12 LTS (stock) | No custom kernel, no DKMS. `snd-aloop` is in-tree. |
| Network | **Ethernet** via hat (Zero 2 W has no onboard NIC — this is a USB-attached adapter) | Removes the Wi-Fi power-save problem entirely. Introduces a different one — see §9.1. |
| Audio out | **Fosi Audio ZD3** — XMOS XU316 + ESS ES9039Q2M, USB-C | XU316 ⇒ **UAC2**, class-compliant, no driver needed. Up to 768 kHz / DSD512 over USB. |
| Hostname | `big` | → `big.local` |
| AirPlay name | `big` | |

---

## 3. Architecture

```
  iPhone / Mac
       │  AirPlay 2 (ALAC/AAC, 44.1 or 48 kHz, up to 24-bit)
       ▼
  ┌─────────────────┐        ┌──────────┐
  │ shairport-sync  │        │  nqptp   │  timing daemon, AP2 only
  │   (built from   │◄──────►│          │  listens on UDP 319/320
  │    source)      │        └──────────┘
  └────────┬────────┘
           │  ALSA playback → hw:Loopback,0
           ▼
  ┌─────────────────────────────┐
  │  snd-aloop  (kernel module) │   virtual cable
  └────────┬────────────────────┘
           │  ALSA capture ← hw:Loopback,1
           ▼
  ┌─────────────────────────────────────────┐      ┌──────────────┐
  │            CamillaDSP                   │◄────►│  camillagui  │
  │  Loudness filter (volume-tracking)      │  ws  │  :5005       │
  │  + user PEQ biquads                     │      └──────────────┘
  └────────┬────────────────────────────────┘             ▲
           │  ALSA playback → hw:<DAC>                    │ browser
           ▼                                              │
     Fosi Audio DAC  ──►  amp / speakers
```

Plus a small volume bridge, out of band:

```
  shairport-sync  ──run_this_when_volume_is_set──►  vol-bridge.sh
                                                          │
                                                    websocket SetVolume
                                                          ▼
                                                     CamillaDSP
```

### 3.1 Why the loopback

You chose "AirPlay only, keep it minimal", and the minimal option described a direct
path with no loopback. I'm recommending we keep the loopback anyway, for one reason:
**it is what makes volume-tracked loudness work**, which you also asked for.

The alternatives and why they lose:

- **shairport-sync → named pipe → CamillaDSP.** No loopback, but shairport-sync loses
  visibility of playback latency, so its drift correction is disabled. AirPlay 2's whole
  timing model (nqptp) assumes accurate playback timing. This is the known-bad path for AP2.
- **`alsa_cdsp` ALSA plugin.** Genuinely avoids the loopback and is a real option, but it
  spawns CamillaDSP per-stream. A volume change arriving while nothing is playing has
  nowhere to go, and the web GUI needs a persistently running instance to talk to. Also a
  third-party C plugin we'd have to compile.
- **ALSA `equal`/LADSPA inline.** Simplest, but it's a fixed 10-band graphic EQ with no
  loudness curve. Doesn't meet the requirement.

The loopback costs one in-tree kernel module and a few ms of latency that is irrelevant
against AirPlay's ~2 s buffer. It also happens to leave the Spotify door open at zero
cost today, which given the repo name seems worth having.

### 3.2 Sample rate — pinned to 48000

My first pass said "AirPlay is always 44.1 kHz". Not true in shairport-sync 5.x. My second
pass then pinned 44100 on the reasoning that most *source material* is 44.1 — also wrong,
because the rate that reaches the loopback is the **transport** rate the sender negotiates,
not the rate of the underlying file.

The formats shairport-sync 5.x can receive:

| Tier | Format |
|---|---|
| Basic | ALAC/S16/**44100**/2 (realtime), AAC/F24/**44100**/2 (buffered) |
| Better | AAC/F24/**48000**/2 |
| **Lossless** | **ALAC/S24/48000/2** |
| Surround | AAC/F24/48000/5.1, 7.1 |

**There is no 44.1 lossless tier.** Lossless over AirPlay 2 *is* 24-bit/48 kHz. Pinning 44100
would have taken the best stream the senders can produce and downsampled it — defeating the
feature outright.

Why pin at all: **the ALSA Loopback adopts the rate of whichever application opens it first.**
A rate that varies per stream would leave one end unable to open. So both ends are pinned to
`OUTPUT_RATE` in `config/settings.env`, and shairport-sync transcodes the 44.1 tiers up to
match on the way in.

The cost of 48000 is upsampling the two Basic-tier formats. That is the lowest-quality tier
anyway — 16-bit ALAC or lossy AAC — and shairport-sync 5's "vernier" resampler was added
specifically for low-power CPUs. Paying a transparent resample on the worst tier to keep the
best tier bit-exact is the right way round.

Format is `S32` end to end so the 24-bit lossless tier isn't truncated.

#### If you later want zero resampling at either rate

Possible, at the cost of a moving part. `camilladsp-controller` (upstream, by CamillaDSP's
author) watches the loopback for format changes and reconfigures CamillaDSP to follow. Its
`-a` "adapt" provider modifies a **single** base config, so the one-config GUI workflow in §7
survives — the `-s` provider would need a config file per rate and would break it.

Not done now because it adds a Python service (`pycamilladsp` isn't packaged in Debian, so it
needs a venv), plus a brief stumble at the start of any stream whose rate differs from the
last. The gain over pinning 48000 is avoiding a resample on the *lowest* quality tier, which
does not justify another daemon on a 512 MB board.

Beyond the pin, the only resampling is CamillaDSP's drift correction (§9.3) — and on a
loopback that's done by tuning the virtual clock, so there isn't any.

#### Surround is a live question

shairport-sync 5.x can accept 5.1 and 7.1. This pipeline is stereo end to end — 2-channel
loopback, 2-channel CamillaDSP. A sender choosing a surround format would have nowhere to go.
shairport-sync should constrain itself to what the output device supports, and the loopback is
stereo, so this ought to resolve itself. **Unverified** — worth watching for on first contact.

Internal processing in 64-bit float, output `S32_LE` at the pinned rate — the XU316 will
advertise that and far more, but there is no reason to upsample beyond what the transport
delivers. We wouldn't be adding information, and every extra kHz is CPU we don't have spare.
Preflight confirms the DAC advertises the configured rate rather than assuming it.

The ZD3's headline 768 kHz / DSD512 capability is irrelevant here: AirPlay tops out at 48 kHz.
Its practical significance is only that **XU316 ⇒ UAC2 ⇒ class-compliant**, so `snd-usb-audio`
in kernel 6.12 drives it with no driver work.

---

## 4. Components

| Component | Source | Notes |
|---|---|---|
| `shairport-sync` | **Build from source** `5.2.1`, `--with-airplay-2` | Debian's package is not built with AP2. ~10–15 min on a Zero 2 W. |
| `nqptp` | Build from source `1.2.8` | Required companion for AP2 timing. |
| `avahi-daemon` | apt | mDNS advertisement. |
| `camilladsp` | **Prebuilt** `camilladsp-linux-aarch64.tar.gz` `v4.1.3` | No compile, no Rust toolchain. |
| `camillagui` | **Prebuilt** `bundle_linux_aarch64.tar.gz` `v4.1.0` | Self-contained — bundles its own Python. The PEP 668 problem I flagged earlier doesn't arise. Serves on **:5005**, GUI at `/gui/index.html`. |
| `snd-aloop` | In-tree kernel module | `/etc/modules-load.d/` + `/etc/modprobe.d/` for options. |

### 4.1 shairport-sync 5.x gotchas

Version 5 landed in 2026 with breaking changes, and most guides online still describe 4.x:

- `--with-systemd` is now **`--with-systemd-startup`**. The old flag silently gives you no service unit.
- On Debian 13 the build needs **`systemd-dev`**, which 4.x-era dependency lists omit.
- Config keys renamed: `loudness` → `loudness_enabled`, `convolution` → `convolution_enabled`.
- Default `output_rate` changed 44100 → 48000 (§3.2).
- AP2 is now conditional at runtime: with nqptp running it advertises AirPlay 2, without it it
  quietly falls back to classic AirPlay. **A dead nqptp looks like "works, but not AP2"** rather
  than a hard failure — so preflight checks nqptp explicitly.

Everything runs under systemd. Version pins live in one `versions.env` at the repo root so
upgrades are a one-line diff.

---

## 5. Repo layout

```
bootstrap.sh              entry point, orchestrates the phases below
versions.env              pinned versions for everything we build or download
lib/
  00-preflight.sh         OS/arch/model checks, refuse politely if wrong
  10-packages.sh          apt deps
  20-nqptp.sh             build + install nqptp
  30-shairport.sh         build + install shairport-sync with AP2
  40-loopback.sh          snd-aloop module config
  50-camilladsp.sh        fetch binary, install service
  60-camillagui.sh        venv + GUI service
  70-config.sh            render templates → /etc, enable services
  80-tuning.sh            disable wlan0, swap, USB autosuspend, RT priority, DAC mixer to 0 dB
config/
  camilladsp/
    base.yml              devices + pipeline skeleton (generated bits substituted)
    filters.yml           ← YOUR EQ LIVES HERE. The tunable surface.
  shairport-sync.conf.tmpl
  vol-bridge.sh           volume forwarding hook
systemd/
  camilladsp.service
  camillagui.service
docs/
  IMAGER.md               exact Raspberry Pi Imager settings
  TUNING.md               how to use the GUI and commit the result
```

---

## 6. `bootstrap.sh` behaviour

**Idempotent.** Re-running is the supported way to apply a config change or upgrade.
Every phase checks whether its work is already done at the pinned version and skips if so.
A second run on an unchanged repo should take seconds, not fifteen minutes.

- `set -euo pipefail`, one phase per file, sourced in order.
- Logs to stdout *and* `/var/log/air-spot-bootstrap.log`.
- **Preflight refuses to proceed** if: not `aarch64`, not Debian 13, not a Pi Zero 2 W,
  or no USB audio device present. Clear message, exit non-zero. Better than a
  half-configured box.
- Compile steps: `make -j2`, not `-j4`. Four parallel GCC jobs against ffmpeg headers on
  512 MB will OOM. Bootstrap ensures swap exists first.
- Flags: `--skip-gui`, `--dry-run`, `--reconfigure` (config only, skip all builds).
- Prints a summary at the end: detected DAC, AirPlay name, GUI URL, whether a reboot is needed.

---

## 7. The EQ — your tuning surface

`config/camilladsp/filters.yml` is the file you own. Everything else is plumbing.

Two layers:

**a) Loudness compensation** — CamillaDSP's built-in `Loudness` filter, with `fader: Main`
so it tracks the live volume. As you turn down, it lifts low (<70 Hz) and high (>3500 Hz)
shelves. Tunables:

- `reference_level` — the volume (dB) at which the curve is flat. This is "how loud is my
  normal listening level", and it's the parameter that actually matters. Needs setting by ear.
- `low_boost` / `high_boost` — max lift in dB at full attenuation (defaults here: 6 dB low,
  3 dB high).
- `attenuate_mid` — whether to cut mids instead of boosting the extremes.

**b) Static PEQ** — a list of `Biquad` filters (peaking / lowshelf / highshelf) for room and
speaker correction. Empty by default; you fill it in.

### Workflow

1. Play something, open `http://big.local:5005/gui/index.html`.
2. Drag filters, watch the frequency response, listen.
3. GUI writes to `/etc/camilladsp/active.yml` on the Pi.
4. `make pull-config` (helper) copies it back to this repo as `filters.yml`.
5. Commit. A reflash reproduces your tuning exactly.

That last step is the bit that makes the GUI safe to rely on — without it, tuning lives
only on an SD card.

---

## 8. Volume & loudness — the one genuinely open detail

The goal: iOS volume slider drives CamillaDSP's Main fader, so the Loudness filter knows the
real listening level. Mechanism:

`shairport-sync.conf` → `run_this_when_volume_is_set = "/usr/local/bin/vol-bridge.sh"`.
shairport-sync invokes it with the AirPlay volume, the script maps that to dB and sends
`SetVolume` over CamillaDSP's websocket.

**RESOLVED on hardware (2026-08-16): option A works.**

The open question was whether `run_this_when_volume_is_set` still fires when
`ignore_volume_control = "yes"`. It does. shairport-sync sends full scale, CamillaDSP owns all
attenuation, the hook fires on every volume change, and there is no double attenuation. This
is the clean arrangement and it's what ships.

For the record, the fallback if it had *not* fired — kept because a future shairport-sync
release could change this behaviour:

- **B:** Let shairport-sync attenuate as normal, and drive the Loudness filter from an **Aux**
  fader that shapes the curve without applying gain. Definitely fires, but needs checking that
  an Aux fader tilts without also attenuating.

If volume ever stops tracking after an upgrade, `make volume-test` is the two-minute check and
docs/TUNING.md has the switch-over.

Mute, and the `-144 dB` AirPlay mute sentinel, need handling explicitly in the bridge.

### 8.1 The ZD3's own volume knob — a behavioural constraint, not a bug

The ZD3 is a DAC *and preamp*: it has a volume knob, a remote and a display. That creates a
problem specific to loudness compensation that wouldn't exist with a fixed-output DAC.

The loudness curve works by knowing your actual listening level. It only knows CamillaDSP's
digital attenuation. If you turn the ZD3's knob, real-world SPL changes and **the curve has no
idea** — so it applies bass lift appropriate to a level you're no longer at. Turn the ZD3
down and the phone up, and you get the flat curve at a quiet level, which is precisely
backwards.

So the operating rule is: **set the ZD3 knob once to a reference position, mark it, and leave
it. All routine volume changes happen from the phone.** `reference_level` gets calibrated
against that knob position — move the knob and the calibration is invalid.

This is a real usability constraint and it should go in the README, not be discovered later.
It's inherent to loudness compensation with an analog volume stage downstream, not something
better engineering avoids.

Two follow-ons for the install:
- The XU316 will likely expose a **USB volume control** to ALSA. Bootstrap must set it to
  0 dB and leave it, or we get a third attenuation stage nobody is tracking.
- Worth checking whether the ZD3's USB volume and its physical knob are the same control or
  independent. Changes whether the knob is visible to us at all.

---

## 9. Pi Zero 2 W specific risks

### 9.1 One USB 2.0 bus, shared by the NIC and the DAC — the new big one
Going Ethernet kills the Wi-Fi power-save problem outright, which was previously the top
risk. Straight win. But the Zero 2 W has **a single USB 2.0 OTG port**, so an Ethernet hat is
a USB-attached NIC sharing that one bus with the DAC, behind a hub.

Bandwidth is a non-issue — 48 kHz/32-bit stereo is ~3.1 Mbit/s against 480 Mbit/s. The risk
is **USB scheduling and interrupt contention disrupting isochronous audio transfers**, which
is a documented failure mode for USB audio on Pi hardware and shows up as random pops and
brief dropouts rather than as anything that looks like a network problem. Streaming AirPlay
means the NIC is busy continuously while the DAC needs its isochronous slots serviced on time.

Mitigations, in order of preference:
- Generous CamillaDSP playback buffers (`target_level`, `chunksize`) — trades a little
  latency, which we have to spare, for tolerance of jitter.
- `RTPrio` on the CamillaDSP unit so the audio thread wins scheduling contests.
- `usbcore.autosuspend=-1` to stop the NIC power-cycling mid-stream.

Do **not** reach for `dwc_otg.speed=1` (a common forum suggestion) — it forces full-speed USB
and would break UAC2 outright.

I'd rate this as likely-fine but genuinely unproven on this combination. It's the same
2-hour soak test as §9.3, so it costs nothing extra to find out.

### 9.1a Disable the Wi-Fi radio
With Ethernet in use, `wlan0` should be switched off rather than left idle: it frees RAM,
and more importantly it stops Avahi advertising the AirPlay service on two interfaces, which
makes devices intermittently pick the wrong route. Bootstrap disables it.

**But enable Wi-Fi in Raspberry Pi Imager anyway.** If the Ethernet hat's chipset isn't in the
base image, a headless first boot has no network and no SSH, and your only recovery is
re-flashing. Wi-Fi configured-but-unused is a free safety net for exactly one boot. Most
common chips (RTL8152/8153, ASIX AX88179) are in-kernel, so this probably won't matter —
which is precisely why it's annoying if it does.

### 9.2 Memory
512 MB with AP2 (ffmpeg AAC decode) + CamillaDSP + a Python web GUI is tight but workable.
Mitigations: Lite image, `gpu_mem=16`, no desktop, ensure swap before compiling, and
`--skip-gui` as an escape hatch if it proves too much. Worth measuring rather than assuming.

### 9.3 Two clock-correction loops
shairport-sync corrects drift against the AirPlay clock; CamillaDSP corrects drift between
the loopback and the DAC. They act on different error signals so they shouldn't fight, and
this is a well-travelled setup — but it's the design's main unknown. **Acceptance test: a
2-hour continuous play with no dropouts or audible drift.**

### 9.4 USB power
The ZD3 is a desktop unit with balanced outputs, a display and a remote — far beyond what a
Zero 2 W's OTG port could feed. Assumed self-powered, which makes this a non-issue. Worth
confirming it isn't drawing from the data connection (§10).

### 9.5 Stable device naming
`hw:1` is not stable across reboots or hotplug. Reference the DAC by card name
(`hw:CARD=...`), detected at install time and written into the config — with a udev rule if
the name turns out to be ambiguous.

### 9.6 SD card longevity
An always-on appliance writing logs to SD will eventually kill the card. Cheap mitigation:
`Storage=volatile` for journald, `commit=600` mount option. Not full read-only root — that
would fight the GUI writing configs.

---

## 10. Questions I still need answered

All resolved:

- **DAC:** Fosi ZD3, UAC2 via XMOS XU316, **self-powered** — no USB current concern.
- **Network:** Ethernet hat, works out of the box, chipset in-kernel.
- **Names:** hostname `big`, AirPlay name `big`.
- **Downstream:** ZD3 → amp → passive speakers. Note this is a **second** analog volume stage
  after the ZD3's own knob; §8.1's "set once and leave it" applies to both.
- **EQ:** no REW measurements. Ship with an empty PEQ list and a conservative loudness
  default, tune by ear via the GUI.

Defaulted without asking: GUI is **LAN-exposed on :5005 with no auth**. It's a home network and
requiring an SSH tunnel to tweak EQ is friction. One line in `camillagui.yml` to bind it to
localhost if you'd rather.

---

## 11. On the repo name

`air-spot-pi-2w` reads as AirPlay + Spotify. You've scoped Spotify out for now and that's
the right call — get one path correct first. Worth recording that the loopback design means
adding librespot later is *additive*: a second systemd unit writing to the same loopback,
with no change to the DSP stage. No rework, no rearchitecting. That's a consequence of §3.1,
not extra work being smuggled in now.

The one thing that would need real thought later is source arbitration — what happens when
AirPlay and Spotify both try to play. Deliberately not solved here.

---

## 12. Acceptance tests

The build is done when all of these pass:

1. Fresh flash → clone → `./bootstrap.sh` → reboot → device appears in iOS Control Center
   as an AirPlay 2 target, no manual steps.
2. Audio plays through the Fosi DAC, correct channels, no clipping at full scale.
3. iOS volume slider moves CamillaDSP's fader (visible in the GUI).
4. Loudness curve audibly changes with volume; flat at `reference_level`.
5. Editing `filters.yml` + re-running bootstrap applies the new EQ.
6. GUI reachable, changes take effect live, and `make pull-config` round-trips to git.
7. **2-hour continuous play, no dropouts, no drift** — covers both the dual clock-correction
   loops (§9.3) and USB bus contention (§9.1). The single most important test here.
8. Same soak **with the network deliberately loaded** (large `scp` to the Pi while playing).
   If USB contention is going to bite, this is what surfaces it.
9. DAC's ALSA volume control sits at 0 dB and nothing moves it.
10. Power-cycle → everything comes back automatically with no SSH.
11. DAC unplug/replug → recovers without a reboot.
12. `./bootstrap.sh` run twice is a no-op the second time.

---

## Sources

- [shairport-sync AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md)
- [shairport-sync BUILD.md](https://github.com/mikebrady/shairport-sync/blob/master/BUILD.md)
- [shairport-sync sample config](https://github.com/mikebrady/shairport-sync/blob/master/scripts/shairport-sync.conf)
- [CamillaDSP releases](https://github.com/HEnquist/camilladsp/releases)
- [CamillaDSP 4.1.x documentation](https://www.camilladsp.com/docs/camilladsp/4.1.x/)
- [CamillaDSP websocket interface](https://github.com/HEnquist/camilladsp/blob/master/websocket.md)
- [Raspberry Pi OS Trixie announcement](https://www.raspberrypi.com/news/trixie-the-new-version-of-raspberry-pi-os/)
