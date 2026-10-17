# feed

Publishes each parody index's price to its `IndexOracle`, and serves the same
numbers read-only over HTTP so both front ends can render a price without an
archive node.

## What it publishes, and why it is a transform

A free market-data tier is delayed deliberately — the delay is how a provider
avoids exchange licensing fees — and nearly all of them forbid
**redistribution**. Publishing a raw quote on chain is republishing market
data, which is a licence question rather than a technical one.

So this service publishes a **derived index** over an openly licensed source:
a weighted basket of public crypto prices from CoinGecko's keyless endpoint,
expressed as growth from a base of 100. The indices are parodies — `GOLOGGLE`,
`AMEZON` — and nothing here claims to track any real company. The transform is
`indices.ts`, in full, including the base measurement and its date.

**The deterministic fallback.** When the source fails, the service publishes a
seeded series instead, and labels every answer with its origin (`source` or
`synthetic`) in the log and on `/prices`. It is the same series on every run,
so a filmed demo is reproducible. A synthetic price is never presented as a
real one.

## Publishing policy

| | |
|---|---|
| Every `INTERVAL_SECONDS` | look at the price |
| Moved more than `THRESHOLD_BPS` | publish early, so a quiet market does not burn gas |
| `HEARTBEAT_SECONDS` elapsed | publish anyway, so consumers never see a stale feed |
| Moved further than the oracle's immutable bound | publish the bound, walking the price over several rounds rather than dropping the update |
| Feed paused by its guardian | publish nothing, and say so |

## The key

This process signs transactions, so it is a hot wallet by definition. What
bounds the damage is **which** key: the publisher holds `PUBLISHER_ROLE` and
nothing else. It cannot pause the feed (a separate guardian), cannot move fees
(a separate treasurer), and cannot widen a bound (immutable). A compromised
publisher can walk the price inside the per-round bound, which is finding M-1
in the audit report. **Keep only gas on it.**

The key comes from `PUBLISHER_PRIVATE_KEY` in the environment, which in
production means a systemd `EnvironmentFile` at mode 0600 — never a command
line, where it would appear in `ps` and in shell history, and never a file in
this repository.

## Run

```sh
cp .env.example .env     # then fill it in; .env is git-ignored
npm install
npm test                 # pure functions: the transform and the publish policy
npm start
```

Endpoints: `GET /prices` and `GET /healthz`. Both report the **chain id**,
and `/prices` also reports the chain's name, the RPC host (the host only: an
RPC URL can carry a token in its path and this response is public) and whether
the series is synthetic.

That exists because two feeds can run at once — a local rehearsal and the real
one — answering the same path on the same port. Without the chain in the
response, telling them apart means noticing that a round number looks
implausible, which is the kind of inference a status endpoint should spare you.
The startup line says the same thing, and a port already in use now says so
plainly instead of throwing.

## Deploy

`deploy/leek-feed.service` is a hardened systemd unit: no new privileges, a
read-only filesystem, no access to home directories, and a system-call filter.
That is not decoration — the process holds a signing key, so if it is ever
compromised the blast radius should be that key and not the host.

```sh
sudo install -D -m 0644 deploy/leek-feed.service /etc/systemd/system/leek-feed.service
sudo install -D -m 0600 /dev/null /etc/leek-stocks/feed.env   # then edit it
sudo systemctl enable --now leek-feed
```
