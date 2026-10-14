import { createClient } from 'npm:@supabase/supabase-js@2';
import { env } from './http.ts';

export async function authenticate(req: Request) {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) throw new Error('Sign in to continue.');
  const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) throw new Error('Your session is invalid or expired. Sign in again.');
  return { admin, user: data.user };
}
export async function requireAdmin(admin: ReturnType<typeof createClient>, userId: string) {
  const { data, error } = await admin.from('profiles').select('role').eq('id', userId).maybeSingle();
  if (error || data?.role !== 'admin') throw new Error('Administrator access is required.');
}
