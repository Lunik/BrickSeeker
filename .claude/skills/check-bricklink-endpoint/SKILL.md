---
name: check-bricklink-endpoint
description: Verify the real response shape of a BrickLink Store API endpoint with a signed probe call, before implementing or trusting code against it. Use before decoding any new BrickLink field or endpoint — the sibling skill check-rebrickable-endpoint does not cover BrickLink.
---

# Verifying a BrickLink Store API endpoint

BrickLink publishes **no machine-readable spec** — no OpenAPI/swagger document, not even the
partial one Rebrickable offers. Its HTML reference (`bricklink.com/v3/api.page`) is rendered
client-side and returns an empty shell to any fetcher, and third-party client libraries encode
their authors' assumptions, not a contract. Every endpoint is also OAuth 1.0a signed, so you
cannot poke at one with a bare `curl`.

That combination means the only trustworthy source for "what does this actually return" is a real
signed call. `probe.py` makes one.

## Run the probe

Credentials are the four values from the developer's own bricklink.com/v3/api.page account (the
same ones the app stores in the Keychain, `KeychainService.brickLinkOAuth1Credentials`). They come
from the environment and are never printed by the script:

```bash
export BL_CONSUMER_KEY=... BL_CONSUMER_SECRET=... BL_TOKEN=... BL_TOKEN_SECRET=...
python3 .claude/skills/check-bricklink-endpoint/probe.py \
  --path /items/SET/10300-1/price \
  --query guide_type=sold new_or_used=U currency_code=EUR
```

Output is the response *shape* — every key, its type, a real value, and for arrays the entry count
plus two sample entries. Add `--raw` for the full payload. Stdlib only; no virtualenv, no install.

Pick an item that will actually have data: a popular, long-retired set (`10300-1`) has months of
sales, while an obscure or brand-new one legitimately returns empty arrays and zeroed prices —
which proves nothing about the shape.

**Paste the shape into the issue** before writing the decoder. That is the record that the fields
were seen, not assumed.

## Before writing code against what you found

- **A field being present once is not a guarantee it always is.** `price_detail[]` is empty for an
  item with no sales in the window, and BrickLink returns `"0.0000"` rather than omitting a price
  it has no data for — treat "present but zero" as absent (see `PriceGuideData` in
  `BrickLinkPriceRepository.swift`).
- **Prices are strings, quantities are numbers.** `min_price`/`max_price`/`avg_price`/
  `qty_avg_price` come back as decimal *strings* (`"12.3400"`); `unit_quantity`/`total_quantity`
  are JSON numbers. Don't decode a price as `Double`.
- **Keep secondary fields optional and decode them defensively.** A strict synthesised `Decodable`
  throws the entire payload away over one unexpected key type, which would cost the app the
  average price it already displays for the sake of a decoration. `PriceGuideData` has a
  hand-written `init(from:)` for exactly this reason.
- **`guide_type` changes the meaning, not just the numbers.** `sold` is the last-6-months sales
  guide (what the app has always shown); `stock` is current listings, and `price_detail[]` carries
  different fields for each (`date_ordered` on sold, `shipping_available` on stock). Switching it
  silently redefines `DealVerdict` and every stored history point — see AGENTS.md.
