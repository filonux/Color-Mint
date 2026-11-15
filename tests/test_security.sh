#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-security.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"

HOME="$TMP/home-lock" CM_HOME="$TMP/cm-lock" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    mkdir -p "$CM_HOME"
    printf protected > "$CM_HOME/target"
    ln -s "$CM_HOME/target" "$CM_LOCK_FILE"
    must_fail cm_lock
    [ "$(cat "$CM_HOME/target")" = protected ]
' bash "$BODY" || fail 'lock symlink protection'
pass 'lock symlink cannot redirect writes'

cat > "$TMP/injection.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
cm_lang_init
marker="$HOME/injected"
mkdir -p "$CM_PRESETS_DIR"
printf '%s\n' 'CM_VERSION="3.1.0"' > "$CM_PRESETS_DIR/evil"
printf '%s\n' 'touch "$HOME/injected"' >> "$CM_PRESETS_DIR/evil"
must_fail cm_load_preset evil >/dev/null 2>&1
[ ! -e "$marker" ]
CASE
chmod 755 "$TMP/injection.sh"
HOME="$TMP/home-preset" CM_HOME="$TMP/cm-preset" CM_LANG_OVERRIDE=en bash "$TMP/injection.sh" "$BODY" || fail 'preset shell injection'
pass 'preset files are treated as data'

MOCK="$TMP/mockbin"; mkdir -p "$MOCK"
cat > "$MOCK/gsettings" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CM_TEST_LOG:?}"
MOCK
chmod 755 "$MOCK/gsettings"

# Rejection must come from validation, never from a failing backend: the gsettings
# double succeeds and records every call, so any accepted name shows up in the log.
run_name() {
    local fn="$1" value="$2"
    : > "$TMP/names.log"
    HOME="$TMP/home-names" CM_HOME="$TMP/cm-names" CM_LANG_OVERRIDE=en CM_TEST_LOG="$TMP/names.log" PATH="$MOCK:$PATH" \
        bash -c 'source "$1"; cm_lang_init; "$2" "$3"' bash "$BODY" "$fn" "$value" >/dev/null 2>&1
}

run_name cm_apply_font_name 'Noto Sans 10' || fail 'positive control: valid font name rejected'
grep -q '^set org.cinnamon.desktop.interface font-name' "$TMP/names.log" || fail 'positive control: backend double not reached'
run_name cm_apply_monospace_font 'Ubuntu Mono 11' || fail 'positive control: valid monospace font rejected'

for fn in cm_apply_gtk_theme cm_apply_icon_theme cm_apply_cursor_theme cm_apply_cinnamon_theme cm_apply_font_name cm_apply_monospace_font; do
    for value in '../evil' 'bad/name' $'bad\\name' $'bad\nname' $'bad\tname' $'bad\rname' $'bad\033name' $'bad\177name'; do
        if run_name "$fn" "$value"; then
            fail "unsafe name accepted by $fn: $(printf '%q' "$value")"
        fi
        [ ! -s "$TMP/names.log" ] || fail "unsafe name reached the backend via $fn: $(printf '%q' "$value")"
    done
done
pass 'theme and font names reject traversal and control characters'

# Valid theme layouts that each carry one hostile member: only the validation layer can reject them.
printf outside > "$TMP/outside"
mkdir -p "$TMP/clean/Clean/cinnamon" "$TMP/linked/Linked/cinnamon" "$TMP/slip/Slip/cinnamon" "$TMP/mock-home/.themes"
printf css > "$TMP/clean/Clean/cinnamon/cinnamon.css"
printf css > "$TMP/linked/Linked/cinnamon/cinnamon.css"
ln -s "$TMP/outside" "$TMP/linked/Linked/cinnamon/escape"
printf css > "$TMP/slip/Slip/cinnamon/cinnamon.css"
(cd "$TMP/clean" && zip -q -r "$TMP/clean.zip" Clean)
(cd "$TMP/linked" && zip -q -r -y "$TMP/symlink.zip" Linked)
(cd "$TMP/slip/Slip" && zip -q -r "$TMP/traversal.zip" cinnamon ../../outside)

HOME="$TMP/mock-home" CM_HOME="$TMP/cm-import" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    themes() { find "$HOME/.themes" -mindepth 1 -maxdepth 1 | wc -l; }
    cm_import_theme "$2" >/dev/null 2>&1 || exit 10
    [ "$(themes)" -eq 1 ] || exit 11
    must_fail cm_import_theme "$3" >/dev/null 2>&1
    must_fail cm_import_theme "$4" >/dev/null 2>&1
    [ "$(cat "$5")" = outside ] || exit 12
    [ "$(themes)" -eq 1 ] || exit 13
' bash "$BODY" "$TMP/clean.zip" "$TMP/traversal.zip" "$TMP/symlink.zip" "$TMP/outside" || fail 'archive validation: clean control rejected or a hostile archive was accepted'
pass 'archive traversal and symlink imports are rejected'

# A zip made on Windows or macOS holds no Unix mode (zipinfo prints "-rw-a--" or "?---------"): it is plain files and
# folders and must install. The path checks still apply to it, and every refusal says that nothing was installed.
python3 - "$TMP" <<'PY' || fail 'could not build the zips made on other systems'
import sys
import zipfile

tmp = sys.argv[1]

def build(path, top, system, extra=()):
    with zipfile.ZipFile(path, 'w') as archive:
        entries = [(top + '/', True), (top + '/cinnamon/', True), (top + '/cinnamon/cinnamon.css', False)] + list(extra)
        for name, is_dir in entries:
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 26, 12, 0, 0))
            info.create_system = system
            if system == 3:
                info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
            else:
                info.external_attr = 0x10 if is_dir else 0x20
            archive.writestr(info, b'' if is_dir else b'css')

for system, label in ((3, 'Unix'), (0, 'Fat'), (11, 'Ntfs'), (19, 'Osx')):
    build(f'{tmp}/host{label}.zip', f'Host{label}', system)
build(f'{tmp}/fat-slip.zip', 'FatSlip', 0, extra=[('../escape', False)])
PY
HOME="$TMP/home-hosts" CM_HOME="$TMP/cm-hosts" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    for label in Unix Fat Ntfs Osx; do
        dest=$(cm_import_theme "$2/host${label}.zip") || exit 10
        [ "$dest" = "$HOME/.themes/Host${label}" ] && [ -f "$dest/cinnamon/cinnamon.css" ] || exit 11
    done
    before=$(find "$HOME/.themes" -mindepth 1 | wc -l)
    must_fail cm_import_theme "$2/fat-slip.zip" >/dev/null 2>&1
    [ "$(find "$HOME/.themes" -mindepth 1 | wc -l)" -eq "$before" ] || exit 12
    [ ! -e "$HOME/escape" ] && [ ! -e "$HOME/.themes/escape" ] || exit 13
' bash "$BODY" "$TMP" || fail 'zips made on Windows or macOS must install, and a path that leaves the folder must still be refused'
pass 'zips made on Windows and macOS install; their hostile paths are still refused'

mkdir -p "$TMP/no-theme/docs" && printf text > "$TMP/no-theme/docs/readme.txt"
for lang in en es; do
    case "$lang" in
        en) nothing='nothing was installed|Nothing was installed'; rejected='theme rejected'; not_a_theme='this is not a theme' ;;
        es) nothing='no se instaló nada|No se instaló nada'; rejected='tema rechazado'; not_a_theme='esto no es un tema' ;;
    esac
    for source in "$TMP/symlink.zip" "$TMP/traversal.zip" "$TMP/no-theme"; do
        case "$source" in */no-theme) reason="$not_a_theme" ;; *) reason="$rejected" ;; esac
        HOME="$TMP/home-refusal-$lang" CM_HOME="$TMP/cm-refusal-$lang" CM_LANG_OVERRIDE="$lang" bash -c '
            source "$1"
            cm_lang_init
            must_fail cm_import_theme "$2" 2>"$3" >/dev/null
        ' bash "$BODY" "$source" "$TMP/refusal.err" || fail "a refused theme must fail ($lang, ${source##*/})"
        grep -Eq "$nothing" "$TMP/refusal.err" || fail "the refusal must say nothing was installed ($lang, ${source##*/})"
        grep -q "$reason" "$TMP/refusal.err" || fail "the refusal must give the right reason ($lang, ${source##*/})"
        ! grep -Eiq 'will be installed|se instalará' "$TMP/refusal.err" || fail "the refusal still promises an installation ($lang, ${source##*/})"
        [ -z "$(find "$TMP/home-refusal-$lang/.themes" -mindepth 1 2>/dev/null)" ] || fail "a refused theme left files behind ($lang, ${source##*/})"
    done
done
HOME="$TMP/home-unreadable" CM_HOME="$TMP/cm-unreadable" CM_LANG_OVERRIDE=en bash -c '
    source "$1"
    cm_lang_init
    cp() { return 1; }
    must_fail cm_import_theme "$2" 2>"$3" >/dev/null
' bash "$BODY" "$TMP/clean/Clean" "$TMP/unreadable.err" || fail 'a theme folder that cannot be read must fail'
grep -q 'could not read the theme folder' "$TMP/unreadable.err" || fail 'an unreadable theme folder must be named as such'
pass 'a refused theme says why and that nothing was installed (English and Spanish)'

# ---------------------------------------------------------------------------------------------------------------------
# An archive is judged by what it unpacks to, never by what its directory says: a cap on the unpacked size,
# measured before anything is written, and a cap on the entries, counted before any Bash loop walks them.
# ---------------------------------------------------------------------------------------------------------------------
CAPS="$TMP/caps"
mkdir -p "$CAPS"
python3 - "$CAPS" <<'PY' || fail 'could not build the size and entry fixtures'
import io
import struct
import sys
import tarfile
import zipfile

out = sys.argv[1]
DATE = (2026, 11, 3, 12, 0, 0)
# 3 + 3 000 000 bytes of content, in every format.
THEME = [('Big/', None), ('Big/cinnamon/', None), ('Big/cinnamon/cinnamon.css', b'css'), ('Big/blob.bin', bytes(3_000_000))]


def zip_bytes(entries, stored=False):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=DATE)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
            is_dir = data is None
            info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
            archive.writestr(info, b'' if is_dir else data)
    return bytearray(buf.getvalue())


def lie(raw, name, size):
    """Overwrite the unpacked size that the central directory declares for `name`, as a hostile zip would."""
    at, hit = 0, 0
    while True:
        at = raw.find(b'PK\x01\x02', at)
        if at < 0:
            break
        length = struct.unpack_from('<H', raw, at + 28)[0]
        if bytes(raw[at + 46:at + 46 + length]) == name.encode():
            struct.pack_into('<I', raw, at + 24, size)
            hit += 1
        at += 4
    assert hit == 1
    return raw


def save(name, raw):
    with open(f'{out}/{name}', 'wb') as handle:
        handle.write(raw)


def save_tar(name, mode, entries):
    with tarfile.open(f'{out}/{name}', mode) as archive:
        for entry, data in entries:
            info = tarfile.TarInfo(entry.rstrip('/'))
            info.mtime = 0
            if data is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                archive.addfile(info)
            else:
                info.size, info.mode = len(data), 0o644
                archive.addfile(info, io.BytesIO(data))


save('big.zip', zip_bytes(THEME))
save('lie.zip', lie(zip_bytes(THEME), 'Big/blob.bin', 100))
save('lie-stored.zip', lie(zip_bytes(THEME, stored=True), 'Big/blob.bin', 100))
for name, mode in (('big.tar', 'w'), ('big.tar.gz', 'w:gz'), ('big.tgz', 'w:gz'), ('big.tar.xz', 'w:xz'),
                   ('big.tar.bz2', 'w:bz2'), ('big.tbz2', 'w:bz2')):
    save_tar(name, mode, THEME)
# Big and hostile at once: the structure must be refused before a byte of it is decoded.
save('bomb-slip.zip', zip_bytes(THEME + [('Big/../../escape', b'x')]))


def flood(count):
    head = [('Flood/', None), ('Flood/cinnamon/', None), ('Flood/cinnamon/cinnamon.css', b'css')]
    return head + [(f'Flood/cinnamon/f{i}.txt', b'') for i in range(count - len(head))]


for count in (20000, 20001):
    save(f'flood{count}.zip', zip_bytes(flood(count), stored=True))
    save_tar(f'flood{count}.tar.gz', 'w:gz', flood(count))
# 20 001 entries, one of them hostile: the count comes first.
save('flood-slip.zip', zip_bytes(flood(20000) + [('Flood/../../escape', b'x')], stored=True))

# 513 MiB of zeros in a zip of half a megabyte, streamed so that memory stays small.
with zipfile.ZipFile(f'{out}/huge.zip', 'w') as archive:
    for name, data in THEME[:3]:
        info = zipfile.ZipInfo(name, date_time=DATE)
        info.create_system = 3
        is_dir = data is None
        info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
        archive.writestr(info, b'' if is_dir else data)
    info = zipfile.ZipInfo('Big/blob.bin', date_time=DATE)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    with archive.open(info, 'w', force_zip64=True) as handle:
        for _ in range(513):
            handle.write(bytes(1 << 20))
PY

# Fixture guards: the zips really lie (the directory says 103 bytes, the data is 3 000 003), and the floods hold what
# their names say. Without them every case below could pass for the wrong reason.
for lying in lie.zip lie-stored.zip; do
    [ "$(LC_ALL=C zipinfo -t -- "$CAPS/$lying" | sed -n 's/.*, \([0-9]*\) bytes uncompressed.*/\1/p')" -eq 103 ] \
        || fail "fixture: $lying must declare 103 bytes unpacked"
    [ "$(unzip -p -- "$CAPS/$lying" </dev/null | wc -c | tr -d ' ')" -eq 3000003 ] || fail "fixture: $lying must hold 3000003 bytes"
done
[ "$(unzip -p -- "$CAPS/big.zip" </dev/null | wc -c | tr -d ' ')" -eq 3000003 ] || fail 'fixture: big.zip must hold 3000003 bytes'
[ "$(stat -c %s "$CAPS/lie.zip")" -lt 10000 ] || fail 'fixture: lie.zip must be tiny on disk (that is the point)'
[ "$(stat -c %s "$CAPS/huge.zip")" -lt 4000000 ] || fail 'fixture: huge.zip must be small on disk (that is the point)'
for count in 20000 20001; do
    [ "$(unzip -Z1 -- "$CAPS/flood$count.zip" | wc -l | tr -d ' ')" -eq "$count" ] || fail "fixture: flood$count.zip must hold $count entries"
    [ "$(tar -tzf "$CAPS/flood$count.tar.gz" | wc -l | tr -d ' ')" -eq "$count" ] || fail "fixture: flood$count.tar.gz must hold $count entries"
done
[ "$(unzip -Z1 -- "$CAPS/flood-slip.zip" | wc -l | tr -d ' ')" -eq 20001 ] || fail 'fixture: flood-slip.zip must hold 20001 entries'

# unzip and tar doubles log each call and run the real tool, so a case can tell whether anything was unpacked.
XBIN="$TMP/xbin"
mkdir -p "$XBIN"
for tool in unzip tar; do
    cat > "$XBIN/$tool" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "${FAKE_LOG:?}"
PATH="${REAL_PATH:?}" exec "${0##*/}" "$@"
FAKE
    chmod 755 "$XBIN/$tool"
done

# wc double: answers nothing, or garbage, to the one counter a case aims at (-c measures the size, -l counts the entries).
cat > "$XBIN/wc" <<'FAKE'
#!/usr/bin/env bash
case "${FAKE_WC_MODE:-real}:${1:-}" in
    size-empty:-c|entries-empty:-l) exit 0 ;;
    size-garbage:-c|entries-garbage:-l) echo banana; exit 0 ;;
esac
PATH="${REAL_PATH:?}" exec wc "$@"
FAKE
chmod 755 "$XBIN/wc"

# cap_case <case> <archive> <max unpacked bytes or -> <max entries or -> [lang] [wc mode]: cm_import_theme with those caps
# ("-" keeps the program's own). Output goes to <case>/out and <case>/err; the calls to unzip and tar go to <case>/log.
cap_case() {
    local id="$1" archive="$2" maxb="$3" maxe="$4" lang="${5:-en}" wcmode="${6:-real}" rc=0
    rm -rf "${TMP:?}/cap-$id"
    mkdir -p "$TMP/cap-$id/home" "$TMP/cap-$id/tmp"
    : > "$TMP/cap-$id/log"
    env HOME="$TMP/cap-$id/home" CM_HOME="$TMP/cap-$id/state" TMPDIR="$TMP/cap-$id/tmp" CM_LANG_OVERRIDE="$lang" \
        REAL_PATH="$PATH" PATH="$XBIN:$PATH" FAKE_LOG="$TMP/cap-$id/log" FAKE_WC_MODE="$wcmode" \
        bash -c 'source "$1"; cm_lang_init
                 [ "$2" = - ] || CM_MAX_UNPACKED_BYTES="$2"; [ "$3" = - ] || CM_MAX_ENTRIES="$3"
                 cm_import_theme "$4"' bash "$BODY" "$maxb" "$maxe" "$archive" > "$TMP/cap-$id/out" 2> "$TMP/cap-$id/err" || rc=$?
    return "$rc"
}
# cap_installed <case> <label>: the theme is in place, whole, and nothing was left in the temporary folder.
cap_installed() {
    local id="$1" label="$2"
    [ "$(cat "$TMP/cap-$id/out")" = "$TMP/cap-$id/home/.themes/Big" ] || fail "$label: the destination was not printed: $(cat "$TMP/cap-$id/out") / $(cat "$TMP/cap-$id/err")"
    [ "$(stat -c %s "$TMP/cap-$id/home/.themes/Big/blob.bin")" -eq 3000000 ] || fail "$label: the blob must be installed whole"
    [ -f "$TMP/cap-$id/home/.themes/Big/cinnamon/cinnamon.css" ] || fail "$label: the theme must be installed"
    [ -z "$(find "$TMP/cap-$id/tmp" -mindepth 1 2>/dev/null)" ] || fail "$label: the temporary folder must be empty"
}
# cap_refused <case> <label> <message>: exactly that message, an empty stdout, nothing installed, nothing left behind,
# and no archive was ever extracted (extraction is unzip -d or tar -C; counting and listing are not).
cap_refused() {
    local id="$1" label="$2" want="$3"
    [ "$(cat "$TMP/cap-$id/err")" = "$want" ] || fail "$label: wrong message: $(cat "$TMP/cap-$id/err")"
    [ ! -s "$TMP/cap-$id/out" ] || fail "$label: stdout must stay empty"
    [ -z "$(find "$TMP/cap-$id/home" -mindepth 1 2>/dev/null)" ] || fail "$label: nothing may be installed"
    [ -z "$(find "$TMP/cap-$id/tmp" -mindepth 1 2>/dev/null)" ] || fail "$label: the temporary folder must be empty"
    if grep -Eq '^(unzip .* -d |tar .* -C )' "$TMP/cap-$id/log"; then fail "$label: the archive must be refused before it is extracted"; fi
}
too_big() { printf '%s' "ERROR: '$1' unpacks to more than $2 MB or holds more than $3 files, or its size could not be measured, and it was discarded. Nothing was installed."; }

# Positive controls: every format installs whole under the program's own caps (and a lying directory changes nothing
# for an honest size).
for archive in big.zip lie.zip lie-stored.zip big.tar big.tar.gz big.tgz big.tar.xz big.tar.bz2 big.tbz2; do
    id="ok-${archive//./-}"
    rc=0; cap_case "$id" "$CAPS/$archive" - - || rc=$?
    [ "$rc" -eq 0 ] || fail "positive control: $archive must install under the default caps (exit $rc): $(cat "$TMP/cap-$id/err")"
    cap_installed "$id" "positive control $archive"
done
# The caps sit exactly where the program says: 3000003 bytes pass a 3000003 cap, and not a 3000002 one.
for archive in big.zip big.tar.gz; do
    id="edge-${archive//./-}"
    rc=0; cap_case "$id" "$CAPS/$archive" 3000003 - || rc=$?
    [ "$rc" -eq 0 ] || fail "$archive: exactly at the size cap must install (exit $rc): $(cat "$TMP/cap-$id/err")"
    cap_installed "$id" "$archive at the cap"
    rc=0; cap_case "$id-b" "$CAPS/$archive" 3000002 - || rc=$?
    [ "$rc" -eq 1 ] || fail "$archive: one byte over the size cap must be refused (exit $rc)"
    cap_refused "$id-b" "$archive one byte over" "$(too_big "$archive" 2 20000)"
done
pass 'archives of every supported format install whole under the default caps, and the size cap sits exactly at its limit'

# Over the cap: refused by what the archive holds, whatever its directory declares (lie.zip says 103 bytes).
for archive in big.zip lie.zip lie-stored.zip big.tar big.tar.gz big.tgz big.tar.xz big.tar.bz2 big.tbz2; do
    id="big-${archive//./-}"
    rc=0; cap_case "$id" "$CAPS/$archive" 2097152 - || rc=$?
    [ "$rc" -eq 1 ] || fail "$archive: more unpacked data than the cap must be refused (exit $rc)"
    cap_refused "$id" "$archive over the size cap" "$(too_big "$archive" 2 20000)"
done
rc=0; cap_case big-es "$CAPS/lie.zip" 2097152 - es || rc=$?
[ "$rc" -eq 1 ] || fail "Spanish: more unpacked data than the cap must be refused (exit $rc)"
cap_refused big-es 'Spanish' "ERROR: 'lie.zip' ocupa más de 2 MB descomprimido o tiene más de 20000 archivos, o no se pudo medir su tamaño, y se ha descartado. No se instaló nada."
pass 'an archive that unpacks to more than the cap is refused even when its directory declares less, in every format, with its reason (English and Spanish)'

# A count that cannot be read is a refusal, never "small enough": the counters answer nothing, or garbage.
for mode in size-empty size-garbage entries-empty entries-garbage; do
    rc=0; cap_case "unreadable-$mode" "$CAPS/big.zip" - - en "$mode" || rc=$?
    [ "$rc" -eq 1 ] || fail "$mode: a count that cannot be read must refuse the archive (exit $rc)"
    cap_refused "unreadable-$mode" "$mode" "$(too_big big.zip 512 20000)"
done
rc=0; cap_case unreadable-tar "$CAPS/big.tar.gz" - - en size-empty || rc=$?
[ "$rc" -eq 1 ] || fail "a tar whose size count cannot be read must be refused (exit $rc)"
cap_refused unreadable-tar 'tar, unreadable size' "$(too_big big.tar.gz 512 20000)"
pass 'a size or an entry count that cannot be read refuses the archive'

# The order: structure before size (a hostile archive is never decoded), entries before everything else.
rc=0; cap_case order-size "$CAPS/bomb-slip.zip" 2097152 - || rc=$?
[ "$rc" -eq 1 ] || fail "a hostile zip that is also over the cap must be refused (exit $rc)"
grep -q 'theme rejected' "$TMP/cap-order-size/err" || fail "a hostile zip must be refused for its structure: $(cat "$TMP/cap-order-size/err")"
if grep -q '^unzip -p' "$TMP/cap-order-size/log"; then fail 'a hostile zip must not be decoded to measure it'; fi
rc=0; cap_case order-count "$CAPS/flood-slip.zip" - - || rc=$?
[ "$rc" -eq 1 ] || fail "a hostile zip with 20001 entries must be refused (exit $rc)"
cap_refused order-count 'entries before structure' "$(too_big flood-slip.zip 512 20000)"
if grep -q '^unzip -p' "$TMP/cap-order-count/log"; then fail 'a flood must not be decoded'; fi
pass 'the order holds: entries counted first, structure judged next, size measured last'

# Entries: exactly the cap installs, one more is refused, in a zip and in a compressed tar.
for archive in flood20000.zip flood20000.tar.gz; do
    id="flood-ok-${archive//./-}"
    rc=0; cap_case "$id" "$CAPS/$archive" - - || rc=$?
    [ "$rc" -eq 0 ] || fail "$archive: exactly 20000 entries must install (exit $rc): $(cat "$TMP/cap-$id/err")"
    [ "$(cat "$TMP/cap-$id/out")" = "$TMP/cap-$id/home/.themes/Flood" ] || fail "$archive: the destination was not printed"
    [ "$(find "$TMP/cap-$id/home/.themes/Flood" -type f | wc -l | tr -d ' ')" -eq 19998 ] || fail "$archive: the 19998 files must be installed"
done
for archive in flood20001.zip flood20001.tar.gz; do
    id="flood-${archive//./-}"
    rc=0; cap_case "$id" "$CAPS/$archive" - - || rc=$?
    [ "$rc" -eq 1 ] || fail "$archive: 20001 entries must be refused (exit $rc)"
    cap_refused "$id" "$archive" "$(too_big "$archive" 512 20000)"
done
pass 'an archive with more entries than the cap is refused before it is listed or unpacked; exactly at the cap it installs'

# The default cap against real data, with the program's own numbers: 513 MiB in half a megabyte.
rc=0; cap_case huge "$CAPS/huge.zip" - - || rc=$?
[ "$rc" -eq 1 ] || fail "a zip that unpacks to 513 MiB must be refused with the default caps (exit $rc)"
cap_refused huge 'default caps, 513 MiB' "$(too_big huge.zip 512 20000)"
pass 'a zip of 513 MiB unpacked is refused by the default caps and installs nothing'

! grep -nE 'mktemp[[:space:]]+-u|^[[:space:]]*eval([[:space:]]|$)|(^|[[:space:]])ls[[:space:]]+-1[[:space:]]+"\$CM_BACKUP_DIR"|\|[[:space:]]*xargs([^[:alnum:]_-]|$)' "$SCRIPT" >/dev/null || fail 'known unsafe primitive detected'
pass 'known unsafe shell primitives remain absent'
