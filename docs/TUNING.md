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
sudo ./bootstrap.sh --reconfigure     # on the Pi
# or, from the laptop:
make push-config
```

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
