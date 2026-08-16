#!/usr/bin/env python3
"""Extract the tunable half of the live CamillaDSP config.

Runs ON THE PI. `make pull-config` invokes it over ssh and captures stdout into
config/camilladsp/filters.yml, so tuning done in the web GUI ends up in git
rather than living only on an SD card.

Why a real YAML parse rather than sed: the GUI rewrites the whole config when
it saves, reserialising it with its own key order and formatting. Text
extraction works right up until the first time you use the GUI, which is
exactly when you need this.
"""

import sys

try:
    import yaml
except ImportError:
    sys.exit(
        "python3-yaml is not installed on the Pi.\n"
        "Fix: sudo apt install python3-yaml   (or re-run bootstrap.sh)"
    )

ACTIVE = "/etc/camilladsp/configs/active.yml"

# Everything else -- title, description, devices -- is generated from base.yml
# and the detected hardware. Pulling it back into the repo would bake this
# specific Pi's DAC name into version control.
TUNABLE_KEYS = ("filters", "mixers", "processors", "pipeline")

HEADER = """\
# ---------------------------------------------------------------------------
# THIS IS YOUR FILE. Everything else in this repo is plumbing.
#
# Pulled from the live config on the Pi by `make pull-config`. Hand edits are
# fine too -- apply them with `sudo ./bootstrap.sh --reconfigure`.
#
# Note: comments do not survive a round trip through the GUI. If you had
# explanatory notes here and they've vanished, that's why -- check git.
# ---------------------------------------------------------------------------

"""


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ACTIVE
    try:
        with open(path) as fh:
            cfg = yaml.safe_load(fh)
    except FileNotFoundError:
        sys.exit(f"no config at {path} -- has bootstrap.sh run?")
    except yaml.YAMLError as e:
        sys.exit(f"{path} is not valid YAML: {e}")

    if not isinstance(cfg, dict):
        sys.exit(f"{path} did not parse to a mapping")

    out = {k: cfg[k] for k in TUNABLE_KEYS if k in cfg and cfg[k] is not None}
    if not out:
        sys.exit(f"{path} contains none of {TUNABLE_KEYS} -- nothing to pull")

    sys.stdout.write(HEADER)
    yaml.safe_dump(out, sys.stdout, sort_keys=False, default_flow_style=False, indent=2)


if __name__ == "__main__":
    main()
