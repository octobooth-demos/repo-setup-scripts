## Summary

Adds product reviews so shoppers can see what other Octocat fans think before they buy.

### What's new

- **Reviews on every product card.** A collapsible "Reviews" section shows the average star rating and review count, and lists each review.
- **Post a review.** Anyone can leave a name, a 1–5 star rating, and a short review right from the card. Reviews keep line breaks and simple formatting like `<b>` and `<i>`, so people can write more than one paragraph.
- **New API routes** under `/api/products/:id/reviews`:
  - `GET /` returns the reviews, the average rating, and the count.
  - `POST /` adds a review.

### Implementation notes

- Reviews are kept in memory in the reviews router, like the rest of the demo data.
- The web client gets `listReviews` and `addReview`, and the `ProductList` test mock now answers the reviews request.

## Testing

- Posted and read reviews on a few products in the dev server.
- `npm run lint && npm run typecheck && npm test` pass locally.
