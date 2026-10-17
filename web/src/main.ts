/**
 * Entry point. Everything interesting is in app.ts; this exists so a failure
 * during mount is reported on the page rather than only in the console.
 */

import { mount } from "./app.ts";

try {
  mount();
} catch (error) {
  const root = document.querySelector("#app");
  if (root) {
    root.textContent = `This page failed to start: ${error instanceof Error ? error.message : String(error)}`;
  }
  throw error;
}
