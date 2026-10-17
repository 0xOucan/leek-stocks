/**
 * Which step a new visitor is on, computed from chain state alone.
 *
 * The flow has a hard dependency chain - you cannot buy without MUSD, you
 * cannot borrow MUSD without BTC for collateral and gas, and you cannot hold
 * BTC without the faucet - and every link in it used to be a sentence in a
 * runbook or a shell script of mine. A tester who does not know the order
 * tries to buy, is told "you hold 0 MUSD", and has nowhere to go.
 *
 * So the order is derived rather than written down: each step owns a
 * predicate over balances, the first unsatisfied one is where the user is,
 * and the page points at exactly that. Import-free so it can be tested.
 */

export type StepId = "connect" | "network" | "gas" | "borrow" | "buy" | "redeem";
export type StepState = "done" | "current" | "todo";

export interface OnboardingInput {
  readonly connected: boolean;
  readonly onRightChain: boolean;
  /** Native gas balance in wei. */
  readonly native: bigint;
  readonly musd: bigint;
  readonly shares: bigint;
  /** Whether Mezo's borrow market already has a position for this address. */
  readonly hasTrove: boolean;
  /** Enough BTC to post collateral and still pay gas. */
  readonly minNative: bigint;
  /** Enough MUSD to be worth a buy. */
  readonly minMusd: bigint;
}

export interface OnboardingStep {
  readonly id: StepId;
  readonly title: string;
  readonly state: StepState;
  /** One line, in the imperative, saying what to do or what happened. */
  readonly detail: string;
  /**
   * Whether this step is setup or is the product.
   *
   * Buying and redeeming are not things a user finishes and moves past -
   * they are what the page is for. Counting them as onboarding meant a
   * wallet holding BTC and MUSD, which is ready to trade and needs no
   * instructions, was still shown a tutorial telling it to buy something.
   */
  readonly setup: boolean;
}

/**
 * Every step, in order, with exactly one marked `current`.
 *
 * `redeem` is never `done`: selling is not a milestone a user passes, it is
 * the thing the whole flow exists to make possible. When it is `current`,
 * onboarding is over - see `isComplete`.
 */
export function onboardingSteps(input: OnboardingInput): readonly OnboardingStep[] {
  const { connected, onRightChain, native, musd, shares, hasTrove, minNative, minMusd } = input;

  const done: Record<Exclude<StepId, "redeem">, boolean> = {
    connect: connected,
    network: connected && onRightChain,
    // A funded wallet that has already spent its BTC on collateral has still
    // done this step: the trove is the proof, and sending someone back to the
    // faucet because their balance is now low would be a loop.
    gas: connected && onRightChain && (native >= minNative || hasTrove),
    /* Shares count too. Someone who arrived with MUSD from elsewhere and
       spent all of it on shares has no trove and no MUSD left, and sending
       them back to the borrow step would be telling a user who has already
       done more than this asks to start over. */
    borrow: connected && onRightChain && (musd >= minMusd || hasTrove || shares > 0n),
    buy: connected && onRightChain && shares > 0n,
  };

  const spec: readonly { id: StepId; title: string; todo: string; done: string; setup: boolean }[] = [
    {
      id: "connect",
      setup: true,
      title: "Connect a wallet",
      todo: "Pick a wallet above. Nothing is sent and no transaction is signed by connecting.",
      done: "Connected.",
    },
    {
      id: "network",
      setup: true,
      title: "Switch to Mezo Testnet",
      todo: "Your wallet is on another chain. The button adds Mezo Testnet if it is missing.",
      done: "On Mezo Testnet.",
    },
    {
      id: "gas",
      setup: true,
      title: "Claim test BTC",
      todo: "Mezo charges gas in BTC, not ether, and the same BTC is the collateral you borrow against. The faucet is free and takes one click.",
      done: hasTrove && native < minNative ? "Spent on collateral, which is what it was for." : "You hold BTC for gas and collateral.",
    },
    {
      id: "borrow",
      setup: true,
      title: "Borrow MUSD against your BTC",
      todo: "This page settles in MUSD and mints none of it. Mezo's own borrow market does: lock BTC, receive MUSD, repay later to get the BTC back.",
      done: "You hold MUSD.",
    },
    {
      id: "buy",
      setup: false,
      title: "Buy index shares",
      todo: "Approve the MUSD, then buy. Both steps are below and the page only ever offers you the next one.",
      done: "You hold shares.",
    },
    {
      id: "redeem",
      setup: false,
      title: "Redeem whenever you like",
      todo: "Shares burn back to MUSD at the oracle price, less the same fee. The vault's cover is on screen before you commit.",
      done: "",
    },
  ];

  let currentTaken = false;
  return spec.map((step) => {
    const isDone = step.id === "redeem" ? false : done[step.id as Exclude<StepId, "redeem">];
    let state: StepState = "todo";
    if (isDone) {
      state = "done";
    } else if (!currentTaken) {
      state = "current";
      currentTaken = true;
    }
    return {
      id: step.id,
      title: step.title,
      state,
      detail: state === "done" ? step.done : step.todo,
      setup: step.setup,
    };
  });
}

/**
 * True once every setup step is behind the user: on the right chain, with gas,
 * and with something to spend.
 *
 * This is the test for hiding the panel entirely, and it deliberately does
 * NOT require that anything has been bought. A wallet holding BTC and MUSD
 * can use every control on the page; a tutorial above it is then just
 * furniture, and the first thing it says - "you are here: buy index
 * shares" - is a step the trade form already asks for in its own words.
 */
export function isSetUp(steps: readonly OnboardingStep[]): boolean {
  return steps.every((step) => !step.setup || step.state === "done");
}

/** How many setup steps there are, and how many are done. Never counts buying. */
export function setupProgress(steps: readonly OnboardingStep[]): { done: number; total: number } {
  const setup = steps.filter((step) => step.setup);
  return { done: setup.filter((step) => step.state === "done").length, total: setup.length };
}

export function currentStep(steps: readonly OnboardingStep[]): OnboardingStep | null {
  return steps.find((step) => step.state === "current") ?? null;
}
