#!/usr/bin/env bash
# Stack: bash 3.2+ + curl + python3 (Pillow) | File: hook-check.sh
# Proves the two Cloud Code rules in cloud/main.js after they are deployed:
#   beforeSave("Photo")  — owner and ACL come from the session, whatever the client sent; no session → 206
#   beforeDelete("Photo") — deleting the row deletes the file (origin 404), without the client holding the master key
# usage: set -a; . ./.env; set +a; ./hook-check.sh
set -uo pipefail
BASE="${BASE:-https://parseapi.back4app.com}"
: "${APP_ID:?}" "${JS_KEY:?}"
H=(-H "X-Parse-Application-Id: $APP_ID" -H "X-Parse-JavaScript-Key: $JS_KEY" -H "X-Parse-Revocable-Session: 1")
WORK="${WORK:-$(mktemp -d)}"; mkdir -p "$WORK"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '\n== %s  (%s)\n' "$1" "$(now)"; }
json() { python3 -c "import json,sys
try: d=json.load(sys.stdin); print($1)
except Exception: print('')"; }
redact() { sed "s#$APP_ID#<APP_ID>#g"; }
served() { curl -s -o /dev/null -D "$WORK/h" -w '%{http_code}  %{content_type}  %{size_download} bytes' "$1"; printf '  %s\n' "$(grep -iE '^x-cache|^age' "$WORK/h" | tr -d '\r' | tr '\n' ' ')"; }
python3 - "$WORK/pic.png" <<'PY'
import os, sys
from PIL import Image
Image.frombytes("RGB", (60, 60), os.urandom(60 * 60 * 3)).save(sys.argv[1], "PNG", compress_level=0)
PY

echo "hook-check.sh  $(now)  base=$BASE"

say "0 two fresh users"
mk_user() { curl -s "${H[@]}" -H "Content-Type: application/json" -X POST "$BASE/users" -d "{\"username\":\"$1\",\"email\":\"$1@example.com\",\"password\":\"correct-horse-$RANDOM\"}"; }
A=$(mk_user "pixa$RANDOM"); TA=$(json 'd["sessionToken"]' <<<"$A"); IDA=$(json 'd["objectId"]' <<<"$A")
B=$(mk_user "pixb$RANDOM"); TB=$(json 'd["sessionToken"]' <<<"$B"); IDB=$(json 'd["objectId"]' <<<"$B")
SA=("${H[@]}" -H "X-Parse-Session-Token: $TA"); SB=("${H[@]}" -H "X-Parse-Session-Token: $TB")
echo "ana=$IDA  bob=$IDB"

say "1 upload with ana's session"
F=$(curl -s "${SA[@]}" -H "Content-Type: image/png" -X POST "$BASE/files/hook.png" --data-binary @"$WORK/pic.png")
NAME=$(json 'd["name"]' <<<"$F"); URL=$(json 'd["url"]' <<<"$F"); echo "name=$NAME"; echo "url=$(redact <<<"$URL")"

say "2 beforeSave: no session → ?"
curl -s -w '  %{http_code}\n' "${H[@]}" -H "Content-Type: application/json" -X POST "$BASE/classes/Photo" -d "{\"caption\":\"anonymous\",\"image\":{\"__type\":\"File\",\"name\":\"$NAME\"}}"

say "3 beforeSave: ana sends owner=bob and a public-write ACL → what is stored?"
P=$(curl -s "${SA[@]}" -H "Content-Type: application/json" -X POST "$BASE/classes/Photo" -d "{\"caption\":\"hook test\",\"image\":{\"__type\":\"File\",\"name\":\"$NAME\"},\"owner\":{\"__type\":\"Pointer\",\"className\":\"_User\",\"objectId\":\"$IDB\"},\"ACL\":{\"*\":{\"read\":true,\"write\":true}}}")
PID=$(json 'd["objectId"]' <<<"$P"); echo "created '$PID': $(head -c 200 <<<"$P")"
[ -n "$PID" ] || { echo "no row was created; the rest of the proof cannot run. done $(now)"; exit 1; }
echo "stored (ana reads it back):"; curl -s "${SA[@]}" "$BASE/classes/Photo/$PID?keys=owner,ACL,caption" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  owner =', d['owner']['objectId'], '(ana=$IDA bob=$IDB)'); print('  ACL   =', json.dumps(d['ACL']))"
printf '%-46s' "bob (not owner) PUT caption";  curl -s -w '  %{http_code}\n' "${SB[@]}" -H "Content-Type: application/json" -X PUT "$BASE/classes/Photo/$PID" -d '{"caption":"bob was here"}'
printf '%-46s' "bob (not owner) DELETE";       curl -s -w '  %{http_code}\n' "${SB[@]}" -X DELETE "$BASE/classes/Photo/$PID"
printf '%-46s' "anonymous GET (public read)";  curl -s -o /dev/null -w '%{http_code}\n' "${H[@]}" "$BASE/classes/Photo/$PID"

say "4 beforeSave: a Photo without an image → ?"
curl -s -w '  %{http_code}\n' "${SA[@]}" -H "Content-Type: application/json" -X POST "$BASE/classes/Photo" -d '{"caption":"no image"}'

say "5 before the delete: the file is served"
ORIGIN="$BASE/files/$APP_ID/$NAME"
printf '%-46s' "GET origin path (API host)"; curl -s -o /dev/null -w '%{http_code}\n' "$ORIGIN"
printf '%-46s' "GET CDN url";                 served "$URL"

say "6 beforeDelete: ana (owner, no master key) deletes the row"
printf '%-46s' "ana DELETE /classes/Photo/$PID"; curl -s -w '  %{http_code}\n' "${SA[@]}" -X DELETE "$BASE/classes/Photo/$PID"
sleep 2
printf '%-46s' "GET row afterwards (ana)";       curl -s -w '  %{http_code}\n' "${SA[@]}" "$BASE/classes/Photo/$PID" | head -c 200; echo
printf '%-46s' "GET origin path (API host)";     curl -s -o /dev/null -w '%{http_code}\n' "$ORIGIN"
printf '%-46s' "GET CDN url";                    served "$URL"
sleep 10
printf '%-46s' "GET origin path 10 s later";     curl -s -o /dev/null -w '%{http_code}\n' "$ORIGIN"
printf '%-46s' "GET CDN url 10 s later";         served "$URL"
echo "done $(now)"
