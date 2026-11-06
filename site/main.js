// Stripe Payment Link (live, Managed Payments), shared by both languages.
// After payment Stripe redirects to /thanks/?key=<download code>.
// Empty = sales paused: the button stays visible and says why.
// Paused on 6 November 2026 until 0.9.2 (copy to SD fixed) is in the download store.
// To reopen: const CHECKOUT_URL = "https://buy.stripe.com/bJe00le8mgyA8Ob0rCfAc00";
const CHECKOUT_URL = "";

const PAUSED = document.documentElement.lang === "fr"
  ? "Vente en pause le temps d’une correction. De retour dans quelques jours."
  : "Sales are paused for a fix. Back in a few days.";

document.querySelectorAll(".js-buy").forEach((button) => {
  if (CHECKOUT_URL) {
    button.href = CHECKOUT_URL;
    return;
  }
  button.removeAttribute("href");
  button.setAttribute("aria-disabled", "true");
  const note = document.createElement("p");
  note.className = "small";
  note.textContent = PAUSED;
  button.closest("p").after(note);
});
