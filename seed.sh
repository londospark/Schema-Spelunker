#!/bin/sh
set -e

mkdir -p bin

./_compile_libs.sh

odin build test -out:"bin/seed" -linker=mold
bin/seed seed.db
