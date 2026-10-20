import type { Product } from '../api/types';
import { formatMoney } from '../lib/money';

interface Props {
  product: Product;
  onAdd: (product: Product) => void;
  canAdd: boolean;
}

export function ProductCard({ product, onAdd, canAdd }: Props) {
  const soldOut = product.stock === 0;
  const salePrice = product.salePercent
    ? Math.round(product.price * (1 - product.salePercent / 100))
    : null;
  const headingId = `product-${product.id}`;

  return (
    <article className="product-card" aria-labelledby={headingId}>
      <span className="product-image" role="img" aria-label={product.imageAlt}>
        {product.image}
      </span>
      <h3 id={headingId}>{product.name}</h3>
      <p className="product-description">{product.description}</p>
      <p className="product-price">
        {salePrice === null ? (
          formatMoney(product.price)
        ) : (
          <>
            <s>{formatMoney(product.price)}</s> {formatMoney(salePrice)}{' '}
            <span className="sale-badge">{product.salePercent}% off</span>
          </>
        )}
      </p>
      <button
        type="button"
        onClick={() => onAdd(product)}
        disabled={!canAdd || soldOut}
        aria-label={`Add ${product.name} to cart`}
      >
        {soldOut ? 'Sold out' : 'Add to cart'}
      </button>
    </article>
  );
}
