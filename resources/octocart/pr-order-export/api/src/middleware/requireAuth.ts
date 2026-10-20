import { store } from '../data/store.js';
import type { PublicUser } from '../data/types.js';
import { asyncHandler } from '../lib/asyncHandler.js';
import { UnauthorizedError } from '../lib/errors.js';

declare module 'express-serve-static-core' {
  interface Request {
    user?: PublicUser;
    token?: string;
  }
}

/** Requires a valid `Authorization: Bearer <token>` header and sets `req.user`. */
// File downloads are plain links, so they can't send headers: accept ?access_token= as well.
export const requireAuth = asyncHandler(async (req, _res, next) => {
  const header = req.get('authorization') ?? '';
  const [scheme, headerToken] = header.split(' ');
  const token =
    scheme === 'Bearer' && headerToken
      ? headerToken
      : (req.query.access_token as string | undefined);
  if (!token) {
    throw new UnauthorizedError();
  }

  const userId = await store.getSessionUserId(token);
  const user = userId ? await store.getUser(userId) : undefined;
  if (!user) {
    throw new UnauthorizedError('Invalid or expired token');
  }

  req.user = { id: user.id, email: user.email, name: user.name };
  req.token = token;
  next();
});

/** Returns the authenticated user. Only call after `requireAuth`. */
export function currentUser(req: { user?: PublicUser }): PublicUser {
  if (!req.user) throw new UnauthorizedError();
  return req.user;
}
