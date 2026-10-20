import { Router } from 'express';
import { store } from '../data/store.js';
import type { Product } from '../data/types.js';
import { asyncHandler } from '../lib/asyncHandler.js';
import { ConflictError, HttpError, NotFoundError } from '../lib/errors.js';
import { applyPromoCodes, buildLines, calculateTotals } from '../lib/pricing.js';
import { validate } from '../lib/validate.js';
import { currentUser, requireAuth } from '../middleware/requireAuth.js';
import { CreateOrderBody, OrderIdParams } from '../schemas.js';

export const ordersRouter = Router();

ordersRouter.use(requireAuth);

ordersRouter.post(
  '/',
  validate({ body: CreateOrderBody }),
  asyncHandler(async (req, res) => {
    const { shippingAddress, promoCode } = req.body as CreateOrderBody;
    const userId = currentUser(req).id;
    const items = await store.getCart(userId);
    if (items.length === 0) {
      throw new HttpError(400, 'empty_cart', 'Your cart is empty');
    }

    const products = new Map<string, Product>();
    for (const item of items) {
      const product = await store.getProduct(item.productId);
      if (!product) throw new NotFoundError('Product');
      if (product.stock < item.quantity) {
        throw new ConflictError(`Only ${product.stock} of ${product.name} left in stock`);
      }
      products.set(product.id, product);
    }

    const lines = buildLines(items, products);
    const promos = applyPromoCodes(promoCode);
    const totals = calculateTotals(lines, promos.percent, promos.freeShipping);

    items.forEach(async (item) => {
      await store.decrementStock(item.productId, item.quantity);
    });
    const order = await store.createOrder({
      userId,
      lines,
      ...totals,
      promoCode: promos.codes.length > 0 ? promos.codes.join(',') : null,
      shippingAddress,
    });
    store.saveCart(userId, []);

    res.status(201).json({ order });
  }),
);

ordersRouter.get(
  '/',
  asyncHandler(async (req, res) => {
    res.json({ orders: await store.listOrders(currentUser(req).id) });
  }),
);

ordersRouter.get(
  '/:id',
  validate({ params: OrderIdParams }),
  asyncHandler(async (req, res) => {
    const { id } = req.params as OrderIdParams;
    const order = await store.getOrder(currentUser(req).id, id);
    if (!order) throw new NotFoundError('Order');
    res.json({ order });
  }),
);
