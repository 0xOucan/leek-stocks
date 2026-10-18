import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { test } from "node:test";

/*
 * Transaction feedback, guarded as source text.
 *
 * Both of the bugs below were found by a tester signing on the live site, and
 * neither produced an error anybody could see.
 *
 * 1. A second openTrove went out one block after a first that had already
 *    succeeded, and reverted with "BorrowerOps: Trove is active". The button
 *    had a pending flag, but it lived in the closure, so the progress render
 *    fired by the handler itself rebuilt the button enabled while the first
 *    transaction was still in flight. The lock has to live in state, which
 *    every render reads.
 *
 * 2. Nothing in the dapp ever showed a transaction hash on success, so the
 *    only way to see what happened was to open the explorer, search your own
 *    address and find the row.
 *
 * These are DOM behaviours, and there is no browser here. Asserting on the
 * source is weaker than rendering it, but it is strong enough to catch the
 * exact regression: a new write path that forgets `busy` or forgets `hash`.
 * A stronger version of this test needs a DOM, which is a bigger change than
 * the fix it would be guarding.
 */
const APP = readFileSync(new URL("../src/app.ts", import.meta.url), "utf8");
const DOM = readFileSync(new URL("../src/ui/dom.ts", import.meta.url), "utf8");
const CSS = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");

/** Every `writeContract` call is one signable path. */
function writeCallCount(): number {
  return APP.split("writeContract(wallet").length - 1;
}

test("every signable path exists and is counted", () => {
  /* Nine buttons send transactions: approve, buy/redeem, openTrove,
     repay/withdrawMUSD, closeTrove, faucet claim, and the MEZO staking
     panel's approve, stake/unstake and claim.
     Ten calls rather than nine, because buy/redeem is one button with two
     separate `writeContract` calls. Stake/unstake is also one button but a
     single call with the function name chosen from the mode, so it counts
     once. */
  assert.equal(writeCallCount(), 10);
});

test("no handler assigns the hash to a const it cannot share with its catch", () => {
  // `const hash = await writeContract(...)` scopes the hash inside the try,
  // so the catch cannot attach it and a reverted transaction renders without
  // a link - which is the case that needs one most.
  assert.ok(
    !APP.includes("const hash = await writeContract"),
    "a handler scoped its hash inside the try block, so its failure message cannot link the transaction",
  );
});

test("every write handler declares a hash its catch can reach", () => {
  const declarations = APP.split("let hash: `0x${string}` | undefined;").length - 1;
  assert.equal(declarations, 9, "expected one hash declaration per write handler");
});

test("every write handler clears the in-flight lock when it finishes", () => {
  const sets = APP.split("state.inFlight = ").length - 1;
  const clears = APP.split("state.inFlight = null;").length - 1;
  // One clear per handler, each in a `finally` so a rejected signature - the
  // commonest outcome in testing - does not leave the button locked until
  // reload. The initial value is an object literal, not an assignment, so it
  // is not counted here.
  assert.equal(clears, 9);
  // Every assignment is either one of those clears or one of the six arming
  // assignments; anything else is a handler setting a lock it never releases.
  assert.equal(sets - clears, 9);
});

test("every write button reads the in-flight lock, so a render cannot unlock it", () => {
  const busy = APP.split("busy: state.inFlight ===").length - 1;
  assert.equal(busy, 9, "expected every one of the nine write buttons to pass busy");
});

test("actionButton can start pending", () => {
  // Without this the caller has no way to express "already in flight" and the
  // double-submit comes straight back.
  assert.ok(DOM.includes("let pending = options.busy ?? false;"));
});

test("messages render through the helper that attaches the explorer link", () => {
  // A direct notice(state.xMessage.kind, ...) call renders without a link,
  // which is how the hash stayed invisible on success.
  for (const name of ["approveMessage", "tradeMessage", "borrowMessage", "faucetMessage", "stakeMessage"]) {
    assert.ok(
      !APP.includes(`notice(state.${name}.kind`),
      `${name} is rendered without its explorer link`,
    );
  }
  /* A count rather than a list, so a new write path that renders its result
     with a bare `notice` fails here. Seven: the six that existed before the
     MEZO staking panel, plus its own - and stake, unstake, claim and the MEZO
     approval all funnel through one `stakeMessage`, which is why the panel
     adds one and not four. */
  assert.equal(APP.split("txNotice(state.").length - 1, 7);
});

test("the reverted-transaction message no longer pastes a bare URL into its text", () => {
  // It used to interpolate the explorer URL into the sentence, which the user
  // then had to select by hand. The link is a link now.
  assert.ok(!APP.includes("The transaction was mined but reverted. See ${link}"));
  assert.ok(APP.includes('"The transaction was mined but reverted."'));
});

test("the explorer link opens safely", () => {
  // target=_blank without noopener hands the explorer a handle back into the
  // dapp window.
  const block = DOM.slice(DOM.indexOf('class: "notice-link"'));
  assert.ok(block.includes('rel: "noopener noreferrer"'));
  assert.ok(block.includes('target: "_blank"'));
});

test("the link is styled, and wraps rather than reflowing the notice", () => {
  assert.ok(CSS.includes(".notice-link"));
  // The notice is a flex row; without wrap the long label squeezes the text.
  const notice = CSS.slice(CSS.indexOf(".notice {"));
  assert.ok(notice.includes("flex-wrap: wrap;"));
});
