import { money } from '../lib/money.js';
import { hashPassword } from '../lib/passwords.js';
import type { Product, User } from './types.js';

export const DEMO_PASSWORD = 'octocat123';

export function seedProducts(): Product[] {
  return [
    {
      id: 'octocat-hoodie',
      name: 'Octocat Hoodie',
      description: 'A cozy zip-up hoodie with an embroidered Octocat.',
      category: 'apparel',
      price: money(5500),
      image: '🧥',
      imageAlt: 'Black hoodie with an Octocat on the chest',
      stock: 12,
    },
    {
      id: 'merge-conflict-tee',
      name: 'Merge Conflict Tee',
      description: '<<<<<<< HEAD — wear your conflicts proudly.',
      category: 'apparel',
      price: money(2500),
      image: '👕',
      imageAlt: 'T-shirt printed with git merge conflict markers',
      stock: 30,
    },
    {
      id: 'contribution-graph-mug',
      name: 'Contribution Graph Mug',
      description: 'Keep your streak green and your coffee hot.',
      category: 'drinkware',
      price: money(1800),
      image: '☕',
      imageAlt: 'White mug covered in green contribution squares',
      stock: 25,
    },
    {
      id: 'mona-sticker-pack',
      name: 'Mona Sticker Pack',
      description: 'Ten vinyl stickers featuring Mona and friends.',
      category: 'stickers',
      price: money(800),
      image: '🐙',
      imageAlt: 'Assorted Octocat stickers',
      stock: 100,
    },
    {
      id: 'copilot-plushie',
      name: 'Copilot Plushie',
      description: 'Your pair programmer, now in huggable form.',
      category: 'toys',
      price: money(3200),
      image: '🧸',
      imageAlt: 'Plush toy of the Copilot mascot',
      stock: 8,
    },
    {
      id: 'actions-water-bottle',
      name: 'Actions Water Bottle',
      description: 'Stay hydrated between workflow runs.',
      category: 'drinkware',
      price: money(2200),
      image: '🥤',
      imageAlt: 'Insulated water bottle with the GitHub Actions logo',
      stock: 15,
      salePercent: 25,
    },
    {
      id: 'dependabot-socks',
      name: 'Dependabot Socks',
      description: 'Keeps your toes patched and up to date.',
      category: 'accessories',
      price: money(1400),
      image: '🧦',
      imageAlt: 'Blue socks with a Dependabot pattern',
      stock: 40,
      salePercent: 30,
    },
  ];
}

export function seedUsers(): User[] {
  return [
    {
      id: 'user-mona',
      email: 'mona@octocart.dev',
      name: 'Mona Lisa Octocat',
      passwordHash: hashPassword(DEMO_PASSWORD),
    },
    {
      id: 'user-hubot',
      email: 'hubot@octocart.dev',
      name: 'Hubot',
      passwordHash: hashPassword(DEMO_PASSWORD),
    },
  ];
}

/** Promo codes map to an integer percentage discount. */
export const PROMO_CODES: Readonly<Record<string, number>> = {
  OCTO10: 10,
  HUBBER20: 20,
  FREESHIP: 0,
};

/** Promo codes that waive shipping regardless of the order total. */
export const FREE_SHIPPING_CODES: readonly string[] = ['FREESHIP'];
