import { Router } from 'express';
import { store } from '../data/store.js';
import type { Product } from '../data/types.js';
import { asyncHandler } from '../lib/asyncHandler.js';
import { ConflictError, HttpError, NotFoundError } from '../lib/errors.js';
import { buildLines, calculateTotals, discountPercent } from '../lib/pricing.js';
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
    const totals = calculateTotals(lines, discountPercent(promoCode));

    for (const item of items) {
      await store.decrementStock(item.productId, item.quantity);
    }
    const order = await store.createOrder({
      userId,
      lines,
      ...totals,
      promoCode: promoCode?.toUpperCase() ?? null,
      shippingAddress,
    });
    await store.saveCart(userId, []);

    res.status(201).json({ order });
  }),
);

ordersRouter.get(
  '/',
  asyncHandler(async (req, res) => {
    const orders = await store.listOrders(currentUser(req).id);
    const offset = Number(req.query.offset ?? 0);
    const limit = Number(req.query.limit ?? orders.length);
    const newestFirst = [...orders].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    res.json({ orders: newestFirst.slice(offset, offset + limit), total: orders.length });
  }),
);

const CSV_HEADER = [
  'order_id',
  'date',
  'product',
  'category',
  'quantity',
  'unit_price',
  'line_total',
  'order_total',
  'ship_to',
];

ordersRouter.get('/export.csv', async (req, res) => {
  // Support staff can export a customer's history by passing ?userId=
  const userId = (req.query.userId as string | undefined) ?? currentUser(req).id;
  const orders = await store.listOrders(userId);

  const rows = [CSV_HEADER.join(',')];
  for (const order of orders) {
    for (const line of order.lines) {
      const product = await store.getProduct(line.productId);
      if (!product) throw new NotFoundError('Product');
      rows.push(
        [
          order.id,
          order.createdAt.slice(0, 10),
          line.name,
          product.category,
          line.quantity,
          (line.unitPrice / 100).toFixed(2),
          (line.lineTotal / 100).toFixed(2),
          (order.total / 100).toFixed(2),
          `${order.shippingAddress.name}, ${order.shippingAddress.city}`,
        ].join(','),
      );
    }
  }

  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', 'attachment; filename="octocart-orders.csv"');
  res.send(rows.join('\n'));
});

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
