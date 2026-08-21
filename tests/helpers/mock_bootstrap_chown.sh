#!/usr/bin/env bash
set -euo pipefail

# Git Bash cannot apply Linux numeric ownership. Metadata assertions are
# provided by mock_bootstrap_stat.sh; Linux runs use the real chown command.
exit 0
