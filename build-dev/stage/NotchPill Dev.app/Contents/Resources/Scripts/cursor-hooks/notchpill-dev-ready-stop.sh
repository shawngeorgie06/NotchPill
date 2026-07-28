#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/Scripts/deliver-notchpill-pending.sh" main
