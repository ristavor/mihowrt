#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
# Runtime JSON must work without jq; jq remains an independent test oracle.
modules=(settings status job lists subscription config)
for module in "${modules[@]}"; do
 assert_file_not_contains "$MIHOWRT_LIB_DIR/$module.sh" 'jq ' "$module still invokes jq"
 pass "JSON runtime: $module has no jq call"
done
