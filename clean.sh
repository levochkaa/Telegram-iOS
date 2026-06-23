#!/bin/bash

set -x

sudo rm -rf "$HOME/telegram-bazel-cache"
rm -rf "build-input"
rm -rf "build"
rm -rf "bazel-bin"
rm -rf "bazel-out"
rm -rf "bazel-Telegram-iOS"
rm -rf "bazel-testlogs"
rm -rf "Telegram/Swiftgram.xcodeproj"
python3 "build-system/Make/Make.py" clean

echo "Cleanup Completed"
