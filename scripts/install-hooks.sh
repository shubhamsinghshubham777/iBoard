#!/usr/bin/env bash
# Points git at scripts/hooks (shared by all worktrees of this clone). Run once after cloning.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/hooks/*
git config core.hooksPath scripts/hooks
echo "hooks installed: core.hooksPath = scripts/hooks (pre-commit runs the privacy audit; pre-push runs scripts/test.sh --no-ui for code changes)"
