import { FREE_SHIPPING_CODES, PROMO_CODES } from '../data/seed.js';
import type { CartItem, OrderLine, Product, Totals } from '../data/types.js';
import { ZERO, add, money, multiply, percentOf, subtract, sum } from './money.js';
import type { Money } from './money.js';
import { HttpError } from './errors.js';

export const FREE_SHIPPING_THRESHOLD = money(5000);
export const FLAT_SHIPPING = money(599);

/** Price after any storewide sale, rounded down so customers are never overcharged. */
export function salePrice(product: Product): Money {
  if (!product.salePercent) return product.price;
  return money(Math.floor(product.price * (1 - product.salePercent / 100)));
}

export function buildLines(items: readonly CartItem[], products: ReadonlyMap<string, Product>) {
  return items.map((item): OrderLine => {
    const product = products.get(item.productId);
    if (!product) {
      throw new HttpError(409, 'product_unavailable', `Product ${item.productId} is unavailable`);
    }
    const unitPrice = salePrice(product);
    return {
      productId: product.id,
      name: product.name,
      unitPrice,
      quantity: item.quantity,
      lineTotal: multiply(unitPrice, item.quantity),
    };
  });
}

export function discountPercent(promoCode: string | undefined): number {
  if (!promoCode) return 0;
  const percent = PROMO_CODES[promoCode.toUpperCase()];
  if (percent === undefined) {
    throw new HttpError(400, 'invalid_promo_code', `Unknown promo code "${promoCode}"`);
  }
  return percent;
}

export interface AppliedPromos {
  codes: string[];
  percent: number;
  freeShipping: boolean;
}

/** Applies a comma-separated list of promo codes, e.g. "OCTO10, FREESHIP". */
export function applyPromoCodes(input: string | undefined): AppliedPromos {
  const codes = (input ?? '')
    .split(',')
    .map((code) => code.trim().toUpperCase())
    .filter(Boolean);

  let percent = 0;
  for (const code of codes) {
    percent += discountPercent(code);
  }
  const freeShipping = codes.some((code) => FREE_SHIPPING_CODES.includes(code));
  return { codes, percent, freeShipping };
}

export function shippingFor(subtotalAfterDiscount: Money, freeShipping = false): Money {
  if (subtotalAfterDiscount === ZERO || freeShipping) return ZERO;
  return subtotalAfterDiscount > FREE_SHIPPING_THRESHOLD ? ZERO : FLAT_SHIPPING;
}

export function calculateTotals(
  lines: readonly OrderLine[],
  percent = 0,
  freeShipping = false,
): Totals {
  const subtotal = sum(lines.map((line) => line.lineTotal));
  const discount = percentOf(subtotal, percent);
  const discounted = subtract(subtotal, discount);
  const shipping = shippingFor(discounted, freeShipping);
  return { subtotal, discount, shipping, total: add(discounted, shipping) };
}
