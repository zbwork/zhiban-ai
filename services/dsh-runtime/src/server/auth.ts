import { timingSafeEqual } from 'node:crypto';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { zapErrors } from './errors.js';

/** 常量时间比较 Bearer；长度不同直接判不等。 */
export function bearerMatches(header: string | undefined, expected: string): boolean {
  if (!header || !expected) return false;
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return false;
  const got = Buffer.from(header.slice(prefix.length).trim(), 'utf8');
  const want = Buffer.from(expected, 'utf8');
  if (got.length !== want.length) return false;
  return timingSafeEqual(got, want);
}

export function makeBearerGuard(apiKey: string) {
  return async function bearerGuard(req: FastifyRequest, _reply: FastifyReply): Promise<void> {
    if (!bearerMatches(req.headers.authorization, apiKey)) throw zapErrors.unauthorized();
  };
}
