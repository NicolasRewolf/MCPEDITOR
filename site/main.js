// Payment link from the provider (Lemon Squeezy, Paddle or Stripe), shared by both languages.
// Empty = sales not open yet.
const CHECKOUT_URL = "";

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
