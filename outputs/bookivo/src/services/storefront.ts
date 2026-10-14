import { requireSupabase } from './supabase';
import type { Product } from '../types';

export type CheckoutLine = { product_id: string; quantity: number };
export async function createPaymentOrder(input: { items: CheckoutLine[]; idempotency_key: string; customer_name: string; customer_phone: string; coupon_code?: string }) {
  const { data, error } = await requireSupabase().functions.invoke('create-cashfree-order', { body: input });
  if (error) throw error;
  return data as { order_id: string; payment_session_id: string; environment: 'sandbox' | 'production'; amount_paise: number; currency: 'INR' };
}
export async function verifyPayment(orderId: string) {
  const { data, error } = await requireSupabase().functions.invoke('verify-cashfree-payment', { body: { gateway_order_id: orderId } });
  if (error) throw error;
  return data as { status: 'pending' | 'paid' | 'failed'; order_id: string };
}
export async function requestDownload(productId: string) {
  const { data, error } = await requireSupabase().functions.invoke('request-ebook-download', { body: { product_id: productId } });
  if (error) throw error;
  return data as { signed_url: string; expires_in: number; filename: string };
}
export async function getMyOrders() {
  const { data, error } = await requireSupabase().from('orders')
    .select('id,order_number,status,payment_status,amount_due_paise,currency,created_at,order_items(product_id,title_snapshot,quantity,unit_price_paise)')
    .order('created_at', { ascending: false }).limit(50);
  if (error) throw error;
  return data ?? [];
}
export async function getMyLibrary(): Promise<Product[]> {
  const client = requireSupabase();
  const { data, error } = await client.from('purchase_entitlements')
    .select('id,product:products(id,title,slug,subtitle,description,tags,price_paise,compare_at_paise,cover_path,benefits,check_benefits,status,featured,category:categories(name))')
    .is('revoked_at', null).order('granted_at', { ascending: false }).limit(100);
  if (error) throw error;
  return (data ?? []).flatMap((row: any) => {
    const p = Array.isArray(row.product) ? row.product[0] : row.product;
    if (!p) return [];
    return [{ id:p.id,title:p.title,slug:p.slug,shortDescription:p.subtitle||'',description:p.description,category:p.category?.name||'Bookivo',tags:p.tags||[],price:p.price_paise/100,listPrice:(p.compare_at_paise??p.price_paise)/100,cover:p.cover_path?client.storage.from('product-media').getPublicUrl(p.cover_path).data.publicUrl:'',benefits:p.benefits||[],checks:p.check_benefits||[],status:p.status,featured:p.featured } as Product];
  });
}
