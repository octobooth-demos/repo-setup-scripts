import { useState } from 'react';
import type { FormEvent } from 'react';
import type { Order, ShippingAddress } from '../api/types';
import { useCart } from '../context/CartContext';
import { formatMoney } from '../lib/money';

const EMPTY_ADDRESS: ShippingAddress = {
  name: '',
  line1: '',
  city: '',
  postalCode: '',
  country: 'US',
};

const FIELDS: { key: keyof ShippingAddress; label: string; autoComplete: string }[] = [
  { key: 'name', label: 'Full name', autoComplete: 'name' },
  { key: 'line1', label: 'Street address', autoComplete: 'address-line1' },
  { key: 'city', label: 'City', autoComplete: 'address-level2' },
  { key: 'postalCode', label: 'Postal code', autoComplete: 'postal-code' },
  { key: 'country', label: 'Country code', autoComplete: 'country' },
];

export function CheckoutForm() {
  const { cart, checkout } = useCart();
  const [address, setAddress] = useState<ShippingAddress>(EMPTY_ADDRESS);
  const [promoCode, setPromoCode] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [order, setOrder] = useState<Order | null>(null);

  if (order && cart.lines.length === 0) {
    return (
      <section aria-labelledby="confirmation-heading" className="confirmation">
        <h2 id="confirmation-heading">Thanks for your order! 🎉</h2>
        <p>
          Order <code>{order.id.slice(0, 8)}</code> is on its way to {order.shippingAddress.city}.
        </p>
        <dl className="totals">
          <dt>Subtotal</dt>
          <dd>{formatMoney(order.subtotal)}</dd>
          {order.discount > 0 && (
            <>
              <dt>Discount ({order.promoCode})</dt>
              <dd>−{formatMoney(order.discount)}</dd>
            </>
          )}
          <dt>Shipping</dt>
          <dd>{order.shipping === 0 ? 'Free' : formatMoney(order.shipping)}</dd>
          <dt>Total charged</dt>
          <dd>{formatMoney(order.total)}</dd>
        </dl>
      </section>
    );
  }

  if (cart.lines.length === 0) return null;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      setOrder(await checkout(address, promoCode.trim() || undefined));
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <section aria-labelledby="checkout-heading">
      <h2 id="checkout-heading">Checkout</h2>
      <form onSubmit={handleSubmit} className="checkout-form" noValidate={false}>
        <fieldset>
          <legend>Shipping address</legend>
          {FIELDS.map(({ key, label, autoComplete }) => (
            <div className="field" key={key}>
              <label htmlFor={`ship-${key}`}>{label}</label>
              <input
                id={`ship-${key}`}
                name={key}
                autoComplete={autoComplete}
                required
                value={address[key]}
                onChange={(e) => setAddress({ ...address, [key]: e.target.value })}
              />
            </div>
          ))}
        </fieldset>
        <div className="field">
          <label htmlFor="promo-code">Promo code (optional)</label>
          <input
            id="promo-code"
            name="promoCode"
            aria-describedby="promo-hint"
            value={promoCode}
            onChange={(e) => setPromoCode(e.target.value)}
          />
          <p id="promo-hint" className="hint">
            Have more than one code? Separate them with commas. Discounts and shipping are
            recalculated when you place your order.
          </p>
        </div>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <button type="submit" disabled={submitting}>
          {submitting ? 'Placing order…' : 'Place order'}
        </button>
      </form>
    </section>
  );
}
