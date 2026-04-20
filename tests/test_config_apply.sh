#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$tmpbin/clash" <<'EOF'
#!/usr/bin/env bash
config=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		-f)
			config="$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done

if grep -q 'bad-syntax: yes' "$config"; then
	printf '%s\n' 'syntax bad' >&2
	exit 1
fi

exit 0
EOF

chmod +x "$tmpbin/logger" "$tmpbin/clash"
export PATH="$tmpbin:$PATH"
export CLASH_DIR="$tmpdir/opt/clash"
export CLASH_BIN="$tmpbin/clash"
export CLASH_CONFIG="$tmpdir/opt/clash/config.yaml"

mkdir -p "$CLASH_DIR"
cat > "$CLASH_CONFIG" <<'EOF'
mode: rule
tproxy-port: 7894
routing-mark: 1

dns:
  listen: 0.0.0.0:7874
EOF

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

cat > "$tmpdir/expected.yaml" <<'EOF'
mode: rule
tproxy-port: 7894
routing-mark: 2

dns:
  listen: 0.0.0.0:7874
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
EOF

candidate_valid="$tmpdir/candidate-valid.yaml"
cp "$tmpdir/expected.yaml" "$candidate_valid"
apply_config_file "$candidate_valid"
cmp -s "$CLASH_CONFIG" "$tmpdir/expected.yaml" || fail "apply_config_file should install validated config"
[[ ! -e "$candidate_valid" ]] || fail "apply_config_file should remove temp candidate after success"
compgen -G "$CLASH_CONFIG.tmp.*" >/dev/null && fail "apply_config_file should not leave flash-side temp config after success"

cp "$CLASH_CONFIG" "$tmpdir/live-before-invalid.yaml"
candidate_parse="$tmpdir/candidate-parse.yaml"
cat > "$candidate_parse" <<'EOF'
mode: rule
tproxy-port: 7894

dns:
  listen: 0.0.0.0:7874
EOF

assert_false "apply_config_file should reject policy-invalid config" apply_config_file "$candidate_parse"
cmp -s "$CLASH_CONFIG" "$tmpdir/live-before-invalid.yaml" || fail "apply_config_file should keep old config on policy validation failure"
[[ ! -e "$candidate_parse" ]] || fail "apply_config_file should remove temp candidate after policy validation failure"
compgen -G "$CLASH_CONFIG.tmp.*" >/dev/null && fail "apply_config_file should not leave flash-side temp config after policy validation failure"

candidate_syntax="$tmpdir/candidate-syntax.yaml"
cat > "$candidate_syntax" <<'EOF'
mode: rule
bad-syntax: yes
tproxy-port: 7894
routing-mark: 9

dns:
  listen: 0.0.0.0:7874
EOF

assert_false "apply_config_file should reject Mihomo syntax-invalid config" apply_config_file "$candidate_syntax"
cmp -s "$CLASH_CONFIG" "$tmpdir/live-before-invalid.yaml" || fail "apply_config_file should keep old config on syntax validation failure"
[[ ! -e "$candidate_syntax" ]] || fail "apply_config_file should remove temp candidate after syntax validation failure"
compgen -G "$CLASH_CONFIG.tmp.*" >/dev/null && fail "apply_config_file should not leave flash-side temp config after syntax validation failure"

pass "config apply helper"
