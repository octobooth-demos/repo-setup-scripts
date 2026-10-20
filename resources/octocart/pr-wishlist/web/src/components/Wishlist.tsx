import { useEffect, useState } from 'react';
import type { Product } from '../api/types';
import { useAuth } from '../context/AuthContext';

interface WishlistItem {
  productId: string;
  note?: string;
  addedAt: string;
  product: Product;
}

export const WISHLIST_CHANGED = 'wishlist:changed';

export function Wishlist() {
  const { token } = useAuth();
  const [items, setItems] = useState<WishlistItem[]>([]);
  const [total, setTotal] = useState('0.00');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!token) return;
    const load = () =>
      fetch('/api/wishlist', { headers: { Authorization: `Bearer ${token}` } })
        .then((res) => res.json())
        .then((body) => {
          setItems(body.items ?? []);
          setTotal(body.total ?? '0.00');
        })
        .catch(() => setError('Could not load your wishlist'));
    void load();
    window.addEventListener(WISHLIST_CHANGED, load);
    return () => window.removeEventListener(WISHLIST_CHANGED, load);
  }, [token]);

  async function send(path: string, method: string, body?: unknown) {
    await fetch(`/api/wishlist${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: body ? JSON.stringify(body) : undefined,
    });
    window.dispatchEvent(new Event(WISHLIST_CHANGED));
  }

  if (!token) return null;

  return (
    <section className="wishlist">
      <h2>Saved for later</h2>
      {error && <p className="error">{error}</p>}
      {items.length === 0 ? (
        <p className="hint">Tap the heart on any product to save it for later.</p>
      ) : (
        <ul className="wishlist-items">
          {items.map((item) => (
            <li key={item.productId}>
              <span aria-hidden="true">{item.product.image}</span> {item.product.name} — $
              {(item.product.price / 100).toFixed(2)}
              <input
                type="text"
                placeholder="Add a note"
                defaultValue={item.note}
                onBlur={(e) =>
                  void send('', 'POST', { productId: item.productId, note: e.target.value })
                }
              />
              <button
                type="button"
                onClick={() => void send(`/${item.productId}/move-to-cart`, 'POST')}
              >
                Move to cart
              </button>
              <button type="button" onClick={() => void send(`/${item.productId}`, 'DELETE')}>
                ✕
              </button>
            </li>
          ))}
        </ul>
      )}
      <p className="wishlist-total">Saved items total: ${total}</p>
    </section>
  );
}
