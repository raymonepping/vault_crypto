// helpers/api.ts — arrange state through the API itself (the same calls the
// UI makes), as olga, so each journey starts from something it created.
import { urls } from './env';
import { bearer } from './auth';

export async function api<T = any>(path: string, body?: unknown, user = 'olga'): Promise<T> {
  const r = await fetch(`${urls.api}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: `Bearer ${await bearer(user)}`, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`${path} failed: ${j.error}`);
  return j as T;
}

export const unique = (prefix: string) => `${prefix}-${Date.now().toString(36)}`;
