#!/usr/bin/env bash
# Test doubles shared by the suites: a `dconf` and a `gsettings` that keep their keys in ONE file, so a
# `gsettings set` is seen by `dconf dump` the way it is on a real desktop, and a `gdbus` that only logs.
# The real gdbus, run with no session bus, writes ~/.cache; a suite that compares a whole HOME needs the double.
#
#   cm_double_install <bin-dir>   write the three executables into <bin-dir> (put it first in PATH)
#   cm_double_db_set <db> <full-path> <gvariant>   seed or change a key from the test itself
#
# The executables read these variables:
#   DCONF_DB            the key store, one "full/path<TAB>gvariant" per line (required)
#   DCONF_FAIL_ONCE     an operation (dump, load, reset, write, set) that fails the first time it runs;
#                       <DCONF_DB>.failed marks that it already did, so a repeated command succeeds
#   DCONF_FAIL_ALWAYS   an operation that always fails
#   GDBUS_LOG           a file that gets one line per gdbus call (the call succeeds); GDBUS_FAIL=1 makes it fail
# A real "gsettings get" answers with the schema default for an unset key; the double fails instead, which
# is what the script already handles (it never relies on a default). A plain string that "gsettings set" is given
# is stored the way GLib prints it back (measured, GLib 2.80.0): 'text', or "text" when it holds an apostrophe.

cm_double_db_set() {
    local db="$1" key="$2" value="$3"
    touch "$db"
    awk -F'\t' -v k="$key" '$1 != k { print }' "$db" > "$db.out"
    printf '%s\t%s\n' "$key" "$value" >> "$db.out"
    mv "$db.out" "$db"
}

cm_double_install() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/dconf" <<'DOUBLE'
#!/usr/bin/env bash
db="${DCONF_DB:?}"; touch "$db"
op="${1:-}"
if [ "${DCONF_FAIL_ALWAYS:-}" = "$op" ]; then exit 9; fi
if [ "${DCONF_FAIL_ONCE:-}" = "$op" ] && [ ! -e "$db.failed" ]; then : > "$db.failed"; exit 9; fi
case "$op" in
  dump)
    awk -F'\t' -v p="$2" 'index($1, p) == 1 { r = substr($1, length(p) + 1); n = split(r, a, "/")
        k = a[n]; s = (n > 1) ? substr(r, 1, length(r) - length(k) - 1) : "/"; print s "\t" k "\t" $2 }' "$db" |
        LC_ALL=C sort | awk -F'\t' '$1 != last { print "[" $1 "]"; last = $1 } { print $2 "=" $3 }'
    ;;
  load)
    awk -v p="$2" '/^\[/ { s = substr($0, 2, length($0) - 2); next }
        /=/ { k = $0; sub(/=.*/, "", k); v = $0; sub(/^[^=]*=/, "", v)
              print p (s == "/" ? "" : s "/") k "\t" v }' > "$db.new"
    awk -F'\t' 'NR == FNR { new[$1] = $2; next } !($1 in new) { print } END { for (k in new) print k "\t" new[k] }' \
        "$db.new" "$db" > "$db.out"
    mv "$db.out" "$db"; rm -f "$db.new"
    ;;
  reset)
    shift; [ "${1:-}" = -f ] && shift
    awk -F'\t' -v p="$1" 'index($1, p) != 1 { print }' "$db" > "$db.out"; mv "$db.out" "$db"
    ;;
  write)
    awk -F'\t' -v k="$2" '$1 != k { print }' "$db" > "$db.out"; printf '%s\t%s\n' "$2" "$3" >> "$db.out"
    mv "$db.out" "$db"
    ;;
  *) exit 2 ;;
esac
DOUBLE
    cat > "$bin/gsettings" <<'DOUBLE'
#!/usr/bin/env bash
# schema org.cinnamon.desktop.interface + key cursor-size -> /org/cinnamon/desktop/interface/cursor-size
db="${DCONF_DB:?}"; touch "$db"
op="${1:-}"
if [ "${DCONF_FAIL_ALWAYS:-}" = "$op" ]; then echo "double: $op refused" >&2; exit 9; fi
if [ "${DCONF_FAIL_ONCE:-}" = "$op" ] && [ ! -e "$db.failed" ]; then : > "$db.failed"; echo "double: $op refused" >&2; exit 9; fi
case "$op" in
  get)
    key="/$(printf '%s' "$2" | tr . /)/$3"
    value=$(awk -F'\t' -v k="$key" '$1 == k { print $2; found = 1; exit } END { exit !found }' "$db") || {
        echo "No such key '$3'" >&2; exit 1; }
    printf '%s\n' "$value"
    ;;
  set)
    key="/$(printf '%s' "$2" | tr . /)/$3"; value="$4"
    case "$value" in
      \'*|\"*|true|false|-[0-9]*|[0-9]*|\[*|\(*|@*) ;;
      *) esc=${value//\\/\\\\}   # a plain string is stored as GLib prints it: 'text', or "text" with an apostrophe in it
         if [[ "$value" == *\'* ]]; then value="\"${esc//\"/\\\"}\""; else value="'$esc'"; fi ;;
    esac
    awk -F'\t' -v k="$key" '$1 != k { print }' "$db" > "$db.out"; printf '%s\t%s\n' "$key" "$value" >> "$db.out"
    mv "$db.out" "$db"
    ;;
  *) exit 2 ;;
esac
DOUBLE
    cat > "$bin/gdbus" <<'DOUBLE'
#!/usr/bin/env bash
[ -z "${GDBUS_LOG:-}" ] || printf '%s\n' "$*" >> "$GDBUS_LOG"
[ "${GDBUS_FAIL:-0}" != 1 ] || exit 1
exit 0
DOUBLE
    chmod +x "$bin/dconf" "$bin/gsettings" "$bin/gdbus"
}
