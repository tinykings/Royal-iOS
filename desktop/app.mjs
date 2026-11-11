const status = document.querySelector("#status");

async function run(request) {
  const buttons = [...document.querySelectorAll("#tab-icloud button")];
  buttons.forEach(button => { button.disabled = true; });
  status.textContent = "Working…";
  try {
    const result = await chrome.runtime.sendMessage(request);
    status.textContent = result.message ?? (result.ok ? "Ready. Save configuration, then sign in." : "Operation failed.");
    return result;
  } catch {
    status.textContent = "Could not reach the Royal extension worker. Reload this page and try again.";
  } finally { buttons.forEach(button => { button.disabled = false; }); }
}

document.querySelector("#configuration").addEventListener("submit", event => {
  event.preventDefault();
  run({ action: "configure", config: Object.fromEntries(new FormData(event.target)) });
});
document.querySelector("#sign-in").addEventListener("click", () => run({ action: "signIn" }));
document.querySelector("#sign-out").addEventListener("click", () => run({ action: "signOut" }));
document.querySelector("#diagnose").addEventListener("click", () => run({ action: "diagnose" }));

const result = await run({ action: "status" });
if (result?.ok) {
  document.querySelector("#callback").textContent = result.callback;
  document.querySelector("#origin").textContent = result.origin;
  if (result.config) for (const [key, value] of Object.entries(result.config)) {
    document.querySelector("#configuration").elements.namedItem(key).value = value;
  }
}
