// Stripe Payment Link (live, Managed Payments), shared by both languages.
// After payment Stripe redirects to /thanks/. Empty = sales not open yet.
const CHECKOUT_URL = "https://buy.stripe.com/bJe00le8mgyA8Ob0rCfAc00";

document.querySelectorAll(".js-buy").forEach((button) => {
  if (CHECKOUT_URL) {
    button.href = CHECKOUT_URL;
    return;
  }
  button.addEventListener("click", (event) => {
    event.preventDefault();
    document.querySelectorAll(".js-sale-note").forEach((note) => {
      note.textContent = document.documentElement.lang === "fr"
        ? "La vente n’est pas encore ouverte."
        : "Sales aren’t open yet.";
    });
  });
});
