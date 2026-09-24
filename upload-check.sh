#!/usr/bin/env bash
# Stack: bash 3.2+ + curl + python3 (Pillow) | File: upload-check.sh
# Measures file uploads to a managed backend end to end: who may upload, how big a file can be and how long it takes,
# which content types are accepted, what the returned URL serves and through what, whether the URL is public even when
# the row that references it is owner-only, and what happens to the file when the row or the file itself is deleted.
# usage: set -a; . ./.env; set +a; ./upload-check.sh          # everything
#        ./upload-check.sh sizes                                # only the size/time table (for repeat runs)
set -uo pipefail
BASE="${BASE:-https://parseapi.back4app.com}"
: "${APP_ID:?}" "${JS_KEY:?}" "${MASTER_KEY:?}"
H=(-H "X-Parse-Application-Id: $APP_ID" -H "X-Parse-JavaScript-Key: $JS_KEY" -H "X-Parse-Revocable-Session: 1")
MK=(-H "X-Parse-Application-Id: $APP_ID" -H "X-Parse-Master-Key: $MASTER_KEY")
WORK="${WORK:-$(mktemp -d)}"; mkdir -p "$WORK"
MODE="${1:-all}"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '\n== %s  (%s)\n' "$1" "$(now)"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
redact() { sed "s#$APP_ID#<APP_ID>#g"; }
served() { curl -s -o /dev/null -w '%{http_code}  %{content_type}  %{size_download} bytes\n' "$1"; }

# A real PNG of about N bytes: random pixels, stored uncompressed, so the size is what we asked for.
mkpng() { python3 - "$1" "$2" <<'PY'
import math, os, sys
from PIL import Image
target, out = int(sys.argv[1]), sys.argv[2]
side = max(4, int(math.sqrt(target / 3)))
Image.frombytes("RGB", (side, side), os.urandom(side * side * 3)).save(out, "PNG", compress_level=0)
PY
}
# upload <label> <file> <content-type> <remote-name>: prints "http time_total speed_upload size_upload", keeps url/name in $WORK
upload() {
  local label=$1 file=$2 ct=$3 name=$4 out code
  out=$(curl -s -o "$WORK/$label.json" -w '%{http_code} %{time_total} %{speed_upload} %{size_upload}' "${S[@]}" -H "Content-Type: $ct" -X POST "$BASE/files/$name" --data-binary @"$file")
  code=${out%% *}
  if [ "$code" = 201 ]; then json 'd["url"]' <"$WORK/$label.json" >"$WORK/$label.url"; json 'd["name"]' <"$WORK/$label.json" >"$WORK/$label.name"; fi
  echo "$out"
}

echo "upload-check.sh  $(now)  base=$BASE  work=$WORK"

say "0 a fresh user (uploads need a session)"
U="pix$RANDOM"; P="correct-horse-$RANDOM"
R=$(curl -s "${H[@]}" -H "Content-Type: application/json" -X POST "$BASE/users" -d "{\"username\":\"$U\",\"email\":\"$U@example.com\",\"password\":\"$P\"}")
TOKEN=$(json 'd["sessionToken"]' <<<"$R"); USER_ID=$(json 'd["objectId"]' <<<"$R")
echo "user $U ($USER_ID) signed up"
S=("${H[@]}" -H "X-Parse-Session-Token: $TOKEN")

if [ "$MODE" = all ]; then
say "1 who may upload? (10 KB PNG, three identities)"
mkpng 10000 "$WORK/10k.png"
printf '%-34s' "client key only (anonymous)";    curl -s -w '  %{http_code}\n' "${H[@]}"  -H "Content-Type: image/png" -X POST "$BASE/files/anon.png"   --data-binary @"$WORK/10k.png"
printf '%-34s' "session token (logged-in user)"; curl -s -w '  %{http_code}\n' "${S[@]}"  -H "Content-Type: image/png" -X POST "$BASE/files/user.png"   --data-binary @"$WORK/10k.png" | redact
printf '%-34s' "master key (server only)";       curl -s -w '  %{http_code}\n' "${MK[@]}" -H "Content-Type: image/png" -X POST "$BASE/files/master.png" --data-binary @"$WORK/10k.png" | redact

fi
say "2 how big, how long? (session token, one POST each, curl time_total)"
printf '%-8s %-12s %-6s %-9s %-10s %s\n' size bytes http total_s upload_MBs url
for sz in 10K:10000 100K:100000 1M:1000000 5M:5000000 10M:10000000; do
  label=${sz%%:*}; bytes=${sz##*:}; f="$WORK/$label.png"; mkpng "$bytes" "$f"
  read -r code total speed sent <<<"$(upload "$label" "$f" image/png "photo-$label.png")"
  printf '%-8s %-12s %-6s %-9s %-10s %s\n' "$label" "$sent" "$code" "$total" "$(python3 -c "print(round($speed/1e6,2))")" "$(redact <"$WORK/$label.url" 2>/dev/null || redact <"$WORK/$label.json")"
done

if [ "$MODE" = all ]; then
say "3 where is the limit? (25 MB, then smaller until one passes)"
for sz in 25M:25000000 20M:20000000 15M:15000000; do
  label=${sz%%:*}; bytes=${sz##*:}; f="$WORK/$label.png"; mkpng "$bytes" "$f"
  read -r code total speed sent <<<"$(upload "$label" "$f" image/png "photo-$label.png")"
  printf '%-8s %-12s %-6s %-9s %s\n' "$label" "$sent" "$code" "$total" "$(redact <"$WORK/$label.json" | head -c 300)"
  [ "$code" = 201 ] && break
done

say "4 which content types are accepted? (session token)"
printf 'hello, plain text' >"$WORK/probe.txt"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" rx="12" fill="#1568b8"/></svg>' >"$WORK/probe.svg"
printf '<h1>hi</h1>' >"$WORK/probe.html"; printf 'alert(1)' >"$WORK/probe.js"; printf 'raw bytes' >"$WORK/probe.bin"
for spec in "txt:text/plain" "svg:image/svg+xml" "html:text/html" "js:text/javascript" "bin:application/octet-stream"; do
  ext=${spec%%:*}; ct=${spec##*:}
  printf '%-30s' "probe.$ext  $ct"; read -r code rest <<<"$(upload "probe-$ext" "$WORK/probe.$ext" "$ct" "probe.$ext")"
  echo "$code  $(redact <"$WORK/probe-$ext.json" | head -c 200)"
done
printf '%-30s' "probe.bin  (no Content-Type)"; curl -s -w '  %{http_code}\n' "${S[@]}" -X POST "$BASE/files/probe.bin" --data-binary @"$WORK/probe.bin" | redact
printf '%-30s' "photo.jpg  image/jpeg, PNG bytes"; read -r code rest <<<"$(upload "mislabelled" "$WORK/10k.png" image/jpeg photo.jpg)"; echo "$code  $(redact <"$WORK/mislabelled.json" | head -c 200)"

say "5 what does the URL serve? (GET, no headers)"
u=$(cat "$WORK/1M.url"); echo "url: $(redact <<<"$u")"
for i in 1 2; do
  echo "-- GET #$i"; curl -s -o /dev/null -D - -w 'time_total %{time_total}s  size %{size_download}\n' "$u" | grep -iE '^HTTP|content-type|content-length|cache-control|etag|last-modified|^via|x-cache|x-amz-cf-pop|^server|access-control|content-disposition|x-content-type|^age:|time_total'
done
echo "-- served content-type by extension:"
for ext in txt svg bin mislabelled; do
  f="$WORK/probe-$ext.url"; [ "$ext" = mislabelled ] && f="$WORK/mislabelled.url"
  [ -f "$f" ] && { printf '%-14s' "$ext"; served "$(cat "$f")"; }
done

say "6 is the file URL public when the Photo row is owner-only?"
NAME1M=$(cat "$WORK/1M.name")
PHOTO=$(curl -s "${S[@]}" -H "Content-Type: application/json" -X POST "$BASE/classes/Photo" -d "{\"caption\":\"owner-only row\",\"owner\":{\"__type\":\"Pointer\",\"className\":\"_User\",\"objectId\":\"$USER_ID\"},\"image\":{\"__type\":\"File\",\"name\":\"$NAME1M\",\"url\":\"$u\"},\"ACL\":{\"$USER_ID\":{\"read\":true,\"write\":true}}}")
PID=$(json 'd["objectId"]' <<<"$PHOTO"); echo "Photo $PID created with ACL {owner: read+write} and image=$NAME1M"
printf '%-42s' "anonymous GET /classes/Photo/$PID";    curl -s -w '  %{http_code}\n' "${H[@]}" "$BASE/classes/Photo/$PID"
printf '%-42s' "owner     GET /classes/Photo/$PID";    curl -s -o /dev/null -w '%{http_code}\n' "${S[@]}" "$BASE/classes/Photo/$PID"
printf '%-42s' "anyone    GET the file URL, no headers"; served "$u"

say "7 does the file survive when the row is deleted?"
printf '%-42s' "owner DELETE /classes/Photo/$PID"; curl -s -w '  %{http_code}\n' "${S[@]}" -X DELETE "$BASE/classes/Photo/$PID"
sleep 2
printf '%-42s' "GET the file URL after the row delete"; served "$u"

say "8 who may delete a file, and what does the URL return afterwards?"
printf '%-42s' "session token DELETE /files/<name>"; curl -s -w '  %{http_code}\n' "${S[@]}"  -X DELETE "$BASE/files/$NAME1M"
printf '%-42s' "client key    DELETE /files/<name>"; curl -s -w '  %{http_code}\n' "${H[@]}"  -X DELETE "$BASE/files/$NAME1M"
printf '%-42s' "master key    DELETE /files/<name>"; curl -s -w '  %{http_code}\n' "${MK[@]}" -X DELETE "$BASE/files/$NAME1M"
sleep 2
printf '%-42s' "GET the file URL after the file delete"; served "$u"
sleep 10
printf '%-42s' "GET again 10 s later";                 served "$u"
printf '%-42s' "master key DELETE again";               curl -s -w '  %{http_code}\n' "${MK[@]}" -X DELETE "$BASE/files/$NAME1M"

fi
say "9 cleanup: delete the other test files with the master key"
for f in "$WORK"/*.name; do n=$(basename "$f" .name); [ "$n" = 1M ] && [ "$MODE" = all ] && continue; printf '%-14s' "$n"; curl -s -o /dev/null -w '%{http_code}\n' "${MK[@]}" -X DELETE "$BASE/files/$(cat "$f")"; done
echo "done $(now)  user=$U"
