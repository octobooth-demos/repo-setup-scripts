import type { Money } from '../lib/money.js';

export type Category = 'apparel' | 'accessories' | 'drinkware' | 'stickers' | 'toys';

export interface Product {
  id: string;
  name: string;
  description: string;
  category: Category;
  price: Money;
  /** Emoji used as the product image in the demo UI. */
  image: string;
  imageAlt: string;
  stock: number;
  /** Storewide sale as a whole-number percentage off, e.g. 30 for 30% off. */
  salePercent?: number;
}

export interface User {
  id: string;
  email: string;
  name: string;
  passwordHash: string;
}

export type PublicUser = Omit<User, 'passwordHash'>;

export interface CartItem {
  productId: string;
  quantity: number;
}

export interface ShippingAddress {
  name: string;
  line1: string;
  city: string;
  postalCode: string;
  country: string;
}

export interface OrderLine {
  productId: string;
  name: string;
  unitPrice: Money;
  quantity: number;
  lineTotal: Money;
}

export interface Totals {
  subtotal: Money;
  discount: Money;
  shipping: Money;
  total: Money;
}

export interface Order extends Totals {
  id: string;
  userId: string;
  lines: OrderLine[];
  promoCode: string | null;
  shippingAddress: ShippingAddress;
  createdAt: string;
}
