import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { resetStore } from '../src/data/store.js';
import { testApp } from './helpers.js';

describe('reviews routes', () => {
  beforeEach(() => resetStore());

  it('POST /api/products/:id/reviews adds a review', async () => {
    const res = await request(testApp())
      .post('/api/products/octocat-hoodie/reviews')
      .send({ author: 'Mona', rating: 5, body: 'So cozy!' });
    expect(res.status).toBe(201);
    expect(res.body.review).toMatchObject({
      productId: 'octocat-hoodie',
      author: 'Mona',
      rating: 5,
    });
  });

  it('GET /api/products/:id/reviews lists reviews with the average rating', async () => {
    const app = testApp();
    await request(app)
      .post('/api/products/octocat-hoodie/reviews')
      .send({ author: 'Hubot', rating: 4, body: 'Great hoodie.' });

    const res = await request(app).get('/api/products/octocat-hoodie/reviews');
    expect(res.status).toBe(200);
    expect(res.body.count).toBe(2);
    expect(res.body.average).toBe(4.5);
  });
});
