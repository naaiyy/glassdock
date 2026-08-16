#!/bin/sh

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec ruby "$root_dir/scripts/compatibility/generate-moby-v1.51-matrix.rb" --check --check-routes "$@"
