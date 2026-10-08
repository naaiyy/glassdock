#!/usr/bin/env python3
"""Repair SPICE custom XRandR modes whose pixel clock is expressed in kHz.

spice-vdagent 0.22/0.23 can advertise 0.06 Hz instead of 60 Hz when it
creates an arbitrary resolution. Chromium follows that timing. Leave normal
modes alone and use the distribution's cvt/xrandr tools to create valid timings.
"""
import re
import shlex
import subprocess
import time


def repairs(state):
    output = None
    result = []
    for line in state.splitlines():
        if line and not line[0].isspace():
            match = re.match(r"(\S+) connected(?: primary)? \d+x\d+", line)
            output = match.group(1) if match else None
        elif output:
            fields = line.split()
            if len(fields) < 2:
                continue
            selected = next((value for value in fields[1:] if "*" in value), None)
            if selected:
                mode = re.fullmatch(r"(\d+)x(\d+)(?:[-_].*)?", fields[0])
                try:
                    rate = float(selected.rstrip("*+"))
                except ValueError:
                    continue
                if mode and 0 < rate < 1:
                    width, height = map(int, mode.groups())
                    if 320 <= width <= 8192 and 200 <= height <= 8192:
                        result.append((output, width, height))
    return result


def repair(output, width, height, run=subprocess.run):
    timing = run(["cvt", str(width), str(height), "60"], capture_output=True, text=True, check=True)
    line = next(line for line in timing.stdout.splitlines() if line.startswith("Modeline "))
    fields = shlex.split(line)[1:]
    fields[0] = f"glassdock-{width}x{height}-60"
    # A mode may already exist from an earlier resize; adding it is idempotent.
    run(["xrandr", "--newmode", *fields], capture_output=True, text=True)
    run(["xrandr", "--addmode", output, fields[0]], capture_output=True, text=True)
    run(["xrandr", "--output", output, "--mode", fields[0]], capture_output=True, text=True, check=True)


def main():
    while True:
        try:
            state = subprocess.run(["xrandr", "--current"], capture_output=True, text=True, check=True)
            for output, width, height in repairs(state.stdout):
                repair(output, width, height)
        except (OSError, ValueError, StopIteration, subprocess.CalledProcessError) as error:
            print(f"GlassDock display timing: {error}", flush=True)
        time.sleep(2)


if __name__ == "__main__":
    main()
