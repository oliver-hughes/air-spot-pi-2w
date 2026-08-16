# Tuning

## Set the analog knobs first, then never touch them

Before any EQ work. This is the step that makes everything else meaningful.

You have three volume controls in series:

```
  phone slider  →  CamillaDSP (digital)  →  ZD3 knob  →  amp knob  →  speakers
                   ^^^^^^^^^^^^^^^^^^^^
                   the only one the loudness filter can see
```

The loudness filter compensates based on where it thinks you're listening. It
only knows its own digital attenuation. Turn the ZD3 or the amp and the real
level changes with the filter none the wiser — so it applies bass lift suited
to a level you're no longer at. Turn the amp *down* and the phone *up* and you
get the flat curve at a quiet level, which is precisely backwards.

So:

1. Set the phone to about two-thirds volume.
2. Set the ZD3 and the amp so that this is comfortably loud — your normal
   listening level.
3. **Mark both knobs.** Tape, pen, whatever. Don't move them again.
4. From now on, all volume changes happen on the phone.

If you do move them, recalibrate `reference_level` (below).

## Calibrating `reference_level`

The one parameter that actually matters. It's the volume at which the loudness
curve does nothing; below it you get progressive lift.

The scale: `vol-bridge.py` maps the AirPlay slider onto 0 dB (full) to −60 dB
(minimum). So `reference_level: -20.0` is roughly two-thirds up the slider.

To calibrate:

1. Play something familiar with real bass content.
2. Set the phone to your normal listening position.
3. In the GUI, adjust `reference_level` until the loudness filter is visibly
   doing nothing at that position — the response curve goes flat.
4. Turn the phone down. Bass should hold up rather than thinning out. Too much
   lift and it'll sound bloated; raise `reference_level` if so.

## A/B testing the DSP

### The quick way: bypass the pipeline step

In the GUI's pipeline view, each step has a bypass toggle. Flip it while music
plays — no restart, no gap. In the config it's `bypassed: true` on the step:

```yaml
pipeline:
  - type: Filter
    channels: [0, 1]
    bypassed: true
    names:
      - loudness
```

**This is safe.** Worth stating explicitly, because it wouldn't necessarily be:
if the Loudness filter carried the Main volume attenuation, bypassing it would
jump the output to full scale into your amp. It doesn't — CamillaDSP applies
Main volume independently of any filter. Measured, not assumed.

### What you should hear

Measured on this exact config (`low_boost: 10`, `high_boost: 4`,
`reference_level: -20`), bypassed vs active:

| Phone volume | 50 Hz | 1 kHz | 12 kHz |
|---|---|---|---|
| −20 dB (at reference) | +0.00 dB | +0.00 dB | +0.00 dB |
| −35 dB | +5.86 dB | +0.02 dB | +2.99 dB |
| −50 dB | +7.74 dB | +0.03 dB | +3.99 dB |

Three things follow:

- **At `reference_level` the curve is exactly flat.** A/B there and you should
  hear *nothing at all*. If you do, `reference_level` isn't where you think.
- **The midrange is untouched** (0.03 dB). So this is a fair comparison — you're
  not just hearing one being louder, which is what ruins most EQ A/Bs.
- **Full boost lands around 30 dB below reference.** Below that it stops
  increasing.

### Level-matching, once you add PEQ

The fairness above is a property of the loudness filter, not of A/B testing in
general. **Any PEQ you add will change the overall level, and louder always
wins a blind comparison.** When you start adding corrective filters, add a
`Gain` filter to match levels before judging:

```yaml
filters:
  trim:
    type: Gain
    parameters:
      gain: -3.0
      inverted: false
      mute: false
```

Put it last in the pipeline and set it so bypassed and active measure the same
at 1 kHz. Only then is the comparison about tone rather than volume.

### The deeper test: bypass the whole DSP chain

The above A/Bs the *filters*. To test whether the loopback and CamillaDSP are
themselves transparent, point shairport-sync straight at the DAC.

> **Set your amp low first.** With `ignore_volume_control = "yes"` there is no
> attenuation anywhere in this path — shairport-sync passes full scale and
> CamillaDSP is no longer in circuit to apply volume. Your phone's slider will
> do nothing. Change both settings together or don't do this at all.

In `config/settings.env` set `IGNORE_VOLUME_CONTROL="no"`, then on the Pi edit
`/etc/shairport-sync.conf` to point `output_device` at the DAC:

```
output_device = "hw:CARD=ZD3,DEV=0";
```

`sudo systemctl restart shairport-sync`. Volume now happens in shairport-sync
instead, and CamillaDSP sits idle with nothing feeding its loopback.

To go back: `sudo ./bootstrap.sh --reconfigure`, which restores both.

This is a one-off sanity check, not a routine comparison — it's fiddly and the
volume semantics change underneath you.

## Using the GUI

```
http://big.local:5005/gui/index.html
```

Changes take effect live — you can drag a filter while listening.

**The GUI writes to the Pi's SD card, not to git.** When you have something you
like:

```bash
make pull-config
git diff -- config/camilladsp/filters.yml
git commit -am "loudness: raise reference_level, tame 120 Hz"
```

Without that step, a reflash loses your tuning. `pull-config` extracts only the
`filters` and `pipeline` sections — the device config stays generated, so this
Pi's DAC name never gets baked into the repo.

One wrinkle: **comments don't survive a round trip through the GUI.** The GUI
reserialises the whole config when it saves. If your annotations vanish from
`filters.yml`, that's why — they're in git history.

## Editing by hand instead

```bash
vim config/camilladsp/filters.yml
make check                            # validate locally first -- seconds
sudo ./bootstrap.sh --reconfigure     # on the Pi
# or, from the laptop:
make push-config
```

`make check` downloads a host build of CamillaDSP (cached, pinned to the same
version bootstrap installs) and runs its own `--check` on the generated config.
It catches bad fields, wrong filter parameters and pipeline syntax errors
without a deploy round trip.

On macOS it swaps the ALSA backends for file-based ones first, because the
macOS build has no ALSA support. Everything version-sensitive is still
validated; the ALSA device strings are not, and are resolved on the Pi.

`--reconfigure` skips all source builds — it's seconds, not minutes.

Bootstrap validates the generated config with `camilladsp --check` before
restarting anything, so a YAML mistake gives you a parser error rather than a
silently dead service.

If you'd tuned in the GUI and then re-run bootstrap, it notices that
`active.yml` no longer matches what it generated, backs it up to
`active.yml.bak`, and warns. Your tuning isn't silently destroyed.

---

# Troubleshooting

## Volume bridge fallback

**This is the known-unresolved bit of the design** (DESIGN.md §8). The bridge
depends on shairport-sync still invoking `run_this_when_volume_is_set` while
`ignore_volume_control = "yes"`. If it doesn't:

```bash
make volume-test     # then move the phone slider
```

Lines appearing → working, nothing to do.

Nothing appearing → switch to the fallback. Edit
`config/shairport-sync.conf.tmpl`:

```
ignore_volume_control = "no";
```

and re-run `sudo ./bootstrap.sh --reconfigure`. shairport-sync then does its own
software attenuation and the hook fires reliably — but you now have **two**
attenuation stages, so drop the loudness filter's `fader` to an Aux fader that
shapes the curve without applying gain, and drive that from the bridge instead.

## Pops, clicks, intermittent dropouts

Most likely USB scheduling contention — the ethernet adapter and the DAC share
one USB 2.0 bus (DESIGN.md §9.1). Confirm before changing anything:

```bash
make soak      # plays under network load, prints only problems
```

If it's real, in order:

1. Raise `chunksize` in `config/camilladsp/base.yml` — 2048 → 4096. Costs
   latency you have in abundance.
2. Raise `target_level` to match (roughly 4× chunksize).
3. Raise `CPUSchedulingPriority` in `systemd/camilladsp.service` from 20.

Do **not** set `dwc_otg.speed=1`, a common forum suggestion. It forces
full-speed USB and breaks the ZD3's UAC2 mode outright.

## It shows up as AirPlay, but won't group with HomePods

nqptp isn't running, so shairport-sync fell back to classic AirPlay. It still
plays, which is why this is easy to miss.

```bash
systemctl status nqptp
journalctl -u nqptp -n 30
```

## No sound, services all "running"

Check both ends of the loopback agree. This is the first-opener-wins problem:

```bash
cat /proc/asound/Loopback/pcm0p/sub0/hw_params   # what shairport-sync opened
cat /proc/asound/Loopback/pcm1c/sub0/hw_params   # what CamillaDSP opened
```

Rate and format must match `output_rate` / `output_format` in
`/etc/shairport-sync.conf` and `samplerate` / `format` in the CamillaDSP config.
A mismatch means one side failed to open.

## CamillaDSP keeps restarting

Normal. It exits when the capture stream ends — i.e. every time you pause. The
service has `StartLimitIntervalSec=0` precisely so systemd doesn't give up.
Volume survives via the statefile.

Restarting *during* playback is a real problem — check `journalctl -u camilladsp`.
