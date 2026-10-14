export const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_URL') || 'https://bookivo.in',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

export function json(body: unknown, status = 200, cors = true) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...(cors ? corsHeaders : {}) } });
}
export function preflight(req: Request) { return req.method === 'OPTIONS' ? new Response('ok', { headers: corsHeaders }) : null; }
export async function body(req: Request) { try { return await req.json(); } catch { throw new Error('Request body must be valid JSON.'); } }
export function env(name: string) { const value = Deno.env.get(name); if (!value) throw new Error(`Missing server configuration: ${name}`); return value; }
export async function sha256(text: string) { const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)); return [...new Uint8Array(bytes)].map(x => x.toString(16).padStart(2, '0')).join(''); }
export function paise(value: unknown): number {
  const s = String(value); if (!/^\d+(\.\d{1,2})?$/.test(s)) throw new Error('Invalid payment amount.');
  const [whole, fraction = ''] = s.split('.'); return Number(whole) * 100 + Number((fraction + '00').slice(0, 2));
}
