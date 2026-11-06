// Payment link from the provider (Lemon Squeezy, Paddle or Stripe), shared by both languages.
// Empty = sales not open yet.
const CHECKOUT_URL = "";

document.querySelectorAll(".js-buy").forEach((button) => {
  if (CHECKOUT_URL) {
    button.href = CHECKOUT_URL;
    return;
  }
  button.addEventListener("click", (event) => {
    if (button.closest(".price-card")) event.preventDefault();
    document.querySelectorAll(".js-sale-note").forEach((note) => {
      note.textContent = document.documentElement.lang === "fr"
        ? "La vente n’est pas encore ouverte."
        : "Sales aren’t open yet.";
    });
  });
});

const root = document.documentElement;
const toggle = document.getElementById("theme");
try {
  const saved = localStorage.getItem("theme");
  if (saved) root.dataset.theme = saved;
} catch (e) {}
toggle.addEventListener("click", () => {
  const dark = root.dataset.theme
    ? root.dataset.theme === "dark"
    : matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = dark ? "light" : "dark";
  try { localStorage.setItem("theme", root.dataset.theme); } catch (e) {}
});
