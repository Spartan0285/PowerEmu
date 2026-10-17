#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/harmony-menu-focus-tests
swiftc app/Sources/PowerEmu/HarmonyInteraction.swift tests/HarmonyMenuFocus/main.swift -o build/harmony-menu-focus-tests/checks
build/harmony-menu-focus-tests/checks
