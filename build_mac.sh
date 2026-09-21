#!/bin/sh
# Builds the Mac screen recorder with plain Command Line Tools; no Xcode.
# Core/ is the same timekeeping and overlay code the iPhone app compiles.
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -target "$(uname -m)-apple-macosx13.0" Core/*.swift MacCapture/*.swift -o .build/timestampcap
echo "built .build/timestampcap"
