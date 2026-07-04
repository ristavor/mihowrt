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

case " $MIHOWRT_RUNTIME_CONFIG_MODULES " in
*" lists.sh "*) ;;
*)
	fail "runtime config module group should load lists.sh for policy file validation"
	;;
esac

pass "cli module groups"
