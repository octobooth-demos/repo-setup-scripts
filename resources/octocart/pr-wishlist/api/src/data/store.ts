import { randomUUID } from 'node:crypto';
import { seedProducts, seedUsers } from './seed.js';
import type { CartItem, Category, Order, Product, User, WishlistEntry } from './types.js';

/**
 * In-memory data store. Methods are async to mirror a real database client,
 * so route handlers must await them inside `asyncHandler`.
 */
interface State {
  products: Map<string, Product>;
  users: Map<string, User>;
  sessions: Map<string, string>;
  carts: Map<string, CartItem[]>;
  orders: Order[];
  wishlists: Map<string, WishlistEntry[]>;
}

let state: State = createState();

function createState(): State {
  return {
    products: new Map(seedProducts().map((p) => [p.id, p])),
    users: new Map(seedUsers().map((u) => [u.id, u])),
    sessions: new Map(),
    carts: new Map(),
    orders: [],
    wishlists: new Map(),
  };
}

/** Restores seed data. Call in `beforeEach` in tests. */
export function resetStore(): void {
  state = createState();
}

export const store = {
  async listProducts(filter: { category?: Category; q?: string } = {}): Promise<Product[]> {
    const q = filter.q?.toLowerCase();
    return [...state.products.values()].filter(
      (p) =>
        (!filter.category || p.category === filter.category) &&
        (!q || p.name.toLowerCase().includes(q) || p.description.toLowerCase().includes(q)),
    );
  },

  async getProduct(id: string): Promise<Product | undefined> {
    return state.products.get(id);
  },

  async decrementStock(id: string, quantity: number): Promise<void> {
    const product = state.products.get(id);
    if (product) product.stock -= quantity;
  },

  async findUserByEmail(email: string): Promise<User | undefined> {
    const normalized = email.toLowerCase();
    return [...state.users.values()].find((u) => u.email === normalized);
  },

  async getUser(id: string): Promise<User | undefined> {
    return state.users.get(id);
  },

  async createSession(token: string, userId: string): Promise<void> {
    state.sessions.set(token, userId);
  },

  async getSessionUserId(token: string): Promise<string | undefined> {
    return state.sessions.get(token);
  },

  async deleteSession(token: string): Promise<void> {
    state.sessions.delete(token);
  },

  async getCart(userId: string): Promise<CartItem[]> {
    return state.carts.get(userId) ?? [];
  },

  async saveCart(userId: string, items: CartItem[]): Promise<void> {
    state.carts.set(userId, items);
  },

  async createOrder(order: Omit<Order, 'id' | 'createdAt'>): Promise<Order> {
    const created: Order = { ...order, id: randomUUID(), createdAt: new Date().toISOString() };
    state.orders.push(created);
    return created;
  },

  async listOrders(userId: string): Promise<Order[]> {
    return state.orders.filter((o) => o.userId === userId);
  },

  async getOrder(userId: string, id: string): Promise<Order | undefined> {
    return state.orders.find((o) => o.userId === userId && o.id === id);
  },

  async getWishlist(userId: string): Promise<WishlistEntry[]> {
    return state.wishlists.get(userId) ?? [];
  },

  /** Adds a product to the wishlist, or updates its note if it's already saved. */
  async saveToWishlist(userId: string, entry: WishlistEntry): Promise<void> {
    const others = (state.wishlists.get(userId) ?? []).filter(
      (e) => e.productId !== entry.productId,
    );
    state.wishlists.set(userId, [...others, entry]);
  },

  async removeFromWishlist(userId: string, productId: string): Promise<void> {
    const remaining = (state.wishlists.get(userId) ?? []).filter((e) => e.productId !== productId);
    state.wishlists.set(userId, remaining);
  },
};
