import { z } from 'zod';
import { LocalError } from './ledger.js';

// This is a consistency check, not authentication. Bus validates the frozen JWT.
export function desktopLoginIdentity(token: string): { account: string; tenant: string; loginSession: string } {
  try {
    const claims = z.object({ sub: z.string().uuid(), sid: z.string().uuid(), act_scope: z.string(), act_tid: z.number().int().positive().optional() }).parse(JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString('utf8')));
    const tenant = claims.act_scope === 'tenant' && claims.act_tid
      ? `id:${claims.act_tid}` : claims.act_scope.startsWith('tenant:') ? z.string().uuid().parse(claims.act_scope.slice(7)) : '';
    if (!tenant) throw new Error('missing tenant');
    return { account: claims.sub, tenant, loginSession: claims.sid };
  } catch { throw new LocalError('local.invalid_login_scope'); }
}
