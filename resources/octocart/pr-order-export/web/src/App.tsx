import { Cart } from './components/Cart';
import { CheckoutForm } from './components/CheckoutForm';
import { Header } from './components/Header';
import { OrderHistory } from './components/OrderHistory';
import { ProductList } from './components/ProductList';
import { useAuth } from './context/AuthContext';
import { useCart } from './context/CartContext';

export function App() {
  const { user } = useAuth();
  const { status, error } = useCart();

  return (
    <>
      <a href="#main" className="skip-link">
        Skip to content
      </a>
      <Header />
      <main id="main">
        <div className="visually-hidden" aria-live="polite">
          {status}
        </div>
        {error && (
          <p role="alert" className="error banner">
            {error}
          </p>
        )}
        <ProductList />
        {user && (
          <div id="cart" className="cart-panel">
            <Cart />
            <CheckoutForm />
            <OrderHistory />
          </div>
        )}
      </main>
      <footer>
        <p>
          A demo store for Copilot Code Review. Try promo code <code>OCTO10</code>.
        </p>
      </footer>
    </>
  );
}
