import { z } from 'zod';

export const ProductIdParams = z.object({ id: z.string().min(1).max(100) });
export type ProductIdParams = z.infer<typeof ProductIdParams>;

export const ListProductsQuery = z.object({
  category: z.enum(['apparel', 'accessories', 'drinkware', 'stickers', 'toys']).optional(),
  q: z.string().trim().min(1).max(100).optional(),
});
export type ListProductsQuery = z.infer<typeof ListProductsQuery>;

export const LoginBody = z.object({
  email: z.string().trim().email(),
  password: z.string().min(1).max(200),
});
export type LoginBody = z.infer<typeof LoginBody>;

export const MAX_QUANTITY = 10;
const Quantity = z.number().int().min(1).max(MAX_QUANTITY);

export const AddCartItemBody = z.object({
  productId: z.string().min(1).max(100),
  quantity: Quantity.default(1),
});
export type AddCartItemBody = z.infer<typeof AddCartItemBody>;

export const CartItemParams = z.object({ productId: z.string().min(1).max(100) });
export type CartItemParams = z.infer<typeof CartItemParams>;

export const UpdateCartItemBody = z.object({ quantity: Quantity });
export type UpdateCartItemBody = z.infer<typeof UpdateCartItemBody>;

export const ShippingAddress = z.object({
  name: z.string().trim().min(1).max(100),
  line1: z.string().trim().min(1).max(200),
  city: z.string().trim().min(1).max(100),
  postalCode: z.string().trim().min(3).max(12),
  country: z.string().trim().length(2).toUpperCase(),
});

export const CreateOrderBody = z.object({
  shippingAddress: ShippingAddress,
  /** One or more promo codes, separated by commas. */
  promoCode: z.string().trim().min(1).optional(),
});
export type CreateOrderBody = z.infer<typeof CreateOrderBody>;

export const OrderIdParams = z.object({ id: z.string().uuid() });
export type OrderIdParams = z.infer<typeof OrderIdParams>;
