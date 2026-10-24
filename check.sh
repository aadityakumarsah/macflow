#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build
mkdir -p .build/qa
sources=(Sources/FocusFlow/*.swift)
sources=(${sources:#Sources/FocusFlow/FocusFlowApp.swift})
accessor=(.build/*/debug/FocusFlow.build/DerivedSources/resource_bundle_accessor.swift)
swiftc -swift-version 5 -whole-module-optimization -parse-as-library -o .build/qa/FocusFlowChecks "${sources[@]}" "${accessor[1]}" Tests/FocusFlowTests/*.swift
.build/qa/FocusFlowChecks
node --check Sources/FocusFlow/BrowserRecorder/recorder.js

node Tests/FocusFlowTests/browser-capture.test.js
