import { describe, expect, it } from 'vitest';
import { seedProducts } from '../src/data/seed.js';
import { HttpError } from '../src/lib/errors.js';
import { money } from '../src/lib/money.js';
import {
  FLAT_SHIPPING,
  applyPromoCodes,
  buildLines,
  calculateTotals,
  discountPercent,
} from '../src/lib/pricing.js';

const products = new Map(seedProducts().map((p) => [p.id, p]));

describe('pricing', () => {
  it('builds lines with integer line totals', () => {
    const [line] = buildLines([{ productId: 'mona-sticker-pack', quantity: 3 }], products);
    expect(line).toMatchObject({ unitPrice: 800, quantity: 3, lineTotal: 2400 });
  });

  it('rejects unknown products', () => {
    expect(() => buildLines([{ productId: 'nope', quantity: 1 }], products)).toThrow(HttpError);
  });

  it('charges flat shipping under the threshold', () => {
    const lines = buildLines([{ productId: 'mona-sticker-pack', quantity: 1 }], products);
    expect(calculateTotals(lines)).toEqual({
      subtotal: money(800),
      discount: money(0),
      shipping: FLAT_SHIPPING,
      total: money(1399),
    });
  });

  it('applies discounts before checking free shipping', () => {
    const lines = buildLines([{ productId: 'octocat-hoodie', quantity: 1 }], products);
    const totals = calculateTotals(lines, discountPercent('octo10'));
    expect(totals).toEqual({
      subtotal: money(5500),
      discount: money(550),
      shipping: money(599),
      total: money(5549),
    });
  });

  it('has zero totals for an empty cart', () => {
    expect(calculateTotals([]).total).toBe(0);
  });

  it('applies storewide sale prices', () => {
    const [line] = buildLines([{ productId: 'actions-water-bottle', quantity: 2 }], products);
    expect(line).toMatchObject({ unitPrice: 1650, quantity: 2, lineTotal: 3300 });
  });

  it('stacks comma-separated promo codes', () => {
    expect(applyPromoCodes('octo10, hubber20')).toEqual({
      codes: ['OCTO10', 'HUBBER20'],
      percent: 30,
      freeShipping: false,
    });
  });

  it('waives shipping with FREESHIP', () => {
    const lines = buildLines([{ productId: 'mona-sticker-pack', quantity: 1 }], products);
    const promos = applyPromoCodes('OCTO10,FREESHIP');
    expect(calculateTotals(lines, promos.percent, promos.freeShipping)).toEqual({
      subtotal: money(800),
      discount: money(80),
      shipping: money(0),
      total: money(720),
    });
  });

  it('rejects unknown promo codes', () => {
    expect(() => discountPercent('FREESTUFF')).toThrow(HttpError);
    expect(discountPercent(undefined)).toBe(0);
  });
});
