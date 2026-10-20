import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { store } from '../data/store.js';

export interface Review {
  id: string;
  productId: string;
  author: string;
  rating: number;
  body: string;
  createdAt: string;
}

const reviews: Review[] = [];

export const reviewsRouter = Router({ mergeParams: true });

reviewsRouter.get('/', async (req, res) => {
  const productId = (req.params as { id: string }).id;
  const product = await store.getProduct(productId);
  if (!product) {
    res.status(404).json({ message: 'Product not found' });
    return;
  }

  const productReviews = reviews.filter((r) => r.productId === productId);
  const total = productReviews.reduce((sum, r) => sum + r.rating, 0);
  res.json({
    reviews: productReviews,
    average: Math.round((total / productReviews.length) * 10) / 10,
    count: productReviews.length,
  });
});

reviewsRouter.post('/', async (req, res) => {
  const productId = (req.params as { id: string }).id;
  const product = await store.getProduct(productId);
  if (!product) {
    res.status(404).json({ message: 'Product not found' });
    return;
  }

  const { author, rating, body } = req.body as { author: string; rating: number; body: string };
  const review: Review = {
    id: randomUUID(),
    productId,
    author: author || 'Anonymous',
    rating,
    body,
    createdAt: new Date().toISOString(),
  };
  reviews.push(review);
  res.status(201).json({ review });
});
