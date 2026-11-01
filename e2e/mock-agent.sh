#!/usr/bin/env bash
set -euo pipefail
# The downloaded BonitoAgents test directory has no instantiated Manifest.
# Launch its mock provider from Community's actual, instantiated test env.
exec "${COMMUNITY_TEST_JULIA:-julia}" --startup-file=no --color=no --history-file=no --project="$(dirname "$0")" -m MockACP
