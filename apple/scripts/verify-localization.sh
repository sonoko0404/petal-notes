#!/bin/zsh
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
python3 "$script_dir/verify-localization.py" "$script_dir/.."
