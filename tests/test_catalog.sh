#!/usr/bin/env bash
# Getting more material: a Cinnamon Spices theme downloaded by name, and a short list of distribution packages.
# Nothing here reaches the network or the system: curl, sudo, apt-get, dpkg-query and the terminal window are doubles
# that record how they were called, and every case has its own HOME, state folder and TMPDIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
SCRIPT="$ROOT/script/color-mint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/color-mint-catalog.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

BODY="$TMP/body.sh"
awk '/^# Command-line dispatcher/{exit} {print}' "$SCRIPT" > "$BODY"

# ---------------------------------------------------------------------------------------------------------------------
# Cinnamon Spices: theme fetch <name>
# ---------------------------------------------------------------------------------------------------------------------
# Zips shaped like the ones Spices publishes (one folder named after the theme), and the ways one can go wrong.
python3 - "$TMP" <<'PY' || fail 'could not build the zip fixtures'
import struct
import sys
import zipfile

tmp = sys.argv[1]


def build(path, entries, links=(), deflate=False):
    with zipfile.ZipFile(path, 'w') as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 27, 12, 0, 0))
            info.create_system = 3
            if deflate:
                info.compress_type = zipfile.ZIP_DEFLATED
            is_dir = name.endswith('/')
            info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
            archive.writestr(info, b'' if is_dir else data)
        for name, target in links:
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 27, 12, 0, 0))
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, target)


good = [('Fixture-Spice/', b''), ('Fixture-Spice/cinnamon/', b''), ('Fixture-Spice/cinnamon/cinnamon.css', b'css'),
        ('Fixture-Spice/metadata.json', b'{}')]
build(f'{tmp}/good.zip', good)
build(f'{tmp}/both.zip', [('Fixture-Both/', b''), ('Fixture-Both/cinnamon/', b''), ('Fixture-Both/cinnamon/cinnamon.css', b'css'),
                          ('Fixture-Both/gtk-3.0/', b''), ('Fixture-Both/gtk-3.0/gtk.css', b'css')])
build(f'{tmp}/wrongtop.zip', [(n.replace('Fixture-Spice', 'Other-Name'), d) for n, d in good])
build(f'{tmp}/extratop.zip', good + [('README.txt', b'x')])
build(f'{tmp}/flat.zip', [('cinnamon/', b''), ('cinnamon/cinnamon.css', b'css')])
build(f'{tmp}/slip.zip', good + [('Fixture-Spice/../../escape', b'x')])
build(f'{tmp}/link.zip', good, links=[('Fixture-Spice/cinnamon/escape', '/etc/passwd')])

# Small on the wire, large unpacked: zeros deflate about 1000 to 1, so the cap on the compressed size protects nothing.
bomb = good + [('Fixture-Spice/bomb.bin', bytes(3_000_000))]
# One entry only: zipinfo then says "1 file", not "1 files".
build(f'{tmp}/single.zip', [('Fixture-Spice/cinnamon/cinnamon.css', b'css')])
build(f'{tmp}/bomb.zip', bomb, deflate=True)
with open(f'{tmp}/bomb.total', 'w', encoding='utf-8') as handle:
    handle.write(str(sum(len(data) for _, data in bomb)) + '\n')


def lie(path, name, size):
    """Overwrite the unpacked size that the zip's central directory declares for `name`."""
    with open(path, 'rb') as handle:
        raw = bytearray(handle.read())
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
    with open(path, 'wb') as handle:
        handle.write(raw)


# The same bomb with a directory that understates it: 105 bytes declared, 3 000 005 held.
build(f'{tmp}/lie.zip', bomb, deflate=True)
lie(f'{tmp}/lie.zip', 'Fixture-Spice/bomb.bin', 100)
build(f'{tmp}/bombwrong.zip', [(n.replace('Fixture-Spice', 'Other-Name'), d) for n, d in bomb], deflate=True)
# 60 entries: the four of `good`, one folder and 55 files.
build(f'{tmp}/many.zip', good + [('Fixture-Spice/extra/', b'')] + [(f'Fixture-Spice/extra/f{i:02d}.txt', b'x') for i in range(55)])
# 20 001 entries, one past the default cap.
build(f'{tmp}/flood.zip', good + [(f'Fixture-Spice/extra/f{i}.txt', b'') for i in range(20_001 - len(good))])


def build_huge(path, mib):
    """The same theme plus one file of `mib` MiB of zeros, streamed so that memory stays small."""
    chunk = bytes(1 << 20)
    with zipfile.ZipFile(path, 'w') as archive:
        for name, data in good:
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 27, 12, 0, 0))
            info.create_system = 3
            is_dir = name.endswith('/')
            info.external_attr = ((0o40755 if is_dir else 0o100644) << 16) | (0x10 if is_dir else 0)
            archive.writestr(info, b'' if is_dir else data)
        info = zipfile.ZipInfo('Fixture-Spice/bomb.bin', date_time=(2026, 10, 27, 12, 0, 0))
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        with archive.open(info, 'w', force_zip64=True) as handle:
            for _ in range(mib):
                handle.write(chunk)


build_huge(f'{tmp}/huge.zip', 513)   # 537 919 488 bytes unpacked: just past 512 MiB
PY

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'FAKE'
#!/usr/bin/env bash
# Test double for curl: records the call, then plays the scenario named by FAKE_CURL_MODE.
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out="$2"; shift ;;
        --) break ;;
    esac
    shift
done
case "${FAKE_CURL_MODE:-ok}" in
    ok)      cp -- "${FAKE_CURL_ZIP:?}" "$out" ;;
    http404) echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22 ;;
    timeout) echo 'curl: (28) Operation timed out after 120001 milliseconds' >&2; exit 28 ;;
    toobig)  echo 'curl: (63) Maximum file size exceeded' >&2; exit 63 ;;
    empty)   : > "$out" ;;
    html)    printf '<html><body>Not found</body></html>' > "$out" ;;
    bytes)   head -c "${FAKE_CURL_BYTES:?}" /dev/zero > "$out"; status=$?
             stat -c %s "$out" > "${FAKE_CURL_LOG}.written"; exit "$status" ;;
    stream)  exec head -c "${FAKE_CURL_BYTES:?}" /dev/zero > "$out" ;;
esac
FAKE
chmod 755 "$FAKEBIN/curl"

# run_fetch <case> <lang> <mode> <zip> <name>: the real command line, in a case folder of its own.
# Output goes to <case>/out and <case>/err; the curl calls to <case>/curl.log.
run_fetch() {
    local id="$1" lang="$2" mode="$3" zip="$4" name="$5" rc=0
    rm -rf "${TMP:?}/$id"
    mkdir -p "$TMP/$id/home" "$TMP/$id/tmp"
    : > "$TMP/$id/curl.log"
    env HOME="$TMP/$id/home" CM_HOME="$TMP/$id/state" TMPDIR="$TMP/$id/tmp" CM_LANG_OVERRIDE="$lang" \
        PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE="$mode" FAKE_CURL_ZIP="$zip" FAKE_CURL_LOG="$TMP/$id/curl.log" \
        bash "$SCRIPT" theme fetch "$name" > "$TMP/$id/out" 2> "$TMP/$id/err" || rc=$?
    return "$rc"
}
left_behind() { find "$TMP/$1/tmp" -mindepth 1 2>/dev/null | head -n 1; }
installed_files() { find "$TMP/$1/home/.themes" "$TMP/$1/home/.icons" -mindepth 1 2>/dev/null | head -n 1; }

[ "$(PATH="$FAKEBIN:$PATH" command -v curl)" = "$FAKEBIN/curl" ] || fail 'the curl double must come first in PATH: a test must never reach the network'

# Positive control: a Spices-shaped zip installs under the name that was asked for, through the real command line.
rc=0; run_fetch ok en ok "$TMP/good.zip" Fixture-Spice || rc=$?
[ "$rc" -eq 0 ] || fail "a valid theme must install (exit $rc): $(cat "$TMP/ok/err")"
[ "$(cat "$TMP/ok/out")" = "$TMP/ok/home/.themes/Fixture-Spice" ] || fail 'the folder the theme was installed into must be printed on stdout, and only that'
[ -f "$TMP/ok/home/.themes/Fixture-Spice/cinnamon/cinnamon.css" ] || fail 'the theme files must be installed'
grep -q 'theme cinnamon Fixture-Spice (or the Themes tab)' "$TMP/ok/err" || fail 'the way to use the theme must be told (English)'
[ -z "$(left_behind ok)" ] || fail "the download must leave no temporary files: $(left_behind ok)"
[ "$(wc -l < "$TMP/ok/curl.log")" -eq 1 ] || fail 'one request per theme'
call="$(cat "$TMP/ok/curl.log")"
for flag in '--fail ' '--max-redirs 3 ' '--proto =https ' '--proto-redir =https ' '--max-filesize 33554432 ' '--max-time 120 ' '--connect-timeout 15 ' '--tlsv1.2 '; do
    case "$call" in *"$flag"*) ;; *) fail "the request must carry $flag";; esac
done
# The address is the one of the Download link on a theme's page: /files/themes/<UUID>.zip with the time as a cache-buster.
[[ "$call" =~ ' -- https://cinnamon-spices.linuxmint.com/files/themes/Fixture-Spice.zip?time='[0-9]{10,}$ ]] || fail "wrong address: $call"
case "$call" in *http://*|*' -k '*|*--insecure*|*--output\ /dev/null*) fail "the request must never be plain HTTP or skip the certificate check: $call";; esac
rc=0; run_fetch ok-es es ok "$TMP/good.zip" Fixture-Spice || rc=$?
[ "$rc" -eq 0 ] && grep -q 'Para usarlo: .* theme cinnamon Fixture-Spice (o la pestaña Temas)' "$TMP/ok-es/err" || fail 'the way to use the theme must be told (Spanish)'
rc=0; run_fetch both en ok "$TMP/both.zip" Fixture-Both || rc=$?
[ "$rc" -eq 0 ] && grep -q 'theme gtk Fixture-Both / .*theme cinnamon Fixture-Both' "$TMP/both/err" || fail 'a theme with GTK and Cinnamon parts must offer both commands'
pass 'theme fetch installs a Spices-shaped zip over HTTPS only, prints where, says how to use it and leaves nothing behind'

# The name goes into an address and a path: only what a Spices name is made of is accepted. Every theme the repository
# held on 2026-10-11 (108 names) must pass, so the rule cannot be tightened into refusing a real one.
read -r -d '' -a spices_names <<'NAMES' || true
Adapta Adapta-Nokto Adara Adara-Dark Ambiance-Crunchy Ambiance-Minty Aune Baldr BelaLugosi Blue-mint Brunnera
Brunnera-Dark CBlack CBlack-Remix CBlue CGreen CPurple Carta Chicago95 Chillies Chinvat ChromeOS
Cinnamox-Aubergine Cinnamox-Gold-Spice Cinnamox-Heather Cinnamox-Kashmir-Blue Cinnamox-Rhino
Cinnamox-Rosso-Cursa Cinnamox-Willow-Grove Discreet-Flat Divo Eleganse Eleganse-dark Facebook Faded-Dream
Faience Fluent Fraiche Fresh-Cinnamon Glass-Mint-Classic GraphX Graphite Graphite-One Graphite-Zero Jade-1
Jade-1-Blue Jet-Gray Kiss-Kool-Viper LM-Light-Panel Linux-Mint-Refreshed Loki MGSE-Unity Material
Metallic_Cyan Mint-Modern-Office-Night Mint-X-Dark Mint-XP Minty Mojave-Dark Mojave-Light Monternos Moonstone
Nergis Nergis-Dark Nergis-Light New-Minty Nocturne Numix-Cinnamon-Semi-Transparent Numix-Cinnamon-Transparent
Obsidian Orchidea OrchideaDock Orchis-Dark Orchis-Light Pepper Photocopy Pragmatic-Darker-Blue Qogir-Dark
Qogir-Light Railway Serena Silk SimpleDock Smoke Soul-Dark Soul-Light Spearmint-Leaf Spider-Void Thunderbolt
Tomcat Tyr-himinn Tyr-jord Ubuntu-touch Vivaldi Vivaldi-ZorinOS WhiteSur-Dark-solid WhiteSur-Light-solid
Win7-Tux-Noir Windows-10 Windows-10-Basic Windows-10-Dark Winterbloom Yaru-cinnamon Yaru-cinnamon-dark
cinnamon-Hacker iOS-X qob waterbody
NAMES
[ "${#spices_names[@]}" -eq 108 ] || fail "the list of real Spices names must hold 108 names, not ${#spices_names[@]}"
# shellcheck disable=SC2016  # the dollar signs and the backquote are the point: they must be refused
bad_names=('' . .. ... .hidden -rf a/b 'a b' 'Fresh Cinnamon' 'a;b' 'a$b' 'a`b' 'a%2e' 'a\b' 'a|b' 'a&b' "a'b" 'a"b' 'a*b' 'a?b' 'ñandú' 'a..b' '../x' $'a\nb' $'a\tb' $'a\033b'
           "$(printf 'x%.0s' $(seq 1 65))")
HOME="$TMP/home-names" CM_HOME="$TMP/state-names" CM_LANG_OVERRIDE=en bash -c '
    source "$1"; cm_lang_init
    shift
    mode=good
    for name in "$@"; do
        if [ "$name" = "--bad" ]; then mode=bad; continue; fi
        if [ "$mode" = good ]; then
            cm_spices_name_ok "$name" || { printf "a real Spices name was refused: %s\n" "$name"; exit 1; }
        else
            if cm_spices_name_ok "$name"; then printf "a name that is not a Spices name was accepted: %q\n" "$name"; exit 1; fi
        fi
    done
    cm_spices_name_ok "$(printf "x%.0s" $(seq 1 64))" || { echo "64 characters must be allowed"; exit 1; }
    cm_spices_name_ok "Jade-1" && cm_spices_name_ok "Metallic_Cyan" && cm_spices_name_ok "v1.2-beta" || { echo "valid names refused"; exit 1; }
' bash "$BODY" "${spices_names[@]}" --bad "${bad_names[@]}" || fail 'theme name validation'
for name in '../x' 'a/b' 'a b' 'Fresh Cinnamon' '-rf' ''; do
    rc=0; run_fetch name en ok "$TMP/good.zip" "$name" || rc=$?
    [ "$rc" -eq 1 ] || fail "a bad name must stop the command (exit $rc): $name"
    [ ! -s "$TMP/name/curl.log" ] || fail "a bad name must never reach curl: $name"
    [ -z "$(installed_files name)" ] && [ -z "$(left_behind name)" ] || fail "a bad name must leave nothing behind: $name"
    if [ -n "$name" ]; then grep -q 'is not a Spices theme name' "$TMP/name/err" && grep -q 'UUID' "$TMP/name/err" || fail "a bad name must be named as such, with the UUID hint: $name"; else grep -q 'enter the exact name' "$TMP/name/err" || fail 'no name must ask for one'; fi
done
rc=0; run_fetch name-es es ok "$TMP/good.zip" 'a b' || rc=$?
[ "$rc" -eq 1 ] && grep -q 'no es un nombre de tema de Spices' "$TMP/name-es/err" || fail 'a bad name must be named as such (Spanish)'
pass 'theme names: the 108 real ones pass, anything that could change an address or a path is refused before curl runs'

# A theme that is already there is never downloaded again, and never overwritten.
for place in .themes .icons; do
    rc=0
    rm -rf "${TMP:?}/there"; mkdir -p "$TMP/there/home/$place/Fixture-Spice"; printf mine > "$TMP/there/home/$place/Fixture-Spice/marker"
    run_there() { env HOME="$TMP/there/home" CM_HOME="$TMP/there/state" TMPDIR="$TMP/there/tmp" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" \
        FAKE_CURL_MODE=ok FAKE_CURL_ZIP="$TMP/good.zip" FAKE_CURL_LOG="$TMP/there/curl.log" bash "$SCRIPT" theme fetch Fixture-Spice > "$TMP/there/out" 2> "$TMP/there/err"; }
    mkdir -p "$TMP/there/tmp"; : > "$TMP/there/curl.log"
    run_there || rc=$?
    [ "$rc" -eq 0 ] || fail "a theme already installed is not an error (exit $rc, $place)"
    [ "$(cat "$TMP/there/out")" = "$TMP/there/home/$place/Fixture-Spice" ] || fail "the existing folder must be printed ($place)"
    grep -q 'already at' "$TMP/there/err" || fail "the user must be told it is already there ($place)"
    [ ! -s "$TMP/there/curl.log" ] || fail "an installed theme must not be downloaded again ($place)"
    [ "$(cat "$TMP/there/home/$place/Fixture-Spice/marker")" = mine ] || fail "an installed theme must not be touched ($place)"
    [ "$(find "$TMP/there/home" -mindepth 2 -maxdepth 2 | wc -l)" -eq 1 ] || fail "no numbered copy may appear ($place)"
done
rm -rf "${TMP:?}/there"; mkdir -p "$TMP/there/home/.themes" "$TMP/there/tmp"; ln -s "$TMP/there/nowhere" "$TMP/there/home/.themes/Fixture-Spice"; : > "$TMP/there/curl.log"
run_there || fail 'a dangling link in the way is "already there" too, not a reason to write through it'
[ ! -s "$TMP/there/curl.log" ] && [ ! -e "$TMP/there/nowhere" ] || fail 'nothing may be written through a link that is in the way'
pass 'a theme that is already installed is reported, not downloaded again or overwritten, and no numbered copy appears'

# Every way a download can go wrong ends the same way: exit 1, a reason, nothing installed, nothing left in /tmp.
check_refusal() {   # <case> <lang> <mode> <zip> <message pattern> <label>
    local id="$1" lang="$2" mode="$3" zip="$4" pattern="$5" label="$6" rc=0 nothing='Nothing was installed'
    [ "$lang" = en ] || nothing='No se instaló nada|no se instaló nada'
    run_fetch "$id" "$lang" "$mode" "$zip" Fixture-Spice || rc=$?
    [ "$rc" -eq 1 ] || fail "$label: exit $rc instead of 1"
    [ ! -s "$TMP/$id/out" ] || fail "$label: stdout must stay empty"
    grep -Eq "$pattern" "$TMP/$id/err" || fail "$label: the reason is missing: $(cat "$TMP/$id/err")"
    grep -Eq "$nothing|nothing was installed" "$TMP/$id/err" || fail "$label: it must say that nothing was installed"
    [ -z "$(installed_files "$id")" ] || fail "$label: files were installed: $(installed_files "$id")"
    [ -z "$(left_behind "$id")" ] || fail "$label: temporary files left behind: $(left_behind "$id")"
}
check_refusal r-404 en http404 "$TMP/good.zip" "could not download 'Fixture-Spice'.*|\(22\) The requested URL returned error: 404" 'HTTP error'
check_refusal r-time en timeout "$TMP/good.zip" '\(28\) Operation timed out' 'timeout'
check_refusal r-big en toobig "$TMP/good.zip" "larger than 32 MB" 'size announced by the server'
check_refusal r-empty en empty "$TMP/good.zip" "could not download 'Fixture-Spice'" 'empty answer'
check_refusal r-html en html "$TMP/good.zip" "is not a .zip file" 'an error page instead of a zip'
check_refusal r-wrong en ok "$TMP/wrongtop.zip" 'does not hold the theme in a folder of that name' 'folder with another name'
check_refusal r-extra en ok "$TMP/extratop.zip" 'does not hold the theme in a folder of that name' 'an extra file beside the folder'
check_refusal r-flat en ok "$TMP/flat.zip" 'does not hold the theme in a folder of that name' 'no folder at all'
check_refusal r-slip en ok "$TMP/slip.zip" 'theme rejected' 'a path that leaves the folder'
check_refusal r-link en ok "$TMP/link.zip" 'theme rejected' 'a link inside the theme'
check_refusal r-404-es es http404 "$TMP/good.zip" "no se pudo descargar 'Fixture-Spice'" 'HTTP error (Spanish)'
check_refusal r-big-es es toobig "$TMP/good.zip" 'supera los 32 MB' 'size (Spanish)'
check_refusal r-html-es es html "$TMP/good.zip" 'no es un archivo .zip' 'error page (Spanish)'
check_refusal r-wrong-es es ok "$TMP/wrongtop.zip" 'no trae el tema dentro de una carpeta con ese nombre' 'folder name (Spanish)'
check_refusal r-slip-es es ok "$TMP/slip.zip" 'tema rechazado' 'hostile path (Spanish)'
pass 'a failed, oversized, wrong or hostile download is refused with its reason, installs nothing and leaves nothing (English and Spanish)'

# The size cap holds even when the server announces no length: the process may not write past it, and what arrived is
# measured. 2 MB stands for 32 MB here; the double writes 5 MB (past the limit, also as the program curl would end: killed
# by the signal if it were not ignored) or just over the cap (under the limit).
cap_case() {   # <case> <bytes> [mode]
    local id="$1" bytes="$2" mode="${3:-bytes}" rc=0
    rm -rf "${TMP:?}/$id"; mkdir -p "$TMP/$id/home" "$TMP/$id/tmp"; : > "$TMP/$id/curl.log"
    env HOME="$TMP/$id/home" CM_HOME="$TMP/$id/state" TMPDIR="$TMP/$id/tmp" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" \
        FAKE_CURL_MODE="$mode" FAKE_CURL_BYTES="$bytes" FAKE_CURL_LOG="$TMP/$id/curl.log" \
        bash -c 'source "$1"; cm_lang_init; CM_FETCH_MAX_BYTES=2097152; cm_fetch_theme Fixture-Spice' bash "$BODY" > "$TMP/$id/out" 2> "$TMP/$id/err" || rc=$?
    [ "$rc" -eq 1 ] || fail "$id: exit $rc instead of 1"
    [ "$(cat "$TMP/$id/err")" = "ERROR: the download of 'Fixture-Spice' is larger than 2 MB and was discarded. Nothing was installed." ] \
        || fail "$id: exactly the size message was expected (no signal noise): $(cat "$TMP/$id/err")"
    [ -z "$(installed_files "$id")" ] && [ -z "$(left_behind "$id")" ] || fail "$id: nothing may stay behind"
    if [ -f "$TMP/$id/curl.log.written" ]; then
        [ "$(cat "$TMP/$id/curl.log.written")" -le $((2097152 + 1024)) ] || fail "$id: the process wrote $(cat "$TMP/$id/curl.log.written") bytes, past the size limit"
    fi
}
cap_case cap-flood 5000000
cap_case cap-over 2097162
cap_case cap-stream 5000000 stream
rc=0
rm -rf "${TMP:?}/cap-ok"; mkdir -p "$TMP/cap-ok/home" "$TMP/cap-ok/tmp"; : > "$TMP/cap-ok/curl.log"
env HOME="$TMP/cap-ok/home" CM_HOME="$TMP/cap-ok/state" TMPDIR="$TMP/cap-ok/tmp" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" \
    FAKE_CURL_MODE=ok FAKE_CURL_ZIP="$TMP/good.zip" FAKE_CURL_LOG="$TMP/cap-ok/curl.log" \
    bash -c 'source "$1"; cm_lang_init; CM_FETCH_MAX_BYTES=2097152; cm_fetch_theme Fixture-Spice' bash "$BODY" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail 'positive control: a small theme must still install under a small cap'
pass 'the size cap holds without an announced length (process limit and measured size) and a small theme still installs'

# A zip can be tiny on the wire and still unpack into a flood: what its directory declares is capped too, before the
# archive is listed or unpacked. zipinfo and unzip are doubles that log each call and run the real tool, except that
# zipinfo -t can be made to answer garbage.
ZIPBIN="$TMP/zipbin"
mkdir -p "$ZIPBIN"
cat > "$ZIPBIN/zipinfo" <<'FAKE'
#!/usr/bin/env bash
printf 'zipinfo %s\n' "$*" >> "${FAKE_ZIP_LOG:?}"
if [ "${1:-}" = -t ]; then
    case "${FAKE_ZIPINFO_MODE:-real}" in
        garbage)   echo 'banana'; exit 0 ;;
        huge)      echo '1 file, 99999999999999999999999 bytes uncompressed, 1 bytes compressed:  0.0%'; exit 0 ;;
        manyfiles) echo '99999999999 files, 5 bytes uncompressed, 5 bytes compressed:  0.0%'; exit 0 ;;
        negative)  echo '1 file, -5 bytes uncompressed, 5 bytes compressed:  0.0%'; exit 0 ;;
        failed)    echo 'zipinfo: cannot find zipfile directory' >&2; exit 9 ;;
    esac
fi
PATH="${REAL_PATH:?}" exec zipinfo "$@"
FAKE
cat > "$ZIPBIN/unzip" <<'FAKE'
#!/usr/bin/env bash
printf 'unzip %s\n' "$*" >> "${FAKE_ZIP_LOG:?}"
PATH="${REAL_PATH:?}" exec unzip "$@"
FAKE
chmod 755 "$ZIPBIN/zipinfo" "$ZIPBIN/unzip"

# unpack_case <case> <zip> <max unpacked bytes or -> <max entries or -> [zipinfo mode] [lang]: cm_fetch_theme with those
# caps ("-" keeps the program's own). Output goes to <case>/out and <case>/err.
unpack_case() {
    local id="$1" zip="$2" maxb="$3" maxe="$4" mode="${5:-real}" lang="${6:-en}" rc=0
    rm -rf "${TMP:?}/$id"; mkdir -p "$TMP/$id/home" "$TMP/$id/tmp"; : > "$TMP/$id/curl.log"; : > "$TMP/$id/zip.log"
    env HOME="$TMP/$id/home" CM_HOME="$TMP/$id/state" TMPDIR="$TMP/$id/tmp" CM_LANG_OVERRIDE="$lang" \
        REAL_PATH="$PATH" PATH="$ZIPBIN:$FAKEBIN:$PATH" FAKE_ZIPINFO_MODE="$mode" FAKE_ZIP_LOG="$TMP/$id/zip.log" \
        FAKE_CURL_MODE=ok FAKE_CURL_ZIP="$zip" FAKE_CURL_LOG="$TMP/$id/curl.log" \
        bash -c 'source "$1"; cm_lang_init
                 [ "$2" = - ] || CM_MAX_UNPACKED_BYTES="$2"; [ "$3" = - ] || CM_MAX_ENTRIES="$3"
                 cm_fetch_theme Fixture-Spice' bash "$BODY" "$maxb" "$maxe" > "$TMP/$id/out" 2> "$TMP/$id/err" || rc=$?
    return "$rc"
}
# refused_unpacked <case> <MB shown> <files shown> <label> [message]: exactly the size message, nothing installed,
# nothing left, and the zip was never listed or unpacked.
refused_unpacked() {
    local id="$1" mb="$2" files="$3" label="$4"
    local want="${5:-ERROR: the .zip of 'Fixture-Spice' declares more than $mb MB unpacked or more than $files files, or its size cannot be read, and it was discarded. Nothing was installed.}"
    [ "$(cat "$TMP/$id/err")" = "$want" ] || fail "$label: exactly the unpacked-size message was expected: $(cat "$TMP/$id/err")"
    [ ! -s "$TMP/$id/out" ] || fail "$label: stdout must stay empty"
    [ -z "$(installed_files "$id")" ] && [ -z "$(left_behind "$id")" ] || fail "$label: nothing may stay behind"
    if grep -q '^unzip ' "$TMP/$id/zip.log"; then fail "$label: the zip must be refused before it is listed or unpacked"; fi
}
bomb_total="$(cat "$TMP/bomb.total")"
[ "$bomb_total" -eq 3000005 ] || fail "fixture: the bomb must declare 3000005 bytes, not $bomb_total"
[ "$(stat -c %s "$TMP/bomb.zip")" -lt 10000 ] || fail 'fixture: the bomb must be tiny compressed (that is the point)'
[ "$(unzip -Z1 -- "$TMP/many.zip" | wc -l | tr -d ' ')" -eq 60 ] || fail 'fixture: many.zip must hold 60 entries'
[ "$(unzip -Z1 -- "$TMP/flood.zip" | wc -l | tr -d ' ')" -eq 20001 ] || fail 'fixture: flood.zip must hold 20001 entries'
[ "$(stat -c %s "$TMP/huge.zip")" -lt 4000000 ] || fail 'fixture: huge.zip must be small compressed (that is the point)'

# The limits are part of what the program promises: changing them must be deliberate.
HOME="$TMP/home-limits" CM_HOME="$TMP/state-limits" CM_LANG_OVERRIDE=en bash -c '
    source "$1"; cm_lang_init
    [ "$CM_MAX_UNPACKED_BYTES" -eq 536870912 ] || { echo "unpacked cap: $CM_MAX_UNPACKED_BYTES"; exit 1; }
    [ "$CM_MAX_ENTRIES" -eq 20000 ] || { echo "entries cap: $CM_MAX_ENTRIES"; exit 1; }
' bash "$BODY" || fail 'the default caps must be 512 MiB unpacked and 20000 entries'

# Positive controls first: the doubles in the path change nothing, and a zip exactly at each cap installs.
rc=0; unpack_case u-ok "$TMP/good.zip" - - || rc=$?
[ "$rc" -eq 0 ] || fail "positive control: a small theme must install with the zipinfo and unzip doubles in the path (exit $rc): $(cat "$TMP/u-ok/err")"
grep -q '^zipinfo -t ' "$TMP/u-ok/zip.log" || fail 'the declared size must be read with zipinfo -t'
rc=0; unpack_case u-single "$TMP/single.zip" - - || rc=$?
[ "$rc" -eq 0 ] && [ -f "$TMP/u-single/home/.themes/Fixture-Spice/cinnamon/cinnamon.css" ] \
    || fail "a zip of one entry (\"1 file\") must install (exit $rc): $(cat "$TMP/u-single/err")"
rc=0; unpack_case u-edge "$TMP/bomb.zip" "$bomb_total" - || rc=$?
[ "$rc" -eq 0 ] && [ "$(stat -c %s "$TMP/u-edge/home/.themes/Fixture-Spice/bomb.bin")" -eq 3000000 ] \
    || fail "a zip that declares exactly the cap must install (exit $rc): $(cat "$TMP/u-edge/err")"
rc=0; unpack_case u-edge-n "$TMP/many.zip" - 60 || rc=$?
[ "$rc" -eq 0 ] && [ -f "$TMP/u-edge-n/home/.themes/Fixture-Spice/extra/f54.txt" ] \
    || fail "a zip with exactly as many entries as the cap must install (exit $rc): $(cat "$TMP/u-edge-n/err")"

# One byte or one entry over the cap, and a real flood against the real defaults.
rc=0; unpack_case u-bomb "$TMP/bomb.zip" 2097152 - || rc=$?
[ "$rc" -eq 1 ] || fail "a 3 KB zip that unpacks to 3 MB must be refused under a 2 MB cap (exit $rc)"
refused_unpacked u-bomb 2 20000 'unpacked size past the cap'
rc=0; unpack_case u-edge-b "$TMP/bomb.zip" $((bomb_total - 1)) - || rc=$?
[ "$rc" -eq 1 ] || fail "one byte over the unpacked cap must be refused (exit $rc)"
refused_unpacked u-edge-b 2 20000 'one byte over'
rc=0; unpack_case u-many "$TMP/many.zip" - 59 || rc=$?
[ "$rc" -eq 1 ] || fail "one entry over the cap must be refused (exit $rc)"
refused_unpacked u-many 512 59 'one entry over'
rc=0; unpack_case u-flood "$TMP/flood.zip" - - || rc=$?
[ "$rc" -eq 1 ] || fail "20001 entries must be refused by the default cap (exit $rc)"
refused_unpacked u-flood 512 20000 '20001 entries'
rc=0; run_fetch u-huge en ok "$TMP/huge.zip" Fixture-Spice || rc=$?
[ "$rc" -eq 1 ] || fail "a small zip that unpacks to 513 MiB must be refused by the real command (exit $rc)"
[ "$(cat "$TMP/u-huge/err")" = "ERROR: the .zip of 'Fixture-Spice' declares more than 512 MB unpacked or more than 20000 files, or its size cannot be read, and it was discarded. Nothing was installed." ] \
    || fail "513 MiB of zeros, real command line, default caps: $(cat "$TMP/u-huge/err")"
[ ! -s "$TMP/u-huge/out" ] && [ -z "$(installed_files u-huge)" ] && [ -z "$(left_behind u-huge)" ] || fail 'the 513 MiB zip must install and leave nothing'
# The size is judged before the structure: an oversized zip with the wrong layout is reported as oversized, so the
# bounded check is what runs first on anything that arrives.
rc=0; unpack_case u-order "$TMP/bombwrong.zip" 2097152 - || rc=$?
[ "$rc" -eq 1 ] || fail "an oversized zip with the wrong layout must be refused (exit $rc)"
refused_unpacked u-order 2 20000 'size before structure'
rc=0; unpack_case u-es "$TMP/bomb.zip" 2097152 - real es || rc=$?
[ "$rc" -eq 1 ] || fail "the Spanish run must be refused too (exit $rc)"
refused_unpacked u-es 2 20000 'Spanish' \
    "ERROR: el .zip de 'Fixture-Spice' declara más de 2 MB descomprimidos o más de 20000 archivos, o no se puede leer su tamaño, y se ha descartado. No se instaló nada."

# A directory zipinfo cannot read, or numbers that are not numbers, are refused: never read as "small enough".
for mode in garbage huge manyfiles negative failed; do
    rc=0; unpack_case "u-$mode" "$TMP/good.zip" - - "$mode" || rc=$?
    [ "$rc" -eq 1 ] || fail "zipinfo -t answering '$mode' must stop the command (exit $rc)"
    refused_unpacked "u-$mode" 512 20000 "zipinfo -t answering '$mode'"
done
pass 'theme fetch refuses a zip that declares too much unpacked data or too many entries, or whose totals cannot be read, before listing or unpacking it'

# A zip whose directory understates what it holds passes the declared check (zipinfo -t says 105) and is stopped by the
# measured size, the same one `theme import` applies: nothing is extracted, installed or left behind.
[ "$(LC_ALL=C zipinfo -t -- "$TMP/lie.zip" | sed -n 's/.*, \([0-9]*\) bytes uncompressed.*/\1/p')" -eq 105 ] || fail 'fixture: lie.zip must declare 105 bytes'
[ "$(unzip -p -- "$TMP/lie.zip" </dev/null | wc -c | tr -d ' ')" -eq 3000005 ] || fail 'fixture: lie.zip must hold 3000005 bytes'
rc=0; unpack_case u-lie "$TMP/lie.zip" 2097152 - || rc=$?
[ "$rc" -eq 1 ] || fail "a zip that holds more than it declares must be refused by the measured size (exit $rc)"
[ "$(cat "$TMP/u-lie/err")" = "ERROR: 'Fixture-Spice.zip' unpacks to more than 2 MB or holds more than 20000 files, or its size could not be measured, and it was discarded. Nothing was installed." ] \
    || fail "a lying zip: exactly the measured-size message was expected: $(cat "$TMP/u-lie/err")"
[ ! -s "$TMP/u-lie/out" ] && [ -z "$(installed_files u-lie)" ] && [ -z "$(left_behind u-lie)" ] || fail 'a lying zip must install nothing and leave nothing'
if grep -Eq '^unzip .* -d ' "$TMP/u-lie/zip.log"; then fail 'a lying zip must be refused before it is extracted'; fi
rc=0; unpack_case u-lie-ok "$TMP/lie.zip" 4194304 - || rc=$?
[ "$rc" -eq 0 ] && [ "$(stat -c %s "$TMP/u-lie-ok/home/.themes/Fixture-Spice/bomb.bin")" -eq 3000000 ] \
    || fail "positive control: the same zip must install when its real size fits the cap (exit $rc): $(cat "$TMP/u-lie-ok/err")"
pass 'a zip that understates its size in its directory is stopped by the measured size through theme fetch, and installs when it fits'

# Missing tools are named before anything is downloaded or created.
for tool in curl unzip zipinfo; do
    rc=0
    rm -rf "${TMP:?}/tool"; mkdir -p "$TMP/tool/home" "$TMP/tool/tmp"; : > "$TMP/tool/curl.log"
    env HOME="$TMP/tool/home" CM_HOME="$TMP/tool/state" TMPDIR="$TMP/tool/tmp" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" \
        FAKE_CURL_MODE=ok FAKE_CURL_ZIP="$TMP/good.zip" FAKE_CURL_LOG="$TMP/tool/curl.log" \
        MISSING_TOOL="$tool" bash -c '
            source "$1"; cm_lang_init
            command() { if [ "${1:-}" = -v ] && [ "${2:-}" = "$MISSING_TOOL" ]; then return 1; fi; builtin command "$@"; }
            cm_fetch_theme Fixture-Spice
        ' bash "$BODY" > "$TMP/tool/out" 2> "$TMP/tool/err" || rc=$?
    [ "$rc" -eq 1 ] || fail "a missing $tool must stop the command (exit $rc)"
    [ ! -s "$TMP/tool/curl.log" ] || fail "a missing $tool must be found before downloading"
    [ -z "$(left_behind tool)" ] && [ -z "$(installed_files tool)" ] || fail "a missing $tool must leave nothing behind"
    case "$tool" in
        curl) grep -q "'curl' is required" "$TMP/tool/err" || fail 'a missing curl must be named' ;;
        *)    grep -q "'unzip' is required" "$TMP/tool/err" || fail "a missing $tool must be named as unzip" ;;
    esac
done
pass 'missing curl or unzip are named before anything is downloaded'

# The command is on the help screen, in both languages.
for lang in en es; do
    help="$(CM_LANG_OVERRIDE=$lang bash "$SCRIPT" --help)"
    grep -q 'theme fetch <name\|theme fetch <nombre>' <<< "$help" || fail "help must list theme fetch ($lang)"
    grep -q 'theme list-packages' <<< "$help" || fail "help must list theme list-packages ($lang)"
    grep -q 'theme install <package>\|theme install <paquete>' <<< "$help" || fail "help must list theme install ($lang)"
done
pass 'theme fetch is on the help screen in English and Spanish'

# ---------------------------------------------------------------------------------------------------------------------
# Theme packages: a short verified list, and ONE apt install flow for it and for the GUI's missing dependencies
# ---------------------------------------------------------------------------------------------------------------------
# Doubles: sudo, apt-get, dpkg-query, the terminal window, yad and notify-send. apt-get "installs" by writing the package
# into a status file that dpkg-query reads, and drops a command into the case's tools folder for the dependency package.
cat > "$FAKEBIN/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${FAKE_APT_LOG:?}"
exec "$@"
FAKE
cat > "$FAKEBIN/apt-get" <<'FAKE'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${FAKE_APT_LOG:?}"
[ "${FAKE_APT_MODE:-ok}" != fail3 ] || exit 3
[ "${FAKE_APT_MODE:-ok}" = ok ] || exit 100
[ "${1:-}" = install ] || exit 0
shift
for pkg in "$@"; do
    case "$pkg" in -*) continue ;; esac
    printf '%s\n' "$pkg" >> "${FAKE_DPKG_DB:?}"
    if [ "$pkg" = fake-pkg-cm-test-missing-tool ]; then
        printf '#!/bin/sh\nexit 0\n' > "${FAKE_TOOL_DIR:?}/cm-test-missing-tool"
        chmod 755 "${FAKE_TOOL_DIR:?}/cm-test-missing-tool"
    fi
done
FAKE
cat > "$FAKEBIN/dpkg-query" <<'FAKE'
#!/usr/bin/env bash
pkg="${!#}"
if grep -qx -- "$pkg" "${FAKE_DPKG_DB:?}" 2>/dev/null; then printf 'ii '; else exit 1; fi
FAKE
cat > "$FAKEBIN/x-terminal-emulator" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_TERM_LOG:?}"
[ "${FAKE_TERM_MODE:-run}" = run ] || exit 0
shift   # -e
"$@" < /dev/null > /dev/null 2>&1
FAKE
cat > "$FAKEBIN/yad" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *--question*) exit "${FAKE_YAD_ANSWER:-0}" ;; esac
exit 0
FAKE
cat > "$FAKEBIN/notify-send" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_NOTIFY_LOG:-/dev/null}"
FAKE
chmod 755 "$FAKEBIN"/sudo "$FAKEBIN"/apt-get "$FAKEBIN"/dpkg-query "$FAKEBIN"/x-terminal-emulator "$FAKEBIN"/yad "$FAKEBIN"/notify-send

# The list is part of what the program promises: changing it must be deliberate.
expected_packages='arc-theme materia-gtk-theme numix-gtk-theme papirus-icon-theme numix-icon-theme-circle breeze-icon-theme elementary-icon-theme bibata-cursor-theme dmz-cursor-theme breeze-cursor-theme'
HOME="$TMP/home-table" CM_HOME="$TMP/state-table" CM_LANG_OVERRIDE=en EXPECTED="$expected_packages" bash -c '
    source "$1"; cm_lang_init
    rows="$(cm_theme_package_table)"
    [ "$(printf "%s\n" "$rows" | wc -l)" -eq 10 ] || { echo "the list must hold exactly 10 packages"; exit 1; }
    [ "$(printf "%s\n" "$rows" | cut -d"|" -f1 | paste -sd" ")" = "$EXPECTED" ] || { echo "the list changed: $(printf "%s\n" "$rows" | cut -d"|" -f1 | paste -sd" ")"; exit 1; }
    [ "$(printf "%s\n" "$rows" | cut -d"|" -f1 | sort | uniq -d | wc -l)" -eq 0 ] || { echo "a package is listed twice"; exit 1; }
    while IFS="|" read -r pkg kind brand extra; do
        [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "not a package name: $pkg"; exit 1; }
        case "$kind" in gtk_cin|gtk|icons|cursors) ;; *) echo "unknown kind for $pkg: $kind"; exit 1 ;; esac
        [ -n "$brand" ] && [ -z "$extra" ] || { echo "a row needs exactly three fields: $pkg"; exit 1; }
        [ -n "$(cm_t "pkg_kind_$kind")" ] || { echo "no label for kind $kind"; exit 1; }
        cm_theme_package_known "$pkg" || { echo "a listed package is not known: $pkg"; exit 1; }
    done <<< "$rows"
    for bad in "" ARC-THEME "arc-theme " " arc-theme" "arc-theme;ls" "arc-theme --reinstall" "../arc-theme" "arc-*" "arc" "gnome-shell" "$(printf "arc-theme\nrm")"; do
        if cm_theme_package_known "$bad"; then printf "a name outside the list was accepted: %q\n" "$bad"; exit 1; fi
    done
' bash "$BODY" || fail 'the verified package table'
pass 'the verified list holds exactly the 10 packages checked against Ubuntu 24.04, each well formed, and nothing else is known'

# run_pkg <case> <lang> <how: tty|term> <apt mode> <terminal mode> <script arguments...>
# tty: the command runs on a pseudo-terminal, as in a terminal window of the user; term: no terminal at all (as from the GUI).
run_pkg() {
    local id="$1" lang="$2" how="$3" aptmode="$4" termmode="$5" rc=0
    shift 5
    rm -rf "${TMP:?}/$id"
    mkdir -p "$TMP/$id/home" "$TMP/$id/tmp" "$TMP/$id/tools"
    : > "$TMP/$id/apt.log"; : > "$TMP/$id/term.log"; : > "$TMP/$id/notify.log"
    # shellcheck disable=SC2086  # a list of names, split on purpose
    printf '%s\n' ${FAKE_INSTALLED:-} > "$TMP/$id/dpkg.db"
    local -a envs=(HOME="$TMP/$id/home" CM_HOME="$TMP/$id/state" TMPDIR="$TMP/$id/tmp" CM_LANG_OVERRIDE="$lang"
        PATH="$TMP/$id/tools:$FAKEBIN:$PATH" FAKE_APT_LOG="$TMP/$id/apt.log" FAKE_APT_MODE="$aptmode"
        FAKE_DPKG_DB="$TMP/$id/dpkg.db" FAKE_TERM_LOG="$TMP/$id/term.log" FAKE_TERM_MODE="$termmode"
        FAKE_TOOL_DIR="$TMP/$id/tools" FAKE_NOTIFY_LOG="$TMP/$id/notify.log" CM_INSTALL_MAX_WAIT="${WAIT:-600}")
    if [ "$how" = tty ]; then
        env "${envs[@]}" python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' \
            bash "$SCRIPT" "$@" > "$TMP/$id/out" 2> "$TMP/$id/err" < /dev/null || rc=$?
    else
        env "${envs[@]}" bash "$SCRIPT" "$@" > "$TMP/$id/out" 2> "$TMP/$id/err" < /dev/null || rc=$?
    fi
    return "$rc"
}
sudo_calls() { grep '^sudo' "$TMP/$1/apt.log" | paste -sd'|'; }
no_wait_folder() { [ -z "$(find "$TMP/$1/state" -maxdepth 1 -name '.install-wait.*' 2>/dev/null)" ]; }

# The list, in both languages, marking what is installed (and saying nothing about it when dpkg is not there).
FAKE_INSTALLED='arc-theme papirus-icon-theme' run_pkg list-en en term ok run theme list-packages || fail 'list-packages must work'
grep -q '^Verified theme packages' "$TMP/list-en/out" && grep -q 'Install one with: color-mint.sh theme install <package>' "$TMP/list-en/out" || fail 'the list needs its header (English)'
for pkg in $expected_packages; do
    [ "$(grep -c "^  $pkg " "$TMP/list-en/out")" -eq 1 ] || fail "$pkg must be listed once"
done
grep -Eq '^  arc-theme +GTK \+ Cinnamon +Arc  \(installed\)$' "$TMP/list-en/out" || fail 'an installed package must be marked'
grep -Eq '^  papirus-icon-theme +Icons +Papirus  \(installed\)$' "$TMP/list-en/out" || fail 'an installed icon package must be marked'
[ "$(grep -c '(installed)' "$TMP/list-en/out")" -eq 2 ] || fail 'only installed packages may be marked'
grep -Eq '^  breeze-cursor-theme +Cursor +Breeze$' "$TMP/list-en/out" || fail 'a package that is not installed is listed without a mark'
FAKE_INSTALLED='arc-theme' run_pkg list-es es term ok run theme list-packages || fail 'list-packages must work (Spanish)'
grep -q '^Paquetes de temas verificados' "$TMP/list-es/out" && grep -Eq '^  papirus-icon-theme +Iconos +Papirus$' "$TMP/list-es/out" \
    && grep -Eq '^  arc-theme +GTK \+ Cinnamon +Arc  \(instalado\)$' "$TMP/list-es/out" || fail 'the list must be in Spanish'
[ ! -s "$TMP/list-en/apt.log" ] && [ ! -s "$TMP/list-en/term.log" ] || fail 'listing must never run apt or open a terminal'
HOME="$TMP/home-list" CM_HOME="$TMP/state-list" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" bash -c '
    source "$1"; cm_lang_init
    command() { if [ "${1:-}" = -v ] && [ "${2:-}" = dpkg-query ]; then return 1; fi; builtin command "$@"; }
    out="$(cm_list_theme_packages)"   # not "| grep -q": the program runs with pipefail and grep -q ends the pipe early
    case "$out" in *"(installed)"*) echo "marks without dpkg"; exit 1 ;; esac
    case "$out" in *"  arc-theme "*) ;; *) echo "the list must still print"; exit 1 ;; esac
' bash "$BODY" || fail 'the list without dpkg-query'
pass 'theme list-packages prints the 10 packages with their kind, marks what is installed and runs nothing (English and Spanish)'

# Refusals: nothing reaches sudo for a name that is not on the list, nor on a system that is not apt based.
for arg in '' 'gnome-shell' 'arc-theme;touch pwned' 'ARC-THEME' '../arc-theme'; do
    rc=0; run_pkg refuse en term ok run theme install "$arg" || rc=$?
    [ "$rc" -eq 1 ] || fail "a bad package must stop the command (exit $rc): '$arg'"
    [ ! -s "$TMP/refuse/apt.log" ] && [ ! -s "$TMP/refuse/term.log" ] || fail "a bad package must never reach sudo or a terminal: '$arg'"
    if [ -n "$arg" ]; then grep -q 'is not in the verified list' "$TMP/refuse/err" || fail "a name outside the list must be refused as such: '$arg'"
    else grep -q 'enter the package' "$TMP/refuse/err" || fail 'no package must ask for one'; fi
done
rc=0; run_pkg refuse-es es term ok run theme install gnome-shell || rc=$?
[ "$rc" -eq 1 ] && grep -q 'no está en la lista verificada' "$TMP/refuse-es/err" || fail 'a name outside the list must be refused (Spanish)'
HOME="$TMP/home-pm" CM_HOME="$TMP/state-pm" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" FAKE_APT_LOG="$TMP/pm.log" FAKE_TERM_LOG="$TMP/pm.term" bash -c '
    source "$1"; cm_lang_init
    cm_pkg_manager() { printf dnf; }
    cm_install_theme_package arc-theme 2> "$2"; rc=$?
    [ "$rc" -eq 1 ] || { echo "a system that is not apt based must stop the command (exit $rc)"; exit 1; }
    grep -q "uses another manager" "$2" || { echo "it must say why"; exit 1; }
' bash "$BODY" "$TMP/pm.err" < /dev/null || fail 'a system that is not apt based'
[ ! -e "$TMP/pm.log" ] && [ ! -e "$TMP/pm.term" ] || fail 'a system that is not apt based must never reach sudo'
pass 'theme install refuses anything outside the list, and any system that is not apt based, before sudo or a terminal is touched'

# Already installed: said, not reinstalled.
FAKE_INSTALLED='arc-theme' run_pkg already en tty ok run theme install arc-theme || fail 'an installed package is not an error'
grep -q "The package 'arc-theme' is already installed" "$TMP/already/out" && [ ! -s "$TMP/already/apt.log" ] || fail 'an installed package must be reported and left alone'
FAKE_INSTALLED='arc-theme' run_pkg already-es es term ok run theme install arc-theme || fail 'an installed package is not an error (Spanish)'
grep -q "El paquete 'arc-theme' ya está instalado" "$TMP/already-es/out" || fail 'an installed package must be reported (Spanish)'

# In a terminal: sudo apt-get update, then install, asking before it does (no -y), and nothing else.
rc=0; run_pkg tty en tty ok run theme install arc-theme || rc=$?
[ "$rc" -eq 0 ] || fail "installing in a terminal (exit $rc): $(cat "$TMP/tty/out" "$TMP/tty/err")"
[ "$(sudo_calls tty)" = 'sudo apt-get update|sudo apt-get install arc-theme' ] || fail "the commands in a terminal were: $(sudo_calls tty)"
grep -q 'Installed: arc-theme\.' "$TMP/tty/out" || fail 'success must be said'
[ ! -s "$TMP/tty/term.log" ] || fail 'in a terminal no window may open'
grep -rq 'Theme package installed: arc-theme' "$TMP/tty/state" || fail 'the install must be logged'
no_wait_folder tty || fail 'a terminal install needs no wait folder'
rc=0; run_pkg tty-fail en tty fail run theme install arc-theme || rc=$?
[ "$rc" -eq 1 ] && grep -q "'arc-theme' was not installed" "$TMP/tty-fail/out" || fail 'a failed install in a terminal must say so and exit 1'
rc=0; run_pkg tty-fail3 en tty fail3 run theme install arc-theme || rc=$?
[ "$rc" -eq 1 ] && grep -q "'arc-theme' was not installed" "$TMP/tty-fail3/out" && ! grep -q 'Run manually' "$TMP/tty-fail3/out" \
    || fail 'whatever status apt fails with (even 3, the code for "no terminal") must be reported as a failed install'
pass 'in a terminal, theme install runs sudo apt-get update and install (without -y: apt asks) and reports success or failure'

# Without a terminal (from the GUI): the same command in a terminal window that reports back through a file.
rc=0; run_pkg term en term ok run theme install arc-theme || rc=$?
[ "$rc" -eq 0 ] || fail "installing in a window (exit $rc): $(cat "$TMP/term/err")"
[ "$(sudo_calls term)" = 'sudo apt-get update|sudo apt-get install arc-theme' ] || fail "the commands in a window were: $(sudo_calls term)"
[ "$(wc -l < "$TMP/term/term.log")" -eq 1 ] || fail 'one terminal window'
window="$(cat "$TMP/term/term.log")"
case "$window" in *'sudo apt-get update && sudo apt-get install "$@"; rc=$?'*' bash arc-theme') ;; *) fail "the window runs: $window";; esac
case "$window" in *' -y '*) fail 'theme install must let apt ask before installing';; esac
grep -q 'Installing arc-theme' "$TMP/term/notify.log" || fail 'the user must be told that it is installing'
grep -q 'Installed: arc-theme\.' "$TMP/term/out" || fail 'success must be said'
no_wait_folder term || fail 'the wait folder must be removed'
rc=0; run_pkg term-fail en term fail run theme install arc-theme || rc=$?
[ "$rc" -eq 1 ] && grep -q "'arc-theme' was not installed" "$TMP/term-fail/err" || fail 'a failed install in a window must say so and exit 1'
no_wait_folder term-fail || fail 'the wait folder must be removed after a failure'
rc=0; WAIT=2 run_pkg term-wait en term ok never theme install arc-theme || rc=$?
[ "$rc" -eq 1 ] && grep -q 'taking longer than expected' "$TMP/term-wait/err" || fail 'giving up waiting must say so and exit 1'
no_wait_folder term-wait || fail 'the wait folder must be removed when giving up'
rc=0; run_pkg term-es es term ok run theme install arc-theme || rc=$?
[ "$rc" -eq 0 ] && grep -q 'Instalado: arc-theme\.' "$TMP/term-es/out" && grep -q 'Instalando arc-theme' "$TMP/term-es/notify.log" || fail 'the install must speak Spanish'
for case_id in no-terminal no-folder; do
    rm -rf "${TMP:?}/$case_id"; mkdir -p "$TMP/$case_id/home" "$TMP/$case_id/tmp"; : > "$TMP/$case_id/apt.log"; : > "$TMP/$case_id/term.log"; : > "$TMP/$case_id/dpkg.db"
    rc=0
    env HOME="$TMP/$case_id/home" CM_HOME="$TMP/$case_id/state" TMPDIR="$TMP/$case_id/tmp" CM_LANG_OVERRIDE=en PATH="$FAKEBIN:$PATH" \
        FAKE_APT_LOG="$TMP/$case_id/apt.log" FAKE_TERM_LOG="$TMP/$case_id/term.log" FAKE_DPKG_DB="$TMP/$case_id/dpkg.db" CASE="$case_id" \
        bash -c '
            source "$1"; cm_lang_init
            if [ "$CASE" = no-terminal ]; then
                command() { if [ "${1:-}" = -v ] && [ "${2:-}" = x-terminal-emulator ]; then return 1; fi; builtin command "$@"; }
            else
                CM_HOME="$2/missing/deeper"
            fi
            cm_install_theme_package arc-theme
        ' bash "$BODY" "$TMP/$case_id" > "$TMP/$case_id/out" 2> "$TMP/$case_id/err" < /dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "$case_id: exit $rc instead of 1"
    [ ! -s "$TMP/$case_id/apt.log" ] || fail "$case_id: nothing may run when there is nowhere to run it"
done
grep -q 'Run manually: sudo apt install arc-theme' "$TMP/no-terminal/err" || fail 'no terminal: the exact command must be given'
grep -q 'could not create a temporary directory' "$TMP/no-folder/err" || fail 'no work folder must be said'
[ ! -s "$TMP/no-terminal/term.log" ] && [ ! -s "$TMP/no-folder/term.log" ] || fail 'no window may open in those cases'
pass 'without a terminal the same command runs in a window that reports back; failure, timeout, no window and no work folder are each said and clean up'

# The GUI's missing dependencies use the very same flow (it had no test of its own): question, then install with -y.
# run_dep <case> <how: tty|term> <apt mode> <terminal mode> <yad answer> [shell code before the call]
run_dep() {
    local id="$1" how="$2" aptmode="$3" termmode="$4" answer="$5" prelude="${6:-:}" rc=0
    rm -rf "${TMP:?}/$id"
    mkdir -p "$TMP/$id/home" "$TMP/$id/tmp" "$TMP/$id/tools"
    : > "$TMP/$id/apt.log"; : > "$TMP/$id/term.log"; : > "$TMP/$id/notify.log"; : > "$TMP/$id/dpkg.db"
    local -a envs=(HOME="$TMP/$id/home" CM_HOME="$TMP/$id/state" TMPDIR="$TMP/$id/tmp" CM_LANG_OVERRIDE=en
        PATH="$TMP/$id/tools:$FAKEBIN:$PATH" FAKE_APT_LOG="$TMP/$id/apt.log" FAKE_APT_MODE="$aptmode"
        FAKE_DPKG_DB="$TMP/$id/dpkg.db" FAKE_TERM_LOG="$TMP/$id/term.log" FAKE_TERM_MODE="$termmode"
        FAKE_TOOL_DIR="$TMP/$id/tools" FAKE_NOTIFY_LOG="$TMP/$id/notify.log" FAKE_YAD_ANSWER="$answer"
        CM_INSTALL_MAX_WAIT="${WAIT:-600}" PRELUDE="$prelude" BODY_FILE="$BODY" CASE_DIR="$TMP/$id")
    local code='
        source "$BODY_FILE"; cm_lang_init
        cm_pkg_manager() { printf apt; }
        cm_pkg_name() { printf "fake-pkg-%s" "$2"; }
        eval "$PRELUDE"
        cm_check_dependencies cm-test-missing-tool
        echo "returned $?"'
    if [ "$how" = tty ]; then
        printf 'y\n' | env "${envs[@]}" python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' \
            bash -c "$code" bash > "$TMP/$id/out" 2> "$TMP/$id/err" || rc=$?
    else
        env "${envs[@]}" bash -c "$code" bash > "$TMP/$id/out" 2> "$TMP/$id/err" < /dev/null || rc=$?
    fi
    return "$rc"
}
rc=0; run_dep dep-ok term ok run 0 || rc=$?
[ "$rc" -eq 0 ] && grep -q 'returned 0' "$TMP/dep-ok/out" || fail "dependencies: the install must succeed and continue (exit $rc): $(cat "$TMP/dep-ok/err")"
[ "$(sudo_calls dep-ok)" = 'sudo apt-get update|sudo apt-get install -y fake-pkg-cm-test-missing-tool' ] || fail "dependencies: the commands were: $(sudo_calls dep-ok)"
grep -q 'Installing dependencies (fake-pkg-cm-test-missing-tool)' "$TMP/dep-ok/notify.log" || fail 'dependencies: the user must be told that it is installing'
no_wait_folder dep-ok || fail 'dependencies: the wait folder must be removed'
rc=0; run_dep dep-tty tty ok run 0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(sudo_calls dep-tty)" = 'sudo apt-get update|sudo apt-get install -y fake-pkg-cm-test-missing-tool' ] && [ ! -s "$TMP/dep-tty/term.log" ] \
    || fail "dependencies in a terminal: the question is answered there and apt runs there (exit $rc, $(sudo_calls dep-tty))"
rc=0; run_dep dep-fail term fail run 0 || rc=$?
[ "$rc" -eq 1 ] && ! grep -q 'returned' "$TMP/dep-fail/out" && grep -q 'cm-test-missing-tool' "$TMP/dep-fail/notify.log" || fail 'dependencies: a failed install must stop the program and name what is missing'
rc=0; run_dep dep-no term ok run 1 || rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$TMP/dep-no/apt.log" ] && [ ! -s "$TMP/dep-no/term.log" ] || fail 'dependencies: answering no must install nothing and stop'
rc=0; WAIT=2 run_dep dep-wait term ok never 0 || rc=$?
[ "$rc" -eq 1 ] && grep -q 'taking longer than expected' "$TMP/dep-wait/notify.log" && no_wait_folder dep-wait || fail 'dependencies: giving up waiting must be said and clean up'
rc=0; run_dep dep-term term ok run 0 'command() { if [ "${1:-}" = -v ] && [ "${2:-}" = x-terminal-emulator ]; then return 1; fi; builtin command "$@"; }' || rc=$?
[ "$rc" -eq 1 ] && grep -q 'Run manually: sudo apt install fake-pkg-cm-test-missing-tool' "$TMP/dep-term/notify.log" && [ ! -s "$TMP/dep-term/apt.log" ] \
    || fail 'dependencies: without a terminal the exact command must be given'
rc=0; run_dep dep-folder term ok run 0 'CM_HOME="$CASE_DIR/missing/deeper"' || rc=$?
[ "$rc" -eq 1 ] && grep -q 'could not create a temporary directory' "$TMP/dep-folder/notify.log" || fail 'dependencies: no work folder must be said'
pass 'the dependencies flow of the GUI uses the same function: question, install with -y, and each way of failing is said'

# ---------------------------------------------------------------------------------------------------------------------
# The GUI's "Get more themes" button: the form, the wait window and the notice around the CLI's functions
# ---------------------------------------------------------------------------------------------------------------------
# yad is a double that answers the form as a user would and logs every dialog it is asked to show. The wait window is a
# double too: it stays open until it is killed, and curl asks it whether it is open before it answers, so "the window
# shows while the download runs" is observed, not assumed. Real yad draws the form and the window in test_gui_render.sh.
MORE_BIN="$TMP/more-bin"
mkdir -p "$MORE_BIN"
cat > "$MORE_BIN/yad" <<'FAKE'
#!/usr/bin/env bash
# One write per line: the wait window runs in the background, and two processes appending piece by piece tear each other's lines.
call=CALL; for arg in "$@"; do call+=$'\t'"${arg//$'\n'/\\n}"; done
printf '%s\n' "$call" >> "${FAKE_YAD_LOG:?}"
for arg in "$@"; do
    case "$arg" in
        --form) printf '%s\n' "${FAKE_FORM_OUT-}"; exit "${FAKE_FORM_RC:-0}" ;;
        --progress)
            # The handler comes first and logs the stop only if the start was logged: a kill landing anywhere in the start-up
            # (a failure that follows the window at once is a normal path) must leave one start and one stop, or none.
            # The window takes a moment to go: only a program that waits for it finds the stop logged when it goes on (MW08).
            trap 'grep -qx wait-start "$FAKE_EVENTS" && { sleep 0.3; echo wait-stop >> "$FAKE_EVENTS"; }; exit 0' TERM
            echo wait-start >> "${FAKE_EVENTS:?}"
            end=$((SECONDS + 10))   # a program that never closes the window fails the case; it must not hang the suite
            while [ "$SECONDS" -lt "$end" ]; do sleep 0.05; done
            echo wait-timeout >> "$FAKE_EVENTS"; exit 0 ;;
    esac
done
exit 0
FAKE
cat > "$MORE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
for _ in $(seq 1 60); do grep -qx wait-start "${FAKE_EVENTS:?}" 2>/dev/null && break; sleep 0.05; done
if grep -qx wait-start "$FAKE_EVENTS" && ! grep -qx wait-stop "$FAKE_EVENTS"; then echo curl-wait-open >> "$FAKE_EVENTS"
else echo curl-wait-closed >> "$FAKE_EVENTS"; fi
exec "${FAKE_CURL_DOUBLE:?}" "$@"
FAKE
chmod 755 "$MORE_BIN/yad" "$MORE_BIN/curl"

# run_more <case> <manager> <form answer> <form exit status> <curl mode> <apt mode> [shell code before the call]
# The button's own function, in a case folder of its own. MORE_LANG picks the language (en), FAKE_INSTALLED the packages
# that are already installed, MORE_ZIP what curl serves. cm_tab_redraw only records that it was called: what it does to
# the window is measured with real yad in test_gui_render.sh.
run_more() {
    local id="$1" pm="$2" answer="$3" frc="$4" cmode="$5" amode="$6" prelude="${7:-:}" rc=0
    rm -rf "${TMP:?}/$id"
    mkdir -p "$TMP/$id/home" "$TMP/$id/tmp" "$TMP/$id/tools"
    : > "$TMP/$id/apt.log"; : > "$TMP/$id/term.log"; : > "$TMP/$id/notify.log"; : > "$TMP/$id/curl.log"
    : > "$TMP/$id/yad.log"; : > "$TMP/$id/events.log"; : > "$TMP/$id/redraw.log"
    # shellcheck disable=SC2086  # a list of names, split on purpose
    printf '%s\n' ${FAKE_INSTALLED:-} > "$TMP/$id/dpkg.db"
    local -a envs=(HOME="$TMP/$id/home" CM_HOME="$TMP/$id/state" TMPDIR="$TMP/$id/tmp" CM_LANG_OVERRIDE="${MORE_LANG:-en}"
        PATH="$TMP/$id/tools:$MORE_BIN:$FAKEBIN:$PATH" FAKE_APT_LOG="$TMP/$id/apt.log" FAKE_APT_MODE="$amode"
        FAKE_DPKG_DB="$TMP/$id/dpkg.db" FAKE_TERM_LOG="$TMP/$id/term.log" FAKE_TERM_MODE=run FAKE_TOOL_DIR="$TMP/$id/tools"
        FAKE_NOTIFY_LOG="$TMP/$id/notify.log" FAKE_CURL_MODE="$cmode" FAKE_CURL_ZIP="${MORE_ZIP:-$TMP/good.zip}"
        FAKE_CURL_LOG="$TMP/$id/curl.log" FAKE_CURL_DOUBLE="$FAKEBIN/curl" FAKE_YAD_LOG="$TMP/$id/yad.log"
        FAKE_EVENTS="$TMP/$id/events.log" FAKE_FORM_OUT="$answer" FAKE_FORM_RC="$frc" CM_INSTALL_MAX_WAIT=600
        PRELUDE="$prelude" PM="$pm" BODY_FILE="$BODY" CASE_DIR="$TMP/$id")
    env "${envs[@]}" bash -c '
        source "$BODY_FILE"; cm_lang_init
        cm_pkg_manager() { printf "%s" "$PM"; }
        cm_tab_redraw() { echo redraw >> "$CASE_DIR/redraw.log"; }
        eval "$PRELUDE"
        rc=0; cm_ui_apply_themes_more || rc=$?
        echo "returned $rc"' bash > "$TMP/$id/out" 2> "$TMP/$id/err" < /dev/null || rc=$?
    return "$rc"
}
yad_count() { awk -F'\t' -v kind="$2" '$1 == "CALL" && $2 == kind { n++ } END { print n + 0 }' "$TMP/$1/yad.log"; }
dialogs() { sed 's/\\n/ /g' "$TMP/$1/yad.log" | tr -s ' '; }      # every dialog of the case, line breaks as spaces
form_arg() { awk -F'\t' -v key="$2" '$1 == "CALL" && $2 == "--form" { for (i = 1; i <= NF; i++) if ($i == key) { print $(i + 1); exit } }' "$TMP/$1/yad.log"; }
progress_args() { awk -F'\t' '$1 == "CALL" && $2 == "--progress" { for (i = 2; i <= NF; i++) print $i; exit }' "$TMP/$1/yad.log"; }   # one per line
call_args() { awk -F'\t' -v kind="$2" '$1 == "CALL" && $2 == kind { for (i = 2; i <= NF; i++) print $i; exit }' "$TMP/$1/yad.log"; }   # <case> <kind>: its arguments, one per line
wrapped_max() {   # <case>: the longest line, markup left out, of the text of the warning
    awk -F'\t' '$1 == "CALL" && $2 == "--warning" { for (i = 2; i <= NF; i++) if ($i ~ /^--text=/) {
        n = split($i, part, /\\n/); for (j = 1; j <= n; j++) { l = part[j]; gsub(/<[^>]*>/, "", l); if (length(l) > max) max = length(l) } } }
        END { print max + 0 }' "$TMP/$1/yad.log"
}
events() { paste -sd' ' "$TMP/$1/events.log"; }
redraws() { wc -l < "$TMP/$1/redraw.log" | tr -d ' '; }
more_clean() { [ -z "$(left_behind "$1")" ] && [ -z "$(find "$TMP/$1/state" -name '.more-err.*' 2>/dev/null | head -n 1)" ]; }
state_line() { grep -qx -- "$2" "$TMP/$1/state/state.conf" 2>/dev/null; }
installed_theme() { find "$TMP/$1/home/.themes" "$TMP/$1/home/.icons" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | paste -sd' '; }
quiet_case() {   # <case>: nothing was done after the form: no window, no download, no sudo, no notice, no redraw, no state
    [ "$(yad_count "$1" --progress)" -eq 0 ] && [ ! -s "$TMP/$1/curl.log" ] && [ ! -s "$TMP/$1/apt.log" ] && [ ! -s "$TMP/$1/term.log" ] \
        && [ ! -s "$TMP/$1/notify.log" ] && [ ! -s "$TMP/$1/events.log" ] && [ "$(redraws "$1")" -eq 0 ] \
        && ! grep -q 'LAST_IMPORTED_THEME' "$TMP/$1/state/state.conf" 2>/dev/null && [ -z "$(installed_theme "$1")" ] && more_clean "$1"
}

[ "$(PATH="$MORE_BIN:$FAKEBIN:$PATH" command -v yad)" = "$MORE_BIN/yad" ] || fail 'the yad double must come first in PATH: a test must never open a window'

# Flow 1, Spices well: the name is typed, the wait window is open while curl runs and closed after, the theme is
# installed and remembered, the lists are redrawn once and one confirmation says where it is.
rc=0; run_more more-spices apt 'None|Fixture-Spice|' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-spices/out" || fail "Get more themes with a Spices name must succeed (exit $rc): $(cat "$TMP/more-spices/err")"
[ "$(yad_count more-spices --form)" -eq 1 ] && [ "$(yad_count more-spices --info)" -eq 1 ] && [ "$(yad_count more-spices --progress)" -eq 1 ] \
    && [ "$(yad_count more-spices --error)" -eq 0 ] && [ "$(yad_count more-spices --warning)" -eq 0 ] \
    || fail "one form, one wait window and one confirmation, no error: $(cut -f1,2 "$TMP/more-spices/yad.log" | paste -sd'|')"
[ "$(events more-spices)" = 'wait-start curl-wait-open wait-stop' ] || fail "the wait window must be open while curl runs and closed after it: $(events more-spices)"
[ "$(wc -l < "$TMP/more-spices/curl.log")" -eq 1 ] && grep -q 'Fixture-Spice' "$TMP/more-spices/curl.log" || fail 'one download, of the name that was typed'
[ -f "$TMP/more-spices/home/.themes/Fixture-Spice/cinnamon/cinnamon.css" ] || fail 'the theme must be installed'
state_line more-spices 'LAST_IMPORTED_THEME="Fixture-Spice"' || fail 'the theme must be remembered so that the redrawn lists preselect it'
[ "$(redraws more-spices)" -eq 1 ] || fail "the lists must be redrawn once ($(redraws more-spices))"
dialogs more-spices | grep -qF 'Theme downloaded' && dialogs more-spices | grep -qF "Path: $TMP/more-spices/home/.themes/Fixture-Spice" \
    && dialogs more-spices | grep -qF 'It is now preselected in its dropdown' || fail 'the confirmation must say what happened and where the theme is'
grep -qF 'Theme downloaded' "$TMP/more-spices/notify.log" || fail 'the desktop notification must say it too'
[ ! -s "$TMP/more-spices/apt.log" ] || fail 'a Spices name must never reach sudo'
more_clean more-spices || fail "nothing may be left behind: $(left_behind more-spices) $(find "$TMP/more-spices/state" -name '.more-err.*' 2>/dev/null)"
# The wait window has its own timeout (CM_FETCH_TIMEOUT 120 + 30), so that it closes by itself if the program dies first.
awk -F'\t' '$1 == "CALL" && $2 == "--progress" { for (i = 1; i <= NF; i++) if ($i == "--timeout=150") found = 1 } END { exit !found }' "$TMP/more-spices/yad.log" \
    || fail 'the wait window needs its own timeout, 30 s past the download limit'
# A bar that does not pulse sits at 0 % for the whole download and looks stuck; with no buttons nothing can close it by hand.
progress_args more-spices | grep -qxF -- '--pulsate' && progress_args more-spices | grep -qxF -- '--no-buttons' \
    && progress_args more-spices | grep -qxF -- '--text=Downloading Fixture-Spice from Cinnamon Spices...\nThis window closes by itself.' \
    || fail "the wait window must pulse, have no buttons and name the theme: $(progress_args more-spices | paste -sd'|')"
# What the form offers: the title, the ten packages in the table's order after "None", an entry for the Spices name.
[ "$(form_arg more-spices '--field=Theme pack:CB')" = 'None!Arc — GTK + Cinnamon!Materia — GTK + Cinnamon!Numix — GTK!Papirus — Icons!Numix Circle — Icons!Breeze — Icons!elementary — Icons!Bibata — Cursor!DMZ — Cursor!Breeze — Cursor' ] \
    || fail "the pack list of the form: $(form_arg more-spices '--field=Theme pack:CB')"
grep -qF -- '--title=Get more themes' "$TMP/more-spices/yad.log" || fail 'the form needs its title'
grep -qF -- '--field=Cinnamon Spices name' "$TMP/more-spices/yad.log" && grep -qF -- '--button=Cancel:1' "$TMP/more-spices/yad.log" \
    && grep -qF -- '--button=Get:0' "$TMP/more-spices/yad.log" || fail 'the form needs the Spices entry and its two buttons'
dialogs more-spices | grep -qF 'Install a theme pack from your system' || fail 'the form must explain both ways in'
# Spaces around the name are not part of it.
rc=0; run_more more-spaces apt 'None|   Fixture-Spice  |' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && [ -d "$TMP/more-spaces/home/.themes/Fixture-Spice" ] && grep -q 'Fixture-Spice' "$TMP/more-spaces/curl.log" \
    || fail 'spaces around the typed name must be ignored'
# In Spanish the whole flow speaks Spanish.
rc=0; MORE_LANG=es run_more more-spices-es apt 'Ninguno|Fixture-Spice|' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && [ -d "$TMP/more-spices-es/home/.themes/Fixture-Spice" ] && grep -qF -- '--title=Conseguir más temas' "$TMP/more-spices-es/yad.log" \
    && grep -qF -- '--field=Paquete de temas:CB' "$TMP/more-spices-es/yad.log" && dialogs more-spices-es | grep -qF 'Tema descargado' \
    && dialogs more-spices-es | grep -qF "Ruta: $TMP/more-spices-es/home/.themes/Fixture-Spice" || fail 'the flow must speak Spanish (form, field, confirmation)'
progress_args more-spices-es | grep -qxF -- '--text=Descargando Fixture-Spice de Cinnamon Spices...\nEsta ventana se cierra sola.' \
    || fail 'the wait window must speak Spanish and name the theme'
icon="$(call_args more-spices --form | grep -m1 -- '^--window-icon=' || true)"
[ -n "${icon#--window-icon=}" ] || fail 'the form needs the icon of the program'
call_args more-spices --form | grep -qxF -- '--borders=12' && call_args more-spices --form | grep -qxF -- '--center' || fail 'the form is centred and has borders'
[ "$(progress_args more-spices | grep -v -- '^--text=' | paste -sd'|')" = "--progress|--pulsate|--progress-text= |--no-buttons|--borders=12|--center|--width=380|--title=Color Mint|$icon|--timeout=150" ] \
    || fail "the arguments of the wait window: $(progress_args more-spices | grep -v -- '^--text=' | paste -sd'|')"
pass 'Get more themes, Spices well: the window shows while curl runs and closes after, the frame of both windows is fixed, the theme is installed, remembered and redrawn once, in both languages'

# Flow 2, empty form: asked for nothing, it says so and does nothing else (no window, no download, no sudo, no redraw).
for answer in 'None||' 'None|   |'; do
    rc=0; run_more more-empty apt "$answer" 0 ok ok || rc=$?
    [ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-empty/out" || fail "an empty form must end with status 1 ('$answer')"
    [ "$(yad_count more-empty --error)" -eq 1 ] && dialogs more-empty | grep -qF 'Choose a theme pack or type a Cinnamon Spices name first.' \
        || fail "an empty form must say what to do ('$answer')"
    [ "$(yad_count more-empty --info)" -eq 0 ] && [ "$(yad_count more-empty --warning)" -eq 0 ] || fail "an empty form must show no confirmation ('$answer')"
    quiet_case more-empty || fail "an empty form must do nothing ('$answer')"
done
rc=0; run_more more-empty-web dnf '   |' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-empty-web/out" && [ "$(yad_count more-empty-web --error)" -eq 1 ] && quiet_case more-empty-web \
    || fail 'an empty form on a system without packages must say so and do nothing'
# Cancel and closing the window with Escape (yad answers 1 and 252): the button ends quietly, with no dialog at all.
for status in 1 252; do
    rc=0; run_more more-cancel apt '' "$status" ok ok || rc=$?
    [ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-cancel/out" || fail "closing the form (status $status) must not be an error"
    [ "$(yad_count more-cancel --form)" -eq 1 ] && [ "$(wc -l < "$TMP/more-cancel/yad.log")" -eq 1 ] || fail "closing the form (status $status) must show nothing else"
    quiet_case more-cancel || fail "closing the form (status $status) must do nothing"
done
pass 'Get more themes, empty or closed form: an empty one says what to do, a closed one says nothing, and neither opens a window, downloads, reaches sudo or redraws'

# Flow 3, pack installed and Spices failed: the pack stays installed, so the lists are redrawn and the warning
# says so next to the failure; the wait window closes on failure too.
rc=0; run_more more-both-bad apt 'Arc — GTK + Cinnamon|Missing-Theme|' 0 http404 ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-both-bad/out" || fail 'a failed download must end the button with status 1'
[ "$(sudo_calls more-both-bad)" = 'sudo apt-get update|sudo apt-get install arc-theme' ] || fail "the pack must be installed first: $(sudo_calls more-both-bad)"
grep -qx 'arc-theme' "$TMP/more-both-bad/dpkg.db" || fail 'the pack must be installed'
[ "$(yad_count more-both-bad --warning)" -eq 1 ] && [ "$(yad_count more-both-bad --info)" -eq 0 ] && [ "$(yad_count more-both-bad --error)" -eq 0 ] \
    || fail "one warning and no success dialog: $(cut -f1,2 "$TMP/more-both-bad/yad.log" | paste -sd'|')"
dialogs more-both-bad | grep -qF 'The theme could not be obtained' && dialogs more-both-bad | grep -qF "could not download 'Missing-Theme'" \
    && dialogs more-both-bad | grep -qF 'curl: (22)' || fail 'the warning must give the reason of the failure'
! dialogs more-both-bad | grep -qF 'ERROR:' || fail 'the warning must not repeat the ERROR: prefix of the message'
dialogs more-both-bad | grep -qF 'Package: arc-theme' && dialogs more-both-bad | grep -qF 'It now shows in the dropdowns' \
    || fail 'the warning must say that the pack stayed installed'
[ "$(redraws more-both-bad)" -eq 1 ] || fail "the lists must be redrawn: the pack is in them now ($(redraws more-both-bad))"
! grep -q 'LAST_IMPORTED_THEME' "$TMP/more-both-bad/state/state.conf" 2>/dev/null || fail 'a failed download must not be remembered'
[ "$(events more-both-bad)" = 'wait-start curl-wait-open wait-stop' ] || fail "the wait window must close on failure too: $(events more-both-bad)"
[ -z "$(installed_theme more-both-bad)" ] && more_clean more-both-bad || fail 'a failed download must install nothing and leave nothing'
# The same failure with no pack: nothing changed, so nothing is redrawn.
rc=0; run_more more-spices-bad apt 'None|Missing-Theme|' 0 http404 ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-spices-bad/out" && [ "$(yad_count more-spices-bad --warning)" -eq 1 ] \
    && dialogs more-spices-bad | grep -qF "could not download 'Missing-Theme'" || fail 'a failed download alone must warn with its reason'
[ "$(wrapped_max more-spices-bad)" -le 70 ] || fail "a long message must be wrapped, not shown as one line ($(wrapped_max more-spices-bad) characters)"
# The heading already says that it failed: neither the title nor the heading carries the "with warnings" tail (seen in the real render).
call_args more-spices-bad --warning | grep -qxF -- '--title=⚠ Color Mint' && ! dialogs more-spices-bad | grep -qF 'with warnings' \
    || fail 'a failed download is not "with warnings": the title is the program name and the heading says what failed'
[ "$(redraws more-spices-bad)" -eq 0 ] && [ ! -s "$TMP/more-spices-bad/apt.log" ] && [ "$(events more-spices-bad)" = 'wait-start curl-wait-open wait-stop' ] \
    && more_clean more-spices-bad || fail 'a failed download alone redraws nothing, reaches no sudo and leaves nothing'
# A failure that says nothing of its own is still reported, with the theme's name; so is an answer of "done" with no folder.
rc=0; run_more more-silent apt 'None|Missing-Theme|' 0 ok ok 'cm_fetch_theme() { return 1; }' || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-silent/out" && [ "$(yad_count more-silent --warning)" -eq 1 ] \
    && dialogs more-silent | grep -qF "could not download 'Missing-Theme'" || fail 'a failure with no message must be reported with the theme name'
rc=0; run_more more-nopath apt 'None|Missing-Theme|' 0 ok ok 'cm_fetch_theme() { return 0; }' || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-nopath/out" && [ "$(yad_count more-nopath --warning)" -eq 1 ] && [ "$(yad_count more-nopath --info)" -eq 0 ] \
    && dialogs more-nopath | grep -qF "could not download 'Missing-Theme'" && [ "$(redraws more-nopath)" -eq 0 ] \
    && ! grep -q 'LAST_IMPORTED_THEME' "$TMP/more-nopath/state/state.conf" 2>/dev/null || fail 'an answer of done with no folder must count as a failure: nothing remembered, nothing redrawn'
pass 'Get more themes, pack well and Spices wrong: the pack stays installed and listed, the warning says why, the wait window closes, nothing is left'

# The same case when the file that collects the download's messages cannot be made: nothing is downloaded and no
# window opens, but a pack installed a moment before is listed and named in the warning, as with any other failure.
no_err_file='mktemp() { case "$*" in *.more-err.*) return 1 ;; esac; command mktemp "$@"; }'
rc=0; run_more more-notemp apt 'None|Fixture-Spice|' 0 ok ok "$no_err_file" || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-notemp/out" && [ "$(yad_count more-notemp --warning)" -eq 1 ] \
    && [ "$(yad_count more-notemp --info)" -eq 0 ] && dialogs more-notemp | grep -qF 'The theme could not be obtained' \
    && dialogs more-notemp | grep -qF 'could not create a temporary directory' \
    || fail "a message file that cannot be made must be reported with its reason: $(dialogs more-notemp | paste -sd'|')"
! dialogs more-notemp | grep -qF 'ERROR:' || fail 'the warning must not repeat the ERROR: prefix of the message'
[ "$(yad_count more-notemp --progress)" -eq 0 ] && [ ! -s "$TMP/more-notemp/curl.log" ] && [ ! -s "$TMP/more-notemp/apt.log" ] \
    && [ "$(redraws more-notemp)" -eq 0 ] && ! grep -q 'LAST_IMPORTED_THEME' "$TMP/more-notemp/state/state.conf" 2>/dev/null \
    && [ -z "$(installed_theme more-notemp)" ] && more_clean more-notemp \
    || fail 'with no message file there is no window, no download, no redraw and nothing left'
rc=0; run_more more-notemp-pack apt 'Arc — GTK + Cinnamon|Fixture-Spice|' 0 ok ok "$no_err_file" || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-notemp-pack/out" \
    && [ "$(sudo_calls more-notemp-pack)" = 'sudo apt-get update|sudo apt-get install arc-theme' ] && grep -qx 'arc-theme' "$TMP/more-notemp-pack/dpkg.db" \
    && [ "$(yad_count more-notemp-pack --warning)" -eq 1 ] && [ "$(yad_count more-notemp-pack --info)" -eq 0 ] \
    && dialogs more-notemp-pack | grep -qF 'could not create a temporary directory' \
    || fail "the pack must be installed and the missing message file reported: $(dialogs more-notemp-pack | paste -sd'|')"
dialogs more-notemp-pack | grep -qF 'Package: arc-theme' && dialogs more-notemp-pack | grep -qF 'It now shows in the dropdowns' \
    || fail 'the warning must say that the pack stayed installed'
[ "$(redraws more-notemp-pack)" -eq 1 ] || fail "the lists must be redrawn: the pack is in them now ($(redraws more-notemp-pack))"
[ "$(yad_count more-notemp-pack --progress)" -eq 0 ] && [ ! -s "$TMP/more-notemp-pack/curl.log" ] \
    && ! grep -q 'LAST_IMPORTED_THEME' "$TMP/more-notemp-pack/state/state.conf" 2>/dev/null && more_clean more-notemp-pack \
    || fail 'with no message file nothing is downloaded, remembered or left, even after a pack'
pass 'Get more themes, no file for the download messages: reported with its reason, no window or download, and a pack installed before stays listed and named'
rc=0; run_more more-errfile apt 'None|Fixture-Spice|' 0 ok ok 'mktemp() { printf "%s\n" "$*" >> "$CASE_DIR/mktemp.log"; command mktemp "$@"; }' || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-errfile/out" && [ "$(grep -c '\.more-err\.' "$TMP/more-errfile/mktemp.log")" -eq 1 ] \
    && grep -qxF "$TMP/more-errfile/state/.more-err.XXXXXX" "$TMP/more-errfile/mktemp.log" \
    || fail "the messages file must be made as .more-err.XXXXXX in the state folder: $(grep '\.more-err\.' "$TMP/more-errfile/mktemp.log" | paste -sd'|')"
rc=0; run_more more-pathfail apt 'None|Ghost-Theme|' 0 ok ok 'cm_fetch_theme() { printf "%s\n" "$HOME/.themes/Ghost-Theme"; return 1; }' || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-pathfail/out" && [ "$(yad_count more-pathfail --warning)" -eq 1 ] && [ "$(yad_count more-pathfail --info)" -eq 0 ] \
    && dialogs more-pathfail | grep -qF "could not download 'Ghost-Theme'" && [ "$(redraws more-pathfail)" -eq 0 ] \
    && ! grep -q 'LAST_IMPORTED_THEME' "$TMP/more-pathfail/state/state.conf" 2>/dev/null \
    || fail 'a download that prints a folder and fails must count as a failure: nothing remembered, nothing redrawn'
rc=0; run_more more-prefix apt 'None|Ghost-Theme|' 0 ok ok 'cm_fetch_theme() { echo "WARNING: the server said no" >&2; return 1; }' || rc=$?
[ "$rc" -eq 0 ] && dialogs more-prefix | grep -qF '⚠ the server said no' || fail "the WARNING: prefix must not be repeated: $(dialogs more-prefix | paste -sd'|')"
rc=0; MORE_LANG=es run_more more-prefix-es apt 'Ninguno|Ghost-Theme|' 0 ok ok 'cm_fetch_theme() { echo "ADVERTENCIA: el servidor dijo que no" >&2; return 1; }' || rc=$?
[ "$rc" -eq 0 ] && dialogs more-prefix-es | grep -qF '⚠ el servidor dijo que no' || fail "the ADVERTENCIA: prefix must not be repeated: $(dialogs more-prefix-es | paste -sd'|')"
long=""; for n in 01 02 03 04 05 06 07 08 09 10 11 12; do long+="segment-$n "; done; long="${long% }"
rc=0; run_more more-wrap apt 'None|Ghost-Theme|' 0 ok ok "cm_fetch_theme() { echo 'ERROR: $long' >&2; return 1; }" || rc=$?
[ "$rc" -eq 0 ] && dialogs more-wrap | grep -qF "⚠ $long" && [ "$(wrapped_max more-wrap)" -le 70 ] \
    || fail "a long reason must be wrapped between words, none split (longest line $(wrapped_max more-wrap)): $(dialogs more-wrap | paste -sd'|')"
pass 'Get more themes, the notice: the messages file in the state folder, a failing download that prints a folder, the three prefixes and the wrapping'

# Packs: each entry of the list installs the package it names (the label is mapped back by position), and the others stay out.
more_pkgs=(arc-theme materia-gtk-theme numix-gtk-theme papirus-icon-theme numix-icon-theme-circle breeze-icon-theme elementary-icon-theme bibata-cursor-theme dmz-cursor-theme breeze-cursor-theme)
more_labels=('Arc — GTK + Cinnamon' 'Materia — GTK + Cinnamon' 'Numix — GTK' 'Papirus — Icons' 'Numix Circle — Icons' 'Breeze — Icons' 'elementary — Icons' 'Bibata — Cursor' 'DMZ — Cursor' 'Breeze — Cursor')
for i in "${!more_pkgs[@]}"; do
    rc=0; run_more more-pack apt "${more_labels[$i]}|" 0 ok ok || rc=$?
    [ "$rc" -eq 0 ] && [ "$(sudo_calls more-pack)" = "sudo apt-get update|sudo apt-get install ${more_pkgs[$i]}" ] \
        || fail "'${more_labels[$i]}' must install ${more_pkgs[$i]} and nothing else: $(sudo_calls more-pack)"
    [ "$(sort -u "$TMP/more-pack/dpkg.db" | grep -c .)" -eq 1 ] && grep -qx "${more_pkgs[$i]}" "$TMP/more-pack/dpkg.db" || fail "only ${more_pkgs[$i]} may be installed"
done
rc=0; run_more more-pack apt 'Papirus — Icons|' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-pack/out" && [ "$(yad_count more-pack --info)" -eq 1 ] && [ "$(yad_count more-pack --warning)" -eq 0 ] \
    && dialogs more-pack | grep -qF 'Theme pack installed' && dialogs more-pack | grep -qF 'Package: papirus-icon-theme' \
    && dialogs more-pack | grep -qF 'It now shows in the dropdowns' || fail 'a pack alone must end in one confirmation that says where to find it'
[ "$(redraws more-pack)" -eq 1 ] && [ ! -s "$TMP/more-pack/curl.log" ] && [ "$(yad_count more-pack --progress)" -eq 0 ] && [ ! -s "$TMP/more-pack/events.log" ] \
    || fail 'a pack alone redraws once and opens no download window'
grep -qF 'Theme pack installed' "$TMP/more-pack/notify.log" || fail 'the notification must say it too'
grep -rq 'Theme package installed: papirus-icon-theme' "$TMP/more-pack/state" || fail 'the install must be logged'
# Already installed: the list marks it, picking it reinstalls nothing and, as nothing changed, nothing is redrawn.
rc=0; FAKE_INSTALLED='arc-theme' run_more more-have apt 'Arc — GTK + Cinnamon  ✓|' 0 ok ok || rc=$?
case "$(form_arg more-have '--field=Theme pack:CB')" in 'None!Arc — GTK + Cinnamon  ✓!Materia — GTK + Cinnamon!'*) ;; *) fail "the list must mark what is installed: $(form_arg more-have '--field=Theme pack:CB')" ;; esac
[ "$(form_arg more-have '--field=Theme pack:CB' | grep -o '✓' | wc -l | tr -d ' ')" -eq 1 ] || fail 'only the installed pack may be marked'
[ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-have/out" && [ ! -s "$TMP/more-have/apt.log" ] && [ ! -s "$TMP/more-have/term.log" ] \
    && dialogs more-have | grep -qF "The package 'arc-theme' is already installed." && [ "$(yad_count more-have --info)" -eq 1 ] \
    || fail 'a pack that is already installed must be said and left alone'
[ "$(redraws more-have)" -eq 0 ] || fail 'nothing changed: nothing may be redrawn'
# A pack that does not install: said with apt's verdict, and the Spices name that came with it is not tried (apt's own
# message says nothing else was changed).
rc=0; run_more more-pack-bad apt 'Arc — GTK + Cinnamon|Fixture-Spice|' 0 ok fail || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-pack-bad/out" && [ "$(yad_count more-pack-bad --warning)" -eq 1 ] \
    && dialogs more-pack-bad | grep -qF "'arc-theme' was not installed" && dialogs more-pack-bad | grep -qF 'The theme could not be obtained' \
    || fail 'a pack that does not install must be warned about'
! dialogs more-pack-bad | grep -qF 'ERROR:' || fail 'the warning must not repeat the ERROR: prefix of the message'
[ ! -s "$TMP/more-pack-bad/curl.log" ] && [ "$(yad_count more-pack-bad --progress)" -eq 0 ] && [ "$(redraws more-pack-bad)" -eq 0 ] \
    && [ -z "$(installed_theme more-pack-bad)" ] && more_clean more-pack-bad || fail 'after a failed pack nothing is downloaded, redrawn or left'
# Pack and Spices both well: one confirmation with both, one redraw, the Spices theme remembered.
rc=0; MORE_ZIP="$TMP/both.zip" run_more more-both apt 'Papirus — Icons|Fixture-Both|' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-both/out" && [ "$(yad_count more-both --info)" -eq 1 ] && [ "$(yad_count more-both --warning)" -eq 0 ] \
    && dialogs more-both | grep -qF 'Theme downloaded' && dialogs more-both | grep -qF 'Package: papirus-icon-theme' \
    && dialogs more-both | grep -qF "Path: $TMP/more-both/home/.themes/Fixture-Both" || fail 'pack and theme together must end in one confirmation that names both'
[ "$(redraws more-both)" -eq 1 ] && state_line more-both 'LAST_IMPORTED_THEME="Fixture-Both"' && [ "$(events more-both)" = 'wait-start curl-wait-open wait-stop' ] \
    && [ "$(sudo_calls more-both)" = 'sudo apt-get update|sudo apt-get install papirus-icon-theme' ] || fail 'pack and theme together redraw once and remember the theme'
pass 'Get more themes, packs: each entry of the list installs its own package, one already installed is left alone, one that fails stops there, and pack plus theme report together'

# Without apt (dnf, pacman, zypper): the form has no pack list and says so; the Spices name works the same.
rc=0; run_more more-web dnf 'Fixture-Spice|' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 0' "$TMP/more-web/out" && [ -d "$TMP/more-web/home/.themes/Fixture-Spice" ] && [ "$(redraws more-web)" -eq 1 ] \
    && state_line more-web 'LAST_IMPORTED_THEME="Fixture-Spice"' || fail 'on a system without apt the Spices name must work'
! grep -qF -- 'Theme pack:CB' "$TMP/more-web/yad.log" && dialogs more-web | grep -qF 'Download a theme from Cinnamon Spices by typing its name' \
    && ! dialogs more-web | grep -qF 'software sources' || fail 'on a system without apt the form must offer no pack list and not promise one'
[ ! -s "$TMP/more-web/apt.log" ] && [ ! -s "$TMP/more-web/term.log" ] && [ "$(events more-web)" = 'wait-start curl-wait-open wait-stop' ] \
    || fail 'on a system without apt nothing may reach sudo'
# A name that is not a Spices name never reaches the network.
rc=0; run_more more-badname apt 'None|../evil|' 0 ok ok || rc=$?
[ "$rc" -eq 0 ] && grep -qx 'returned 1' "$TMP/more-badname/out" && [ "$(yad_count more-badname --warning)" -eq 1 ] && dialogs more-badname | grep -qF "is not a Spices theme name" \
    && [ ! -s "$TMP/more-badname/curl.log" ] && [ -z "$(installed_theme more-badname)" ] && more_clean more-badname \
    && [ "$(grep -c wait-start "$TMP/more-badname/events.log" || true)" = "$(grep -c wait-stop "$TMP/more-badname/events.log" || true)" ] \
    || fail 'a name that is not a Spices name must be refused with no download and no window left open'
pass 'Get more themes without apt offers only the Spices name, and a name that is not one never reaches curl'

# Optional, for CI and maintainers: every package of the list must still exist in the distribution that runs the check.
if [ "${CM_CHECK_PACKAGES:-}" = 1 ]; then
    command -v apt-cache > /dev/null 2>&1 || fail 'CM_CHECK_PACKAGES=1 needs apt-cache'
    for pkg in $expected_packages; do
        candidate="$(apt-cache policy "$pkg" 2> /dev/null | awk '/Candidate:/ { print $2 }')"
        { [ -n "$candidate" ] && [ "$candidate" != '(none)' ]; } || fail "$pkg has no installable version in this distribution"
    done
    pass 'every package of the list has an installable version in this distribution'
fi

# Optional, for maintainers, and the only part of the suite that reaches the network:
#   CM_CHECK_SPICES=1 bash tests/run.sh test_catalog.sh        (CM_SPICES_SAMPLE=<UUID> picks the theme to download)
# It runs the real command line against the real Cinnamon Spices server in a throw-away HOME. With no connection the
# suite ends BLOCKED (exit 2), never FAIL: only an answer that differs from what the program expects fails. The INFO
# lines are the measurement of the server (status, type, size, entries): they are what to paste back when it fails.
if [ "${CM_CHECK_SPICES:-}" = 1 ]; then
    for tool in curl unzip zipinfo python3; do
        command -v "$tool" > /dev/null 2>&1 || { printf 'BLOCKED: CM_CHECK_SPICES=1 needs %s\n' "$tool" >&2; exit 2; }
    done
    spices='https://cinnamon-spices.linuxmint.com'
    live="$TMP/live"
    mkdir -p "$live/home" "$live/tmp"
    # live_get <url> <file>: one HTTPS request without --fail, so the status is always seen; prints "<status> <type> <bytes>".
    # Its exit status is curl's own: 6, 7, 28, 35, 60... mean the server never answered.
    live_get() {
        curl --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 60 --max-filesize 33554432 \
            --write-out '%{http_code} %{content_type} %{size_download}' --output "$2" -- "$1" 2> "$2.err"
    }
    rc=0; meta="$(live_get "$spices/json/themes.json" "$live/themes.json")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'BLOCKED: no answer from %s (curl exit %s: %s). The suite runs with an empty environment: a proxy set in your shell is not passed on.\n' \
            "$spices" "$rc" "$(tail -n 1 "$live/themes.json.err" 2> /dev/null)" >&2
        exit 2
    fi
    printf 'INFO: GET json/themes.json -> %s\n' "$meta"
    # The index lists every theme; its names are the UUIDs that `theme fetch` takes. Nocturne is the default sample.
    python3 - "$live/themes.json" "$live/sample" "${CM_SPICES_SAMPLE:-}" <<'PY'
import json
import re
import sys

path, sample_file, wanted = sys.argv[1:4]
names, first, shape = [], None, 'unreadable'
try:
    with open(path, encoding='utf-8') as handle:
        data = json.load(handle)
    shape = type(data).__name__
    if isinstance(data, dict):
        names = [str(key) for key in data]
        first = next(iter(data.values()), None)
    elif isinstance(data, list):
        names = [str(item.get('uuid') or item.get('name') or '') for item in data if isinstance(item, dict)]
        first = data[0] if data else None
except (OSError, ValueError):
    pass
usable = [n for n in names if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', n) and '..' not in n]
sample = wanted or ('Nocturne' if 'Nocturne' in usable or not usable else usable[0])
fields = ','.join(sorted(first)[:10]) if isinstance(first, dict) else type(first).__name__
if shape == 'unreadable':
    print(f'INFO: the index could not be read as JSON; sample: {sample}')
else:
    print(f'INFO: the index is JSON ({shape}) with {len(names)} entries, {len(usable)} with a name this program accepts; '
          f'an entry has: {fields}; sample: {sample}')
with open(sample_file, 'w', encoding='utf-8') as out:
    out.write(sample + '\n')
PY
    sample="$(cat "$live/sample")"
    head_out="$(curl --silent --head --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
        -- "$spices/files/themes/$sample.zip" 2> /dev/null | tr -d '\r' \
        | awk 'NR == 1 || tolower($1) ~ /^(content-type|content-length|location|last-modified):$/' | paste -sd'|' || true)"
    printf 'INFO: HEAD files/themes/%s.zip -> %s\n' "$sample" "${head_out:-no answer}"

    live_fetch() {   # <home> <name>: the real command line, output to <home>.out and <home>.err
        env HOME="$1" CM_HOME="$1.state" TMPDIR="$live/tmp" CM_LANG_OVERRIDE=en \
            bash "$SCRIPT" theme fetch "$2" > "$1.out" 2> "$1.err"
    }
    dest="$live/home/.themes/$sample"
    rc=0; live_fetch "$live/home" "$sample" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'INFO: theme fetch %s failed (exit %s): %s\n' "$sample" "$rc" "$(paste -sd'|' "$live/home.err")"
        rc=0; meta="$(live_get "$spices/files/themes/$sample.zip" "$live/raw.zip")" || rc=$?
        printf 'INFO: GET files/themes/%s.zip -> curl exit %s, %s\n' "$sample" "$rc" "$meta"
        [ ! -s "$live/raw.zip" ] || printf 'INFO: first entries of what arrived: %s\n' "$(unzip -Z1 -- "$live/raw.zip" 2> /dev/null | head -n 12 | paste -sd'|' || true)"
        fail "the real server does not give what theme fetch expects for $sample: see the INFO lines above"
    fi
    [ "$(cat "$live/home.out")" = "$dest" ] || fail "theme fetch must print the folder it installed into, and only that: $(cat "$live/home.out")"
    [ -n "$(find "$dest" -type f 2> /dev/null | head -n 1)" ] || fail "the installed folder of $sample holds no files"
    printf 'INFO: installed %s: %s files, %s; top level: %s\n' "$sample" "$(find "$dest" -type f | wc -l | tr -d ' ')" \
        "$(du -sh "$dest" | cut -f1)" "$(find "$dest" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')"
    [ -z "$(find "$live/tmp" -mindepth 1 2> /dev/null | head -n 1)" ] || fail 'the real download left temporary files behind'
    rc=0; live_fetch "$live/home" "$sample" || rc=$?
    [ "$rc" -eq 0 ] && [ "$(cat "$live/home.out")" = "$dest" ] && [ "$(find "$live/home/.themes" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ] \
        || fail 'a second fetch of the same theme must change nothing'
    # A name that does not exist: refused either by the HTTP status or because what arrives is not a zip; nothing installed.
    rc=0; live_fetch "$live/missing" Color-Mint-No-Such-Theme-0000 || rc=$?
    { [ "$rc" -eq 1 ] && [ -z "$(find "$live/missing/.themes" "$live/missing/.icons" -mindepth 1 2> /dev/null | head -n 1)" ]; } \
        || fail "an unknown name must fail and install nothing (exit $rc)"
    printf 'INFO: an unknown name is answered with: %s\n' "$(paste -sd'|' "$live/missing.err")"
    pass "the real Cinnamon Spices server serves $sample in the form theme fetch expects, a second fetch changes nothing and an unknown name installs nothing"
fi
