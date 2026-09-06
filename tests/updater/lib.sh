#!/usr/bin/env bash
# Shared helpers for the updater integration suite.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
info() { echo "---- $*"; }
