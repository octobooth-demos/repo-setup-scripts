import { useEffect, useState } from 'react';
import { api } from '../api/client';
import type { Product } from '../api/types';
import { useAuth } from '../context/AuthContext';
import { useCart } from '../context/CartContext';
import { ProductCard } from './ProductCard';
import { WISHLIST_CHANGED } from './Wishlist';

export function ProductList() {
  const { token } = useAuth();
  const { addItem, loading } = useCart();
  const [products, setProducts] = useState<Product[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.listProducts().then(setProducts, (err: Error) => setError(err.message));
  }, []);

  async function saveForLater(product: Product) {
    await fetch('/api/wishlist', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ productId: product.id }),
    });
    window.dispatchEvent(new Event(WISHLIST_CHANGED));
  }

  if (error) return <p role="alert">Could not load products: {error}</p>;
  if (!products) return <p aria-busy="true">Loading products…</p>;

  return (
    <section aria-labelledby="products-heading">
      <h2 id="products-heading">Octocat merch</h2>
      {!token && <p className="hint">Sign in to start adding items to your cart.</p>}
      <div className="product-grid">
        {products.map((product) => (
          <ProductCard
            key={product.id}
            product={product}
            canAdd={Boolean(token) && !loading}
            onAdd={(p) => void addItem(p.id, p.name)}
            onSave={token ? (p) => void saveForLater(p) : undefined}
          />
        ))}
      </div>
    </section>
  );
}
