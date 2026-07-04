#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

source_mihowrt_cli_lib

case " $MIHOWRT_STATUS_MODULES " in
*" fetch.sh "*) ;;
*)
	fail "status module group should load fetch.sh for remote policy URL diagnostics"
	;;
esac

pass "cli module groups"
