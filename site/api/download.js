// Download for Kit for MPC3000 buyers.
//
// After paying, Stripe redirects to /thanks/?key=<code>. The code is set only in the Stripe
// Payment Link's redirect (plink_1UYluHPc3KBNseSeyFyUCCtD), so only buyers are sent to it.
// This file holds just its SHA-256, never the code itself: the repository is public.
// With a valid code, the DMG streams from the private Vercel Blob store kitmpc3000-releases.
//
//   GET /api/download?key=<code>           the DMG, or a short plain-text refusal
//   GET /api/download?key=<code>&check=1   {"paid": bool, "ready": bool} for /thanks/
//
// The same link keeps working, so buyers get later versions from it. If it ever leaks, make
// a new code, put its SHA-256 below and the code in the Stripe redirect: docs/LAUNCH.md.
// Needs BLOB_READ_WRITE_TOKEN on the Vercel project (added when the Blob store was connected).
import { createHash, timingSafeEqual } from "node:crypto";
import { get } from "@vercel/blob";

const KEY_SHA256 = "0176102893e47a7a5d38010baed7aa44de5e0ce85a8665323115d296a50f317c";
const RELEASE_PATHNAME = "releases/Kit-for-MPC3000-Apple-Silicon.dmg";
const DOWNLOAD_NAME = "Kit-for-MPC3000-Apple-Silicon.dmg";

function reply(status, body, json = false) {
  return new Response(json ? JSON.stringify(body) : body + "\n", {
    status,
    headers: {
      "Content-Type": json ? "application/json" : "text/plain; charset=utf-8",
      "Cache-Control": "private, no-store",
      "X-Robots-Tag": "noindex",
    },
  });
}

function validKey(key) {
  if (!/^[A-Za-z0-9_-]{20,100}$/.test(key)) return false;
  const given = createHash("sha256").update(key).digest();
  return timingSafeEqual(given, Buffer.from(KEY_SHA256, "hex"));
}

export async function GET(request) {
  const params = new URL(request.url).searchParams;
  const check = params.has("check");
  if (!validKey(params.get("key") || "")) {
    return check ? reply(403, { paid: false, ready: false }, true)
                 : reply(403, "This isn’t a valid download link. Ce lien de téléchargement n’est pas valide.");
  }

  // Pass the store's token explicitly: the runtime also has an OIDC token without a store id,
  // and the SDK refuses to pick between half-configured credentials. useCache: false, because
  // publishing a version overwrites the same pathname and a cached read would serve the old DMG.
  const blob = await get(RELEASE_PATHNAME, {
    access: "private", token: process.env.BLOB_READ_WRITE_TOKEN, useCache: false,
  }).catch(() => null);
  const ready = Boolean(blob && blob.statusCode === 200);
  if (check) {
    if (blob?.stream) await blob.stream.cancel().catch(() => {});
    return reply(200, { paid: true, ready }, true);
  }
  if (!ready) {
    return reply(503, "The file isn’t online right now: write to nicolas@rewolf.studio. Le fichier n’est pas en ligne pour l’instant : écris à nicolas@rewolf.studio.");
  }
  return new Response(blob.stream, {
    status: 200,
    headers: {
      "Content-Type": "application/x-apple-diskimage",
      "Content-Disposition": `attachment; filename="${DOWNLOAD_NAME}"`,
      ...(blob.blob.size ? { "Content-Length": String(blob.blob.size) } : {}),
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex",
    },
  });
}
