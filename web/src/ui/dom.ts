/**
 * The whole view layer: element construction, and one button that owns its
 * own pending state.
 *
 * No framework and no virtual DOM. Each section has a render function that
 * replaces its own subtree, which is cheap because the subtrees are a few
 * dozen nodes, and it keeps the memory profile flat on a page that polls
 * every five seconds.
 */

export type Attrs = Record<string, string | number | boolean | undefined>;

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Attrs = {},
  children: (Node | string | null | undefined)[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === false) continue;
    if (key === "class") node.className = String(value);
    else if (value === true) node.setAttribute(key, "");
    else node.setAttribute(key, String(value));
  }
  for (const child of children) {
    if (child === null || child === undefined) continue;
    node.append(typeof child === "string" ? document.createTextNode(child) : child);
  }
  return node;
}

export function clear(node: Element): void {
  node.replaceChildren();
}

/** SVG only, never an emoji: an emoji is a font-dependent glyph that a screen reader reads aloud as a word. */
export function icon(path: string, label?: string): SVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.8");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("class", "icon");
  if (label) {
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", label);
  } else {
    svg.setAttribute("aria-hidden", "true");
  }
  const d = document.createElementNS("http://www.w3.org/2000/svg", "path");
  d.setAttribute("d", path);
  svg.append(d);
  return svg;
}

export const ICONS = {
  copy: "M8 8V5a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-3M5 8h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2Z",
  external: "M14 4h6v6M20 4l-9 9M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4",
  warning: "M12 4 2.5 20h19L12 4ZM12 10v5M12 17.5v.5",
  check: "M4 12.5 9.5 18 20 6.5",
};

export interface ActionButton {
  readonly element: HTMLButtonElement;
  /** Set when something other than this action is the next step. */
  setBlocked(reason: string | null): void;
}

/**
 * A button that disables itself for the life of its own promise.
 *
 * Each button carries its own pending flag rather than reading a shared
 * `isLoading`, because with one flag an approval in flight greys out the buy
 * button too, and the user cannot tell which of the two is working. The
 * release is in `finally`, so a rejected signature - by far the most common
 * outcome in testing - leaves the button usable instead of locked until
 * reload.
 */
export function actionButton(options: {
  label: string;
  pendingLabel: string;
  variant?: "primary" | "secondary" | "ghost";
  onClick: () => Promise<void>;
}): ActionButton {
  const labelNode = el("span", { class: "button-label" }, [options.label]);
  const spinner = el("span", { class: "spinner", "aria-hidden": "true" });
  const button = el("button", {
    type: "button",
    class: `button button-${options.variant ?? "primary"}`,
  }, [spinner, labelNode]);

  let pending = false;
  let blocked: string | null = null;

  const sync = (): void => {
    button.disabled = pending || blocked !== null;
    button.classList.toggle("is-pending", pending);
    // aria-busy rather than only a spinner: the spinner is a visual cue and a
    // screen reader needs the state said out loud.
    button.setAttribute("aria-busy", pending ? "true" : "false");
    labelNode.textContent = pending ? options.pendingLabel : options.label;
    if (blocked && !pending) button.title = blocked;
    else button.removeAttribute("title");
  };

  button.addEventListener("click", () => {
    if (pending || button.disabled) return;
    pending = true;
    sync();
    void options
      .onClick()
      .catch(() => {
        /* The caller renders the message; swallowed here so one failed click
           cannot become an unhandled rejection that kills the handler. */
      })
      .finally(() => {
        pending = false;
        sync();
      });
  });

  sync();
  return {
    element: button,
    setBlocked(reason: string | null) {
      blocked = reason;
      sync();
    },
  };
}

/** Truncated, copyable, linked. Never a raw 42-character hex run. */
/**
 * An address, truncated, with copy and an optional explorer link.
 *
 * The link is optional because a local chain has no explorer, and offering one
 * sends the reader to a "not found" page that reads as the address not
 * existing. Copy always works, so the chip is still useful without it.
 */
export function addressChip(address: string, truncated: string, explorerUrl?: string): HTMLElement {
  const copy = el("button", {
    type: "button",
    class: "chip-action",
    "aria-label": `Copy address ${address}`,
  }, [icon(ICONS.copy)]);
  const copied = el("span", { class: "chip-copied", role: "status", "aria-live": "polite" });
  copy.addEventListener("click", () => {
    void navigator.clipboard
      .writeText(address)
      .then(() => {
        copied.textContent = "copied";
        window.setTimeout(() => (copied.textContent = ""), 1500);
      })
      .catch(() => (copied.textContent = "copy failed"));
  });
  const children: (HTMLElement | string)[] = [el("span", { class: "mono" }, [truncated]), copy];
  if (explorerUrl !== undefined) {
    children.push(
      el("a", {
        class: "chip-action",
        href: explorerUrl,
        target: "_blank",
        rel: "noopener noreferrer",
        "aria-label": `View ${address} on the block explorer`,
      }, [icon(ICONS.external)]),
    );
  }
  children.push(copied);
  return el("span", { class: "chip", title: address }, children);
}

/** An inline message, next to the control that caused it. */
export function notice(kind: "error" | "warning" | "ok", text: string, name?: string): HTMLElement {
  return el("p", {
    class: `notice notice-${kind}`,
    role: kind === "error" ? "alert" : "status",
    "data-error": name,
  }, [icon(kind === "ok" ? ICONS.check : ICONS.warning), el("span", {}, [text])]);
}

/** A labelled figure. The value is mono so two of them line up digit for digit. */
/**
 * @param extra the full-precision value, as a tooltip on the rounded one.
 * @param sub a second line under the value - what it is worth, or why it has
 *        no worth to show. A figure in index points or in a token nobody
 *        prices in their head is not yet information.
 */
export function stat(label: string, value: string, extra?: string, sub?: string): HTMLElement {
  const children = [
    el("span", { class: "stat-label" }, [label]),
    el("span", { class: "stat-value mono", title: extra }, [value]),
  ];
  if (sub !== undefined) children.push(el("span", { class: "stat-sub muted small" }, [sub]));
  return el("div", { class: "stat" }, children);
}

/**
 * Run a re-render without stealing the caret.
 *
 * Every section here rebuilds its own subtree, which is cheap and keeps the
 * render functions trivial - but a poll that fires while someone is typing
 * replaces the input element under them. The text survives, because it is
 * read back out of state, and the focus and the cursor position do not: the
 * caret jumps to the end, or out of the field entirely, every five seconds.
 * On a form where the amount is the whole decision, that is the difference
 * between a page that feels alive and one that fights you.
 *
 * So: remember which field had focus and where its cursor was, by `id`
 * because the element itself is about to be discarded, and put both back
 * afterwards. Restored only if the field still exists and the user has not
 * moved on in the meantime - re-focusing a field someone has deliberately
 * left would be the same rudeness in the other direction.
 */
export function preservingFocus(render: () => void): void {
  const active = document.activeElement;
  const isField = active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement;
  const id = isField ? active.id : "";
  const start = isField ? active.selectionStart : null;
  const end = isField ? active.selectionEnd : null;

  render();

  if (!isField || id === "") return;
  // Already elsewhere: the render did not take the focus, so nothing to give
  // back. Happens when a click moved focus to a button mid-poll.
  if (document.activeElement !== document.body && document.activeElement !== null) return;

  const restored = document.getElementById(id);
  if (!(restored instanceof HTMLInputElement || restored instanceof HTMLTextAreaElement)) return;
  restored.focus({ preventScroll: true });
  if (start !== null && end !== null) {
    try {
      restored.setSelectionRange(start, end);
    } catch {
      // Some input types refuse a selection range (number, email). The focus
      // is the part that matters; the caret lands at the end.
    }
  }
}
