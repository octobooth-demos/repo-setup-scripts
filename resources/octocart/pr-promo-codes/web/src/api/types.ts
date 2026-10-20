import type { Money } from '../lib/money';

export type Category = 'apparel' | 'accessories' | 'drinkware' | 'stickers' | 'toys';

export interface Product {
  id: string;
  name: string;
  description: string;
  category: Category;
  price: Money;
  image: string;
  imageAlt: string;
  stock: number;
  salePercent?: number;
}

export interface User {
  id: string;
  email: string;
  name: string;
}

export interface CartLine {
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

export interface Cart extends Totals {
  lines: CartLine[];
}

export interface ShippingAddress {
  name: string;
  line1: string;
  city: string;
  postalCode: string;
  country: string;
}

export interface Order extends Totals {
  id: string;
  lines: CartLine[];
  promoCode: string | null;
  shippingAddress: ShippingAddress;
  createdAt: string;
}
