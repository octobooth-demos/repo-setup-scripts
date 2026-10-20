import { useEffect, useState, type FormEvent } from 'react';
import { api } from '../api/client';
import type { Product, ReviewSummary } from '../api/types';

interface Props {
  product: Product;
}

export function ProductReviews({ product }: Props) {
  const [summary, setSummary] = useState<ReviewSummary | null>(null);
  const [author, setAuthor] = useState('');
  const [rating, setRating] = useState(5);
  const [body, setBody] = useState('');

  useEffect(() => {
    api.listReviews(product.id).then(setSummary, () => setSummary(null));
  }, [product.id]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    await api.addReview(product.id, { author, rating, body });
    setBody('');
    setSummary(await api.listReviews(product.id));
  }

  const formId = `review-${product.id}`;

  return (
    <details className="product-reviews">
      <summary>
        Reviews{summary && summary.count > 0 ? ` · ★ ${summary.average} (${summary.count})` : ''}
      </summary>
      <ul>
        {summary?.reviews.map((review) => (
          <li key={review.id}>
            <strong>{review.author}</strong> · {'★'.repeat(review.rating)}
            <p dangerouslySetInnerHTML={{ __html: review.body }} />
          </li>
        ))}
      </ul>
      <form onSubmit={(e) => void onSubmit(e)} aria-label={`Review ${product.name}`}>
        <label htmlFor={`${formId}-author`}>Name</label>
        <input id={`${formId}-author`} value={author} onChange={(e) => setAuthor(e.target.value)} />
        <label htmlFor={`${formId}-rating`}>Rating</label>
        <select
          id={`${formId}-rating`}
          value={rating}
          onChange={(e) => setRating(Number(e.target.value))}
        >
          {[5, 4, 3, 2, 1].map((n) => (
            <option key={n} value={n}>
              {n} ★
            </option>
          ))}
        </select>
        <label htmlFor={`${formId}-body`}>Review</label>
        <textarea id={`${formId}-body`} value={body} onChange={(e) => setBody(e.target.value)} />
        <button type="submit">Post review</button>
      </form>
    </details>
  );
}
