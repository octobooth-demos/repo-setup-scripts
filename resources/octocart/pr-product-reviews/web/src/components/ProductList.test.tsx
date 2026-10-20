import { render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AuthProvider } from '../context/AuthContext';
import { CartProvider } from '../context/CartContext';
import { ProductList } from './ProductList';

describe('ProductList', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('loads products from the API and renders them', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        url.endsWith('/reviews')
          ? new Response(JSON.stringify({ reviews: [], average: 0, count: 0 }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            })
          : new Response(
              JSON.stringify({
                products: [
                  {
                    id: 'mona-sticker-pack',
                    name: 'Mona Sticker Pack',
                    description: 'Stickers!',
                    category: 'stickers',
                    price: 800,
                    image: '🐙',
                    imageAlt: 'Assorted Octocat stickers',
                    stock: 10,
                  },
                ],
              }),
              { status: 200, headers: { 'Content-Type': 'application/json' } },
            ),
      ),
    );

    render(
      <AuthProvider>
        <CartProvider>
          <ProductList />
        </CartProvider>
      </AuthProvider>,
    );

    expect(await screen.findByRole('heading', { name: 'Mona Sticker Pack' })).toBeInTheDocument();
    expect(screen.getByText('$8.00')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add Mona Sticker Pack to cart' })).toBeDisabled();
  });
});
