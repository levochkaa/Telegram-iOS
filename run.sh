#!/bin/bash

set -x

python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    --overrideXcodeVersion \
    generateProject \
    --configurationPath=config.json \
    --xcodeManagedCodesigning
