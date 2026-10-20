import { Router } from 'express';
import { store } from '../data/store.js';
import type { Product, WishlistEntry } from '../data/types.js';
import { currentUser, requireAuth } from '../middleware/requireAuth.js';

export const wishlistRouter = Router();

wishlistRouter.use(requireAuth);

wishlistRouter.get('/', async (req, res) => {
  try {
    const entries = await store.getWishlist(currentUser(req).id);
    const items: (WishlistEntry & { product: Product })[] = [];
    for (const entry of entries) {
      const product = await store.getProduct(entry.productId);
      if (product) items.push({ ...entry, product });
    }
    const total = items.reduce(
      (sum, item) => sum + parseFloat((item.product.price / 100).toFixed(2)),
      0,
    );
    res.json({ items, total: total.toFixed(2) });
  } catch {
    res.status(500).json({ message: 'Could not load wishlist' });
  }
});

wishlistRouter.post('/', async (req, res) => {
  const { productId, note } = req.body;
  const product = await store.getProduct(productId);
  if (!product) {
    res.status(404).json({ error: 'Product not found' });
    return;
  }
  await store.saveToWishlist(currentUser(req).id, {
    productId,
    note,
    addedAt: new Date().toISOString(),
  });
  res.json({ ok: true });
});

wishlistRouter.delete('/:productId', async (req, res) => {
  await store.removeFromWishlist(currentUser(req).id, req.params.productId);
  res.json({ ok: true });
});

wishlistRouter.post('/:productId/move-to-cart', async (req, res) => {
  const userId = currentUser(req).id;
  const cart = await store.getCart(userId);
  await store.saveCart(userId, [...cart, { productId: req.params.productId, quantity: 1 }]);
  await store.removeFromWishlist(userId, req.params.productId);
  res.json({ ok: true });
});
