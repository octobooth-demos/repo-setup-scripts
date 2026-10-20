## Summary

Marketing wants to run a spring sale alongside the existing promo codes, and support has been fielding requests from customers who want to combine codes. This PR adds both.

### What's new

- **Sale pricing.** Products can carry an optional `salePercent`. The API applies it when building order lines, and the product card shows the sale price next to the original (struck-through) price. The water bottle (25% off) and socks (30% off) are seeded as the first sale items.
- **Stackable promo codes.** Checkout now accepts several codes separated by commas (for example `OCTO10, HUBBER20`). Their percentages are added together, and all applied codes are recorded on the order.
- **`FREESHIP` code.** A new code that waives shipping without changing the discount percentage.
- The checkout hint text now explains that codes can be combined.

### Implementation notes

- `applyPromoCodes()` in `api/src/lib/pricing.ts` parses the input and returns `{ percent, freeShipping, codes }`.
- `shippingFor()` and `calculateTotals()` take a new `freeShipping` flag.
- The 32-character limit on `promoCode` is gone, since a list of several codes can exceed it.

## Testing

- New unit tests in `api/test/pricing.test.ts` cover sale pricing, stacking two codes, and `FREESHIP`.
- `npm run lint && npm run typecheck && npm test` pass locally.
- Manually checked out with `OCTO10, HUBBER20` and with `FREESHIP` on a small cart.
