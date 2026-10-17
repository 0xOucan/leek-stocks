import { strict as assert } from "node:assert";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { test } from "node:test";

/*
 * Every font the stylesheet asks for must exist in public/.
 *
 * This is here because two of them did not. The palette pass declared
 * @font-face rules for Space Grotesk 600 and 700 and nobody copied the files
 * out of @fontsource into public/fonts, so every page load fetched two woff2
 * files that were not there and the wordmark silently fell back to system-ui.
 * It looked fine, which is the problem: a missing font is not an error, it is
 * a substitution, and the only signal is two 404s in a network panel nobody
 * had open.
 *
 * The CSP serves fonts from 'self' with no Google origins, so a font that is
 * not in this directory cannot be loaded from anywhere else. That makes the
 * directory the whole contract, and this test the thing that checks it.
 */
const CSS = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");

function referencedFonts(): string[] {
  return [...CSS.matchAll(/url\("(\/fonts\/[^"]+)"\)/g)].map((match) => match[1] as string);
}

test("the stylesheet references at least one font, so this test cannot pass vacuously", () => {
  assert.ok(referencedFonts().length > 0);
});

test("every font the stylesheet references is present in public/", () => {
  const missing = referencedFonts().filter(
    (href) => !existsSync(new URL(`../public${href}`, import.meta.url)),
  );
  assert.deepEqual(missing, [], `declared in @font-face but not in public/fonts: ${missing.join(", ")}`);
});

test("every font file in public/ is referenced, so none is dead weight", () => {
  /* The other direction. A woff2 nobody asks for is 15-30 kB shipped to every
     visitor for nothing, and it is the state the directory would drift into
     if a typeface were dropped from the design without being deleted. */
  const referenced = new Set(referencedFonts().map((href) => href.replace("/fonts/", "")));
  const present = readdirSync(new URL("../public/fonts", import.meta.url));
  const unused = present.filter((file) => !referenced.has(file));
  assert.deepEqual(unused, [], `in public/fonts but never referenced: ${unused.join(", ")}`);
});
