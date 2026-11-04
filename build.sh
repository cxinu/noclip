#!/usr/bin/env bash
set -e
mkdir -p bin
odin run src -out:bin/game -debug -vet -extra-linker-flags:"-lGL -lX11"
