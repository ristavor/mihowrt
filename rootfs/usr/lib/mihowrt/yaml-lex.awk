# Plain or quoted mapping key at the start of the text.
function key_of(text) {
	if (text !~ /^["\047]?[A-Za-z0-9_-]+["\047]?[[:space:]]*:/)
		return ""
	sub(/[[:space:]]*:.*/, "", text)
	gsub(/["\047]/, "", text)
	return text
}
# Diagnostics preserves immediate # values and trims loose quote/space edges;
# the renderer keeps its stricter historical value and quote handling.
function strip_comment(text, keep_initial_comment) {
	if (!keep_initial_comment) sub(/^#.*/, "", text)
	sub(/[[:space:]]+#.*/, "", text)
	sub(/[[:space:]]+$/, "", text)
	return text
}
# Value after "key:" without a trailing comment.
function value_of(text, keep_initial_comment) {
	sub(/^[^:]*:[[:space:]]*/, "", text)
	return strip_comment(text, keep_initial_comment)
}
function unquote(text, trim_edges) {
	if (trim_edges) {
		gsub(/^[[:space:]\042\047]+|[[:space:]\042\047]+$/, "", text)
		return text
	}
	if (text ~ /^".*"$/)
		text = substr(text, 2, length(text) - 2)
	else if (text ~ /^\047.*\047$/) {
		text = substr(text, 2, length(text) - 2)
		gsub(/\047\047/, "\047", text)
	}
	return text
}
function indent_of(text) {
	match(text, /^[[:space:]]*/)
	return RLENGTH
}
