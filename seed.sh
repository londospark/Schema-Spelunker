#!/bin/sh
set -e

mkdir -p bin

./_compile_libs.sh

if [ "$1" = "huge" ]; then
	odin build test/huge_seed.odin -file -out:"bin/huge_seed" -linker=mold
	bin/huge_seed huge.db
else
	odin build test/seed.odin -file -out:"bin/seed" -linker=mold
	bin/seed seed.db
fi
