## Summary

Adds a wishlist so shoppers can save products for later. This was the most-requested feature in the last booth survey.

### What's new

- **Heart button on product cards.** Signed-in shoppers can tap ♡ on any product to save it.
- **"Saved for later" panel.** Shows up next to the cart and lists saved products with their prices, a short personal note per item, and the total value of everything saved.
- **Move to cart.** One click moves a saved item into the cart and removes it from the wishlist.
- **New API routes** under `/api/wishlist`:
  - `GET /` lists saved items (with product details) and the saved total.
  - `POST /` saves a product, or updates its note if it's already saved.
  - `DELETE /:productId` removes a product.
  - `POST /:productId/move-to-cart` moves a product into the cart.

### Implementation notes

- Wishlists live in the in-memory store next to carts, so they reset along with the rest of the demo data.
- The product list and the wishlist panel stay in sync through a small `wishlist:changed` window event, so no new context provider was needed.

## Testing

- Saved, annotated, moved, and removed items manually in the dev server.
- `npm run lint && npm run typecheck && npm test` pass locally.
