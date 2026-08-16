# Helpers you run from your laptop, against the Pi.
#
#   make pull-config    bring GUI tuning back into git
#   make push-config    apply repo tuning to the Pi
#   make logs           follow everything relevant
#   make volume-test    verify the AirPlay volume bridge is firing
#   make status         one-screen health check

PI      ?= big.local
PI_USER ?= big
SSH     := ssh $(PI_USER)@$(PI)

REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
FILTERS   := $(REPO_ROOT)/config/camilladsp/filters.yml

.PHONY: help pull-config push-config logs volume-test status restart soak

help:
	@sed -n 's/^#   //p' $(MAKEFILE_LIST) | head -20

## Pull the live filters + pipeline off the Pi into the repo.
## Run this after tuning in the web GUI, or your work lives only on the SD card.
pull-config:
	@echo "==> pulling tuning from $(PI)"
	@tmp=$$(mktemp); \
	if $(SSH) 'sudo /usr/local/bin/air-spot-config-split' > $$tmp && [ -s $$tmp ]; then \
		if cmp -s $$tmp $(FILTERS); then \
			echo "    no change -- repo already matches the Pi"; \
		else \
			mv $$tmp $(FILTERS); \
			echo "    updated $(FILTERS)"; \
			echo "    review with: git diff -- config/camilladsp/filters.yml"; \
		fi; \
	else \
		rm -f $$tmp; \
		echo "    FAILED -- nothing written, your repo copy is untouched" >&2; \
		exit 1; \
	fi

## Push the repo's tuning to the Pi and apply it.
push-config:
	@echo "==> pushing repo to $(PI) and reconfiguring"
	$(SSH) 'cd ~/air-spot-pi-2w && git pull --ff-only && sudo ./bootstrap.sh --reconfigure'

logs:
	$(SSH) 'sudo journalctl -f -u shairport-sync -u camilladsp -u nqptp -t air-spot-vol'

## Watch the volume bridge react to the phone's slider.
## This is the check for the one thing the design couldn't settle without
## hardware -- see DESIGN.md 8.
volume-test:
	@echo "==> move the volume slider on your phone. Ctrl-C to stop."
	@echo "    Nothing appearing? See docs/TUNING.md 'volume bridge fallback'."
	$(SSH) 'sudo journalctl -t air-spot-vol -f -n 20'

status:
	@$(SSH) 'for s in nqptp shairport-sync camilladsp camillagui; do \
	    printf "%-16s %s\n" "$$s" "$$(systemctl is-active $$s 2>&1)"; \
	  done; \
	  echo; echo "--- cards ---"; cat /proc/asound/cards; \
	  echo "--- loopback rate (0 = idle) ---"; \
	  cat /proc/asound/Loopback/pcm0p/sub0/hw_params 2>/dev/null || echo "closed"; \
	  echo; echo "--- camilladsp volume ---"; \
	  sudo cat /var/lib/camilladsp/statefile.yml 2>/dev/null || echo "(no statefile yet)"; \
	  echo; printf "xruns logged this boot: "; \
	  sudo journalctl -u camilladsp --no-pager 2>/dev/null | grep -ci "underrun\|xrun" || echo 0'

restart:
	$(SSH) 'sudo systemctl restart camilladsp shairport-sync'

## The acceptance test that matters: continuous play while the shared USB bus
## is under real network load, watching for the contention dropouts in
## DESIGN.md 9.1. Load has to come over the wire to stress the NIC -- local
## disk traffic wouldn't touch the USB bus the DAC is on.
soak:
	@echo "==> Start playback to '$(PI)' first, then leave this running."
	@echo "    Pushing continuous traffic to the Pi's USB ethernet adapter."
	@echo "    Any line that appears below is a dropout worth investigating."
	@echo
	@( while true; do \
	     dd if=/dev/zero bs=1M count=512 2>/dev/null | $(SSH) 'cat > /dev/null'; \
	   done ) & \
	 LOAD_PID=$$!; \
	 trap "kill $$LOAD_PID 2>/dev/null" EXIT INT TERM; \
	 $(SSH) 'sudo journalctl -f -u camilladsp -u shairport-sync' \
	   | grep -i --line-buffered "underrun\|xrun\|error\|resync\|drift"
