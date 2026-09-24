# image-upload-starter

[![Deploy on Back4app](https://img.shields.io/badge/Deploy%20on-Back4app-1568B8?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTEyIDJMMiA3djEwbDEwIDUgMTAtNVY3eiIvPjwvc3ZnPg==)](https://www.back4app.com/signup?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter)

**Upload and serve user images (avatars, photos) from a web page without setting up object storage, signed URLs or an upload server.** Two REST calls to a managed [Back4app](https://www.back4app.com/?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter) backend do it: `POST /files/<name>` with the raw bytes returns a public, CDN-served URL; `POST /classes/Photo` references that file from a row with an `owner` pointer and a caption. The code here is one HTML page with 120 lines of vanilla JavaScript, a 32-line Cloud Code file and a `curl` script that measures everything.

Measured on September 24, 2026: a **1 MB** image uploaded in **6.8 s** from `curl` and **6.8 s** from the page, a **10 MB** image in **57 s** (medians of three runs), and a **50 MB** file never got an answer (three attempts, every byte sent, connection closed without a status). The file URL answered **200 to anyone** with no headers, while the row that referenced it was owner-only (`404 / 101` to everyone else). Deleting the row left the file online; deleting the file with the master key left the CDN copy online. Every number in the article comes from the two scripts in this repo.

> **Read the article:** [How to Upload and Serve Images From an App Without S3](https://www.back4app.com/blog/upload-and-serve-images-without-s3?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter)

## The two calls

| Call | What it does | Measured (session token, 2026-09-24) |
|---|---|---|
| `POST /files/avatar.png` (raw bytes, `Content-Type: image/png`) | Stores the file, returns `201 {url, name}`; `name` is `<32-hex>_avatar.png` | 10 KB 1.3 s · 100 KB 2.3 s · 1 MB 6.8 s · 5 MB 30 s · 10 MB 57 s (medians of 3) · 25 MB 130 s · 50 MB no answer |
| `POST /classes/Photo` with `image: {__type: "File", name}` | The row that references the file, with `owner`, `caption`, `ACL` | 201 |
| `GET /classes/Photo?include=owner` | Lists rows; the backend fills in `image.url` | 200 |
| `GET <url>` (no headers) | The bytes, from the CDN, `image/png`, CORS `*`, ranges | 200 · `x-cache: Hit from cloudfront` |
| `DELETE /files/<name>` (master key only) | Removes the object; session token and client key get `403` | 200 · the CDN kept serving the cached copy |

## What is in here

- `web/` — `index.html` and `app.js` (vanilla JavaScript, no framework, no SDK): sign up or log in, pick a file, upload it, create the Photo row, list photos with their URLs. The status line prints the two timings from `performance.now()`.
- `cloud/main.js` — the backend rules, deployed as Cloud Code: `beforeSave("Photo")` sets the owner and the ACL from the session, `beforeDelete("Photo")` deletes the file with the master key so a deleted row does not leave its bytes online.
- `upload-check.sh` — the measurements from `curl`: who may upload (client key → `130`), the size and time table, the limit probe, accepted content types (`.html` → `130`, `.svg`/`.txt`/`.js` → `201`), what the URL serves and through what, the owner-only ACL test, the row-delete and file-delete tests.
- `web-check.mjs` — drives `web/` in headless Chrome over the DevTools protocol (no browser package): signs up, sets the file input, clicks Upload, reads the page's own timings, takes the screenshots.

## Findings from the run

- Uploads with only the App ID and a client key are refused: `400 {"code":130,"error":"File upload by public is disabled."}`. A logged-in user's session token (or the master key) is required. Log in before you upload.
- The file URL is public. A Photo row with an owner-only ACL answered `404 / 101 Object not found` to everyone but the owner; the URL in its `image` field answered `200 image/png` to a `curl` with no headers. The ACL guards the row, not the bytes.
- Deleting the row does not delete the file. `DELETE /classes/Photo/<id>` returned `200`; the URL still returned `200` afterwards. `DELETE /files/<name>` needs the master key (`403 unauthorized: master key is required` otherwise), which is why `cloud/main.js` does it in `beforeDelete`.
- Deleting the file does not empty the CDN. After the master-key delete the origin path returned `404`, but the public URL kept serving the bytes with `x-cache: Hit from cloudfront` and a rising `age`, still `200` at 32 minutes when we stopped polling. The object is served with no `cache-control` header, and a query string does not bust the cache.
- `.html` uploads are refused (`130 File upload of extension html is disabled.`); `.svg`, `.txt`, `.js` and a file with no `Content-Type` are accepted, and the URL serves whatever `Content-Type` you sent, checked against nothing: PNG bytes sent as `image/jpeg` come back as `image/jpeg`.
- A 25 MB file was accepted (130 s). A 50 MB file was not: in three attempts (two over HTTP/2, one over HTTP/1.1) all 50,008,266 bytes were sent and the connection closed without a status after 200–329 s (`Error in the HTTP2 framing layer`, `Empty reply from server`). Whether that is a size ceiling or a request timeout, the backend did not say.

## Deploy your own

1. **Create a free backend.** Sign up at [https://www.back4app.com/signup?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter](https://www.back4app.com/signup?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter), then **New App → Build your Backend**. The free plan (1 GB of file storage) is enough for everything here.
2. **App Settings → Security & Keys**: copy the App ID and the JavaScript key into `web/config.js` (copy `web/config.example.js`; `config.js` is git-ignored). For `upload-check.sh`, copy the same two plus the Master key into `.env` (`.env.example` shows the names). The master key stays on your machine.
3. **Cloud Code → main.js**: paste `cloud/main.js` and click **Deploy**, twice on a fresh backend (the first deploy ships nothing). Prove it: delete a Photo row from the page or the Database Browser, then `GET` its file's origin path; it must be gone.
4. Serve `web/` with any static server and upload a picture. **Database → Photo** shows the row with the `image` column as a file link, and **Database → Files** (if your dashboard has it) lists the stored objects.

## Run it

```bash
cp web/config.example.js web/config.js   # APP_ID, JS_KEY
cd web && python3 -m http.server 8765    # then open http://127.0.0.1:8765/

cp .env.example .env                     # APP_ID, JS_KEY, MASTER_KEY
set -a; . ./.env; set +a
./upload-check.sh                        # everything: identities, sizes, limit, types, headers, ACL, deletes
./upload-check.sh sizes                  # the size/time table only, for repeat runs
node web-check.mjs http://127.0.0.1:8765/ ./runs path/to/a.png path/to/b.png   # the same upload from the page, headless Chrome
```

`upload-check.sh` needs `python3` with Pillow (it generates real PNGs of the sizes it uploads) and deletes the files it created at the end, with the master key. `web-check.mjs` needs Node 22+ and Google Chrome (`CHROME=/path/to/chrome` to point at another build).

## What the backend gives you

A managed Parse Server with a file store behind a CDN, a database with a File field type, REST and GraphQL APIs, and Cloud Code where the master key can live. Documentation: [https://www.back4app.com/docs?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter](https://www.back4app.com/docs?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter) · REST files guide: [https://www.back4app.com/docs/rest-api/files](https://www.back4app.com/docs/rest-api/files?utm_source=github&utm_medium=repo&utm_campaign=image-upload-starter).

Uploads need a logged-in user; if the app does not have accounts yet, start with [user-auth-starter](https://github.com/templates-back4app/user-auth-starter). To decide who may read the Photo rows, see [lockdown-lab](https://github.com/templates-back4app/lockdown-lab).

## License

MIT
