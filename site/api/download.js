// Paid download for Kit for MPC3000.
//
// Stripe sends buyers to /thanks/?session_id={CHECKOUT_SESSION_ID}. This function asks Stripe
// whether that Checkout Session was paid through the Kit for MPC3000 Payment Link, then
// streams the DMG from a private Vercel Blob store. Nothing else is stored or logged.
//
//   GET /api/download?session_id=cs_...           the DMG, or a short plain-text refusal
//   GET /api/download?session_id=cs_...&check=1   {"paid": bool, "ready": bool} for /thanks/
//
// Needs two environment variables on the Vercel project:
//   STRIPE_SECRET_KEY      a restricted Stripe key with read access to Checkout Sessions
//   BLOB_READ_WRITE_TOKEN  added by Vercel when the private Blob store is connected
// The same session link keeps working, so a buyer gets later versions from the same page.
import { get } from "@vercel/blob";

const PAYMENT_LINK = "plink_1UYluHPc3KBNseSeyFyUCCtD";
const RELEASE_PATHNAME = "releases/Kit-for-MPC3000-Apple-Silicon.dmg";
const DOWNLOAD_NAME = "Kit-for-MPC3000-Apple-Silicon.dmg";
const SESSION_ID = /^cs_(live|test)_[A-Za-z0-9]{10,250}$/;

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

async function paidSession(id) {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) return { error: [503, "Downloads are not set up yet. Le téléchargement n’est pas encore en place."] };
  const response = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(id)}`, {
    headers: { Authorization: `Bearer ${key}` },
  });
  if (response.status === 404) return { paid: false };
  if (!response.ok) return { error: [502, "Stripe didn’t answer. Try again in a minute. Stripe n’a pas répondu, réessaie dans une minute."] };
  const session = await response.json();
  return { paid: session.payment_link === PAYMENT_LINK && session.payment_status === "paid" };
}

export async function GET(request) {
  const params = new URL(request.url).searchParams;
  const id = params.get("session_id") || "";
  const check = params.has("check");
  if (!SESSION_ID.test(id)) {
    return check ? reply(400, { paid: false, ready: false }, true)
                 : reply(400, "This link has no valid payment reference. Ce lien ne contient pas de référence de paiement valide.");
  }

  const session = await paidSession(id);
  if (session.error) {
    return check ? reply(session.error[0], { paid: false, ready: false, error: true }, true)
                 : reply(...session.error);
  }
  if (!session.paid) {
    return check ? reply(403, { paid: false, ready: false }, true)
                 : reply(403, "No completed payment for Kit for MPC3000 matches this link. Aucun paiement de Kit for MPC3000 ne correspond à ce lien.");
  }

  const blob = await get(RELEASE_PATHNAME, { access: "private" }).catch(() => null);
  const ready = Boolean(blob && blob.statusCode === 200);
  if (check) {
    if (blob?.stream) await blob.stream.cancel().catch(() => {});
    return reply(200, { paid: true, ready }, true);
  }
  if (!ready) {
    return reply(503, "Payment confirmed. The file isn’t online yet: the link comes by email. Paiement confirmé. Le fichier n’est pas encore en ligne : le lien arrive par mail.");
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
