import express from 'express';
import { errorHandler, notFoundHandler } from './middleware/errorHandler.js';
import { authRouter } from './routes/auth.js';
import { cartRouter } from './routes/cart.js';
import { ordersRouter } from './routes/orders.js';
import { productsRouter } from './routes/products.js';
import { reviewsRouter } from './routes/reviews.js';

export function createApp() {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }));

  app.get('/api/health', (_req, res) => {
    res.json({ status: 'ok' });
  });
  app.use('/api/products/:id/reviews', reviewsRouter);
  app.use('/api/products', productsRouter);
  app.use('/api/auth', authRouter);
  app.use('/api/cart', cartRouter);
  app.use('/api/orders', ordersRouter);

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
