import { useEffect, useState } from 'react';
import { api } from '../api/client';
import type { Order } from '../api/types';
import { useAuth } from '../context/AuthContext';
import { formatMoney } from '../lib/money';

export function OrderHistory() {
  const { token } = useAuth();
  const [orders, setOrders] = useState<Order[]>([]);

  useEffect(() => {
    if (!token) return;
    api
      .listOrders(token)
      .then(setOrders)
      .catch(() => setOrders([]));
  }, [token]);

  if (!token) return null;

  return (
    <section aria-labelledby="orders-heading" className="order-history">
      <h2 id="orders-heading">Your orders</h2>
      {orders.length === 0 ? (
        <p className="hint">You haven’t placed any orders yet.</p>
      ) : (
        <table>
          <caption className="visually-hidden">Past orders</caption>
          <thead>
            <tr>
              <th scope="col">Order</th>
              <th scope="col">Date</th>
              <th scope="col">Items</th>
              <th scope="col">Total</th>
            </tr>
          </thead>
          <tbody>
            {orders.map((order) => (
              <tr key={order.id}>
                <td>
                  <code>{order.id.slice(0, 8)}</code>
                </td>
                <td>{new Date(order.createdAt).toLocaleDateString()}</td>
                <td>{order.lines.reduce((count, line) => count + line.quantity, 0)}</td>
                <td>{formatMoney(order.total)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <a href={api.ordersExportUrl(token)} download>
        Download order history (CSV)
      </a>
    </section>
  );
}
