// Stack: vanilla JavaScript (browser) | File: web/app.js
// An image upload is two REST calls: POST /files/<name> with the raw bytes and a Content-Type (returns a public URL),
// then POST /classes/Photo with a File field that references the name. Listing is one GET. No SDK, no bucket, no server.

const BASE = window.BACKEND_URL ?? "https://parseapi.back4app.com";
const HEADERS = {
  "X-Parse-Application-Id": window.APP_ID,
  "X-Parse-JavaScript-Key": window.JS_KEY,      // a client key: identifies the app, not the user
  "X-Parse-Revocable-Session": "1",
};

// The session token is the only state the page keeps. Uploads without it are refused (code 130).
const session = {
  get: () => sessionStorage.getItem("sessionToken"),
  set: (t) => sessionStorage.setItem("sessionToken", t),
  clear: () => sessionStorage.removeItem("sessionToken"),
};

// One helper for every call. `body` is a plain object (sent as JSON) or a File/Blob (sent as raw bytes with its type).
async function api(method, path, body) {
  const headers = { ...HEADERS };
  const token = session.get();
  if (token) headers["X-Parse-Session-Token"] = token;
  let payload;
  if (body instanceof Blob) { headers["Content-Type"] = body.type || "application/octet-stream"; payload = body; }
  else if (body) { headers["Content-Type"] = "application/json"; payload = JSON.stringify(body); }
  const r = await fetch(BASE + path, { method, headers, body: payload });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(data.error ?? r.statusText), { code: data.code, status: r.status });
  return data;
}

const $ = (s) => document.querySelector(s);
const status = (msg, kind = "") => { $("#status").textContent = msg; $("#status").className = kind; };
const fmt = (n) => n.toLocaleString("en-US");
let me = null;

// Step 1: the bytes. POST /files/<name> answers 201 {url, name}. The name comes back prefixed with a hash, so two users
// uploading "avatar.jpg" never collide; the url is public to anyone who has it.
async function uploadFile(file) {
  const safeName = file.name.replace(/[^\w.]+/g, "-");   // the path segment, not the served name
  return api("POST", `/files/${encodeURIComponent(safeName)}`, file);
}

// Step 2: the row. A File field references the stored file by name; the backend fills in the url when you read it back.
// owner is a pointer to the logged-in user; the ACL lets everyone read the row and only the owner change or delete it.
async function createPhoto({ name }, caption, file) {
  return api("POST", "/classes/Photo", {
    caption,
    image: { __type: "File", name },
    contentType: file.type,
    size: file.size,
    owner: { __type: "Pointer", className: "_User", objectId: me.objectId },
    ACL: { "*": { read: true }, [me.objectId]: { read: true, write: true } },
  });
}

async function listPhotos() {
  const q = new URLSearchParams({ order: "-createdAt", limit: "20", include: "owner", keys: "image,caption,size,contentType,owner.username,createdAt" });
  const { results } = await api("GET", `/classes/Photo?${q}`);
  $("#photos").replaceChildren(...results.map((p) => {
    const li = document.createElement("li");
    const img = Object.assign(document.createElement("img"), { src: p.image?.url ?? "", alt: p.caption || "photo", loading: "lazy" });
    const div = document.createElement("div");
    const title = Object.assign(document.createElement("b"), { textContent: p.caption || "(no caption)" });
    const meta = Object.assign(document.createElement("small"), { textContent: `${p.owner?.username ?? "?"} · ${p.size ? fmt(p.size) + " bytes" : ""} · ${new Date(p.createdAt).toISOString().slice(0, 19)}Z` });
    const url = Object.assign(document.createElement("code"), { textContent: p.image?.url ?? "" });
    div.append(title, meta, document.createElement("br"), url);
    li.append(img, div);
    return li;
  }));
}

async function showMe() {
  if (!session.get()) { $("#anon").hidden = false; $("#me").hidden = true; return; }
  try {
    me = await api("GET", "/users/me");                       // validates the token on every page load
    $("#who small").textContent = `logged in as ${me.username}`;
    $("#anon").hidden = true; $("#me").hidden = false;
    await listPhotos();
  } catch (err) {
    session.clear(); me = null; $("#anon").hidden = false; $("#me").hidden = true;
    status(`session rejected: ${err.code} ${err.message}`, "err");
  }
}

$("#signup").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = Object.fromEntries(new FormData(e.target));
  const action = e.submitter?.value ?? "signup";
  try {
    const u = action === "login" ? await api("POST", "/login", { username: f.username, password: f.password }) : await api("POST", "/users", f);
    session.set(u.sessionToken);
    status(`${action === "login" ? "logged in" : "signed up"} as ${f.username}`, "ok");
    e.target.reset(); showMe();
  } catch (err) { status(`${err.code} ${err.message}`, "err"); }
});

$("#upload").addEventListener("submit", async (e) => {
  e.preventDefault();
  const file = e.target.file.files[0];
  const caption = e.target.caption.value.trim();
  if (!file) return;
  try {
    status(`uploading ${file.name} (${fmt(file.size)} bytes)…`);
    const t0 = performance.now();
    const stored = await uploadFile(file);                    // 201 {url, name}
    const t1 = performance.now();
    const photo = await createPhoto(stored, caption, file);   // 201 {objectId, createdAt}
    const t2 = performance.now();
    status(`uploaded ${fmt(file.size)} bytes in ${Math.round(t1 - t0)} ms, row ${photo.objectId} created in ${Math.round(t2 - t1)} ms\n${stored.url}`, "ok");
    e.target.reset(); await listPhotos();
  } catch (err) { status(`${err.code ?? err.status} ${err.message}`, "err"); }
});

$("#logout").addEventListener("click", async () => {
  try { await api("POST", "/logout"); } finally { session.clear(); me = null; status("logged out"); showMe(); }
});

showMe();
