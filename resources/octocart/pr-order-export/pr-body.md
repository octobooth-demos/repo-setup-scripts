## Summary

Customers keep asking where to find their past orders, and finance wants an easy way to pull a customer's purchase history for expense reports. This PR adds an order history panel and a CSV export.

### What's new

- **Order history panel.** Signed-in shoppers see a "Your orders" table under checkout, newest order first, showing the date, item count, and total.
- **CSV export.** `GET /api/orders/export.csv` returns one row per order line (order id, date, product, category, quantity, unit price, line total, order total, ship-to), and the panel links to it as a download.
- **Pagination params.** `GET /api/orders` now returns orders newest-first and accepts optional `limit` / `offset` query parameters. The response also includes a `total` count.
- **Support exports.** Support staff can pass `?userId=` to export a specific customer's history when they're helping with a ticket.

### Implementation notes

- Plain download links can't send an `Authorization` header, so `requireAuth` now also accepts the session token as an `access_token` query parameter.
- `api.listOrders()` and `api.ordersExportUrl()` were added to the web API client.

## Testing

- New API test covering the CSV export's headers and row format.
- `npm run lint && npm run typecheck && npm test` pass locally.
- Manually placed two orders and opened the downloaded CSV in Numbers and Excel.
