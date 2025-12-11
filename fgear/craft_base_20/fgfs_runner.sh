#!/bin/bash
set -e

FG_ROOT="/usr/share/games/flightgear"

echo "Starting generic FlightGear..."
echo "FG_ROOT = ${FG_ROOT}"

/usr/games/fgfs \
  --fg-root="${FG_ROOT}" \
  --timeofday=noon \
  --disable-ai-models \
  --launcher=0 \
  --disable-sound \
  "$@"
