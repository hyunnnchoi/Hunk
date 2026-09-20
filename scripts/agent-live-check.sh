#!/bin/bash
# Calls a real agent CLI and uses your account. Usage: bash scripts/agent-live-check.sh claude|codex
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/smoke
swiftc -parse-as-library -swift-version 6 \
  Sources/Hunk/Domain.swift \
  Sources/Hunk/ProcessRunner.swift \
  Sources/Hunk/DiffParser.swift \
  Sources/Hunk/GitServices.swift \
  Sources/Hunk/AgentCLI.swift \
  scripts/AgentLiveCheck.swift -o .build/smoke/AgentLiveCheck
.build/smoke/AgentLiveCheck "${1:-claude}"
