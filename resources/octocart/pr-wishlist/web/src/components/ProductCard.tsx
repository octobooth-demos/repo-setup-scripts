import type { Product } from '../api/types';
import { formatMoney } from '../lib/money';

interface Props {
  product: Product;
  onAdd: (product: Product) => void;
  canAdd: boolean;
  onSave?: (product: Product) => void;
}

export function ProductCard({ product, onAdd, canAdd, onSave }: Props) {
  const soldOut = product.stock === 0;
  const headingId = `product-${product.id}`;

  return (
    <article className="product-card" aria-labelledby={headingId}>
      <span className="product-image" role="img" aria-label={product.imageAlt}>
        {product.image}
      </span>
      {onSave && (
        <div
          className="save-heart"
          role="button"
          tabIndex={0}
          title="Save for later"
          onClick={() => onSave(product)}
          onKeyDown={(e) => e.key === 'Enter' && onSave(product)}
        >
          ♡
        </div>
      )}
      <h3 id={headingId}>{product.name}</h3>
      <p className="product-description">{product.description}</p>
      <p className="product-price">{formatMoney(product.price)}</p>
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
