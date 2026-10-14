import { requireSupabase } from './supabase';
import type { Product } from '../types';

type ProductRow = {
  id: string; title: string; slug: string; subtitle: string | null; description: string;
  category: { name: string } | null; tags: string[] | null; price_paise: number; compare_at_paise: number | null;
  cover_path: string | null; preview_paths: string[] | null; benefits: unknown; check_benefits: unknown;
  status: string; featured: boolean;
};

export async function listPublishedProducts(search = '', categorySlug?: string): Promise<Product[]> {
  const client = requireSupabase();
  let query = client.from('products').select('id,title,slug,subtitle,description,tags,price_paise,compare_at_paise,cover_path,preview_paths,benefits,check_benefits,status,featured,category:categories(name)')
    .eq('status', 'published').order('display_order', { ascending: true }).order('created_at', { ascending: false }).limit(48);
  if (categorySlug) query = query.eq('categories.slug', categorySlug);
  if (search.trim()) query = query.textSearch('search_document', search.trim(), { type: 'websearch', config: 'simple' });
  const { data, error } = await query;
  if (error) throw error;
  return ((data ?? []) as unknown as ProductRow[]).map(row => ({
    id: row.id, title: row.title, slug: row.slug, shortDescription: row.subtitle ?? '', description: row.description,
    category: row.category?.name ?? 'Uncategorised', tags: row.tags ?? [], price: row.price_paise / 100,
    listPrice: row.compare_at_paise == null ? row.price_paise / 100 : row.compare_at_paise / 100,
    cover: row.cover_path ? client.storage.from('product-media').getPublicUrl(row.cover_path).data.publicUrl : '',
    benefits: Array.isArray(row.benefits) ? row.benefits as string[] : [],
    checks: Array.isArray(row.check_benefits) ? row.check_benefits as string[] : [],
    status: row.status === 'published' ? 'published' : 'draft', featured: row.featured,
  }));
}

export async function fetchPublicPromotions() {
  const { data, error } = await requireSupabase().from('promotions')
    .select('message,image_path,popup_enabled,starts_at,expires_at').eq('enabled', true)
    .or(`starts_at.is.null,starts_at.lte.${new Date().toISOString()}`).or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
    .order('updated_at', { ascending: false }).limit(1).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const client = requireSupabase();
  return { enabled: true, message: data.message, start: data.starts_at ?? '', expiry: data.expires_at ?? '', popup: data.popup_enabled,
    image: data.image_path ? client.storage.from('product-media').getPublicUrl(data.image_path).data.publicUrl : '' };
}
