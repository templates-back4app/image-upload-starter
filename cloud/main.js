// Stack: Node.js 22.x | Parse Server 7.x (Cloud Code) | File: cloud/main.js
// Two rules the page cannot be trusted to keep. Deploy in the dashboard under Cloud Code → main.js (twice on a fresh
// backend: the first deploy ships nothing), then prove each rule with a request before relying on it.

// Rule 1: a Photo belongs to whoever uploaded it, whatever the client claimed. Anyone may read the row; only the owner
// may change or delete it. Set here, on the backend, so a curl command cannot skip it.
Parse.Cloud.beforeSave("Photo", (request) => {
  const photo = request.object;
  if (!photo.isNew()) return;
  const owner = request.user;
  if (!owner) throw new Parse.Error(Parse.Error.SESSION_MISSING, "log in to upload a photo.");
  if (!photo.get("image")) throw new Parse.Error(Parse.Error.VALIDATION_ERROR, "a Photo needs an image.");
  photo.set("owner", owner);
  const acl = new Parse.ACL();
  acl.setPublicReadAccess(true);
  acl.setWriteAccess(owner, true);
  photo.setACL(acl);
});

// Rule 2: deleting the row deletes the file. Measured on 2026-09-24: without this, DELETE /classes/Photo/<id> returns
// 200 and the file URL keeps serving the bytes; only DELETE /files/<name> with the master key removes the object, and
// that call is refused (403) to session tokens and client keys. So the backend does it here, with the master key.
Parse.Cloud.beforeDelete("Photo", async (request) => {
  const file = request.object.get("image");
  if (!file) return;
  try {
    await file.destroy({ useMasterKey: true });
  } catch (err) {
    // A file that is already gone must not block the row delete; anything else should.
    if (err.code !== Parse.Error.FILE_DELETE_ERROR && err.code !== Parse.Error.OBJECT_NOT_FOUND) throw err;
  }
});
