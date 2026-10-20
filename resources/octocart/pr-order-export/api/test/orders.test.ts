import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { resetStore, store } from '../src/data/store.js';
import { loginAs, testApp, validAddress } from './helpers.js';

describe('orders routes', () => {
  let app: ReturnType<typeof testApp>;
  let auth: { Authorization: string };

  beforeEach(async () => {
    resetStore();
    app = testApp();
    auth = { Authorization: `Bearer ${await loginAs(app)}` };
  });

  async function addToCart(productId: string, quantity = 1) {
    await request(app).post('/api/cart/items').set(auth).send({ productId, quantity });
  }

  it('requires authentication', async () => {
    const res = await request(app).post('/api/orders').send({ shippingAddress: validAddress });
    expect(res.status).toBe(401);
  });

  it('GET /api/orders requires authentication', async () => {
    const res = await request(app).get('/api/orders');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('unauthorized');
  });

  it('POST /api/orders checks out the cart', async () => {
    await addToCart('octocat-hoodie');
    await addToCart('mona-sticker-pack', 2);
    const res = await request(app)
      .post('/api/orders')
      .set(auth)
      .send({ shippingAddress: validAddress, promoCode: 'hubber20' });

    expect(res.status).toBe(201);
    expect(res.body.order).toMatchObject({
      subtotal: 7100,
      discount: 1420,
      shipping: 0,
      total: 5680,
      promoCode: 'HUBBER20',
      shippingAddress: { country: 'US' },
    });
    expect((await store.getProduct('octocat-hoodie'))?.stock).toBe(11);

    const cart = await request(app).get('/api/cart').set(auth);
    expect(cart.body.cart.lines).toEqual([]);
  });

  it('rejects an empty cart', async () => {
    const res = await request(app)
      .post('/api/orders')
      .set(auth)
      .send({ shippingAddress: validAddress });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('empty_cart');
  });

  it('rejects an invalid promo code', async () => {
    await addToCart('octocat-hoodie');
    const res = await request(app)
      .post('/api/orders')
      .set(auth)
      .send({ shippingAddress: validAddress, promoCode: 'FREESTUFF' });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('invalid_promo_code');
  });

  it('rejects a missing shipping address', async () => {
    await addToCart('octocat-hoodie');
    const res = await request(app).post('/api/orders').set(auth).send({});
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('validation_error');
  });

  it('GET /api/orders and /api/orders/:id return the user’s orders', async () => {
    await addToCart('octocat-hoodie');
    const created = await request(app)
      .post('/api/orders')
      .set(auth)
      .send({ shippingAddress: validAddress });
    const id = created.body.order.id as string;

    const list = await request(app).get('/api/orders').set(auth);
    expect(list.body.orders).toHaveLength(1);

    const one = await request(app).get(`/api/orders/${id}`).set(auth);
    expect(one.status).toBe(200);
    expect(one.body.order.id).toBe(id);
  });

  it('does not expose other users’ orders', async () => {
    await addToCart('octocat-hoodie');
    const created = await request(app)
      .post('/api/orders')
      .set(auth)
      .send({ shippingAddress: validAddress });
    const hubot = { Authorization: `Bearer ${await loginAs(app, 'hubot@octocart.dev')}` };
    const res = await request(app).get(`/api/orders/${created.body.order.id}`).set(hubot);
    expect(res.status).toBe(404);
  });

  it('GET /api/orders/export.csv exports the user’s order history', async () => {
    await addToCart('octocat-hoodie');
    await request(app).post('/api/orders').set(auth).send({ shippingAddress: validAddress });

    const res = await request(app).get('/api/orders/export.csv').set(auth);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('text/csv');
    const [header, row] = res.text.split('\n');
    expect(header).toBe(
      'order_id,date,product,category,quantity,unit_price,line_total,order_total,ship_to',
    );
    expect(row).toContain('Octocat Hoodie,apparel,1,55.00,55.00');
  });

  it('validates the order id', async () => {
    const res = await request(app).get('/api/orders/not-a-uuid').set(auth);
    expect(res.status).toBe(400);
  });
});
