import { env } from './http.ts';
export function cashfreeBase() { return Deno.env.get('CASHFREE_ENV') === 'production' ? 'https://api.cashfree.com/pg' : 'https://sandbox.cashfree.com/pg'; }
export function cashfreeHeaders() { return { 'x-api-version':'2025-01-01','x-client-id':env('CASHFREE_APP_ID'),'x-client-secret':env('CASHFREE_SECRET_KEY'),'content-type':'application/json' }; }
