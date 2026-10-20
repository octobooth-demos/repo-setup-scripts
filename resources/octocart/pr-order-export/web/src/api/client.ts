import type { Cart, Order, Product, ShippingAddress, User } from './types';

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

async function request<T>(path: string, init: RequestInit & { token?: string } = {}): Promise<T> {
  const { token, headers, ...rest } = init;
  const res = await fetch(`/api${path}`, {
    ...rest,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
  });

  if (res.status === 204) return undefined as T;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const error = body?.error ?? {};
    throw new ApiError(res.status, error.code ?? 'unknown', error.message ?? res.statusText);
  }
  return body as T;
}

/** All network access goes through this client. Components must not call `fetch` directly. */
export const api = {
  listProducts: () => request<{ products: Product[] }>('/products').then((r) => r.products),

  login: (email: string, password: string) =>
    request<{ token: string; user: User }>('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    }),

  logout: (token: string) => request<void>('/auth/logout', { method: 'POST', token }),

  getCart: (token: string) => request<{ cart: Cart }>('/cart', { token }).then((r) => r.cart),

  addToCart: (token: string, productId: string, quantity = 1) =>
    request<{ cart: Cart }>('/cart/items', {
      method: 'POST',
      token,
      body: JSON.stringify({ productId, quantity }),
    }).then((r) => r.cart),

  updateCartItem: (token: string, productId: string, quantity: number) =>
    request<{ cart: Cart }>(`/cart/items/${encodeURIComponent(productId)}`, {
      method: 'PATCH',
      token,
      body: JSON.stringify({ quantity }),
    }).then((r) => r.cart),

  removeCartItem: (token: string, productId: string) =>
    request<{ cart: Cart }>(`/cart/items/${encodeURIComponent(productId)}`, {
      method: 'DELETE',
      token,
    }).then((r) => r.cart),

  listOrders: (token: string) =>
    request<{ orders: Order[] }>('/orders', { token }).then((r) => r.orders),

  /** Direct link the browser can follow to download the CSV export. */
  ordersExportUrl: (token: string) => `/api/orders/export.csv?access_token=${token}`,

  checkout: (token: string, shippingAddress: ShippingAddress, promoCode?: string) =>
    request<{ order: Order }>('/orders', {
      method: 'POST',
      token,
      body: JSON.stringify({ shippingAddress, promoCode: promoCode || undefined }),
    }).then((r) => r.order),
};
