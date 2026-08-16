# Flashing the card

## Image

**Raspberry Pi OS Lite (64-bit)** — Trixie / Debian 13.

In Raspberry Pi Imager: *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**.

Two things people get wrong here:

- **Lite, not Desktop.** 512 MB of RAM and no display attached.
- **64-bit, not 32-bit.** CamillaDSP and CamillaGUI are installed as prebuilt
  `aarch64` binaries. On the 32-bit image there is no prebuilt path and you'd be
  compiling Rust on a Zero 2 W. `bootstrap.sh` refuses to run on `armv7l` rather
  than let you find this out slowly.

## Imager settings (the gear icon)

| Setting | Value |
|---|---|
| Hostname | `big` |
| Enable SSH | yes, **public-key authentication** |
| Username | `big` (if you use something else, set `PI_USER` in the Makefile to match) |
| Wi-Fi SSID / password | **your network — yes, even though you're using ethernet** |
| Locale / timezone | yours |

### Why configure Wi-Fi when the Pi is on ethernet

Insurance for exactly one boot. If the ethernet hat's chipset happens not to be
in the base image, a headless first boot gives you no network and no SSH, and
the only way back in is re-flashing the card. Wi-Fi configured-but-unused costs
nothing and removes that failure mode.

`bootstrap.sh` disables the Wi-Fi radio at the end, once ethernet is confirmed
working. It also refuses to do so if you're currently connected over Wi-Fi,
rather than cutting the branch it's sitting on.

## First boot

```bash
ssh big@big.local

# Pi OS Lite ships without git. bootstrap.sh installs it (it needs git to fetch
# the nqptp and shairport-sync sources) but that's too late to clone this repo.
sudo apt update && sudo apt install -y git

git clone https://github.com/oliver-hughes/air-spot-pi-2w.git
cd air-spot-pi-2w
sudo ./bootstrap.sh
```

### Or skip git entirely

Once you're iterating on changes, syncing your working tree beats a
commit/push/pull cycle per fix — and it needs nothing installed on the Pi:

```bash
# from your laptop, in the repo
rsync -av --exclude .git ./ big@big.local:~/air-spot-pi-2w/
```

Note that `make push-config` assumes the git clone, since it does a `git pull`
on the Pi. If you rsync'd, just rsync again and run
`sudo ./bootstrap.sh --reconfigure`.

Expect **15–25 minutes**, nearly all of it compiling shairport-sync. It goes
quiet during the build; that's normal.

Have the ZD3 plugged in and switched to its USB input before you start —
preflight checks for a USB audio device and stops if there isn't one, which is
better than configuring a pipeline with no output.
