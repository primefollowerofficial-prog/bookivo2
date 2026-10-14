-- BOOKIVO core schema. Apply locally first; do not use `supabase db push` on production without review.
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

do $$ begin create type public.user_role as enum ('customer', 'admin'); exception when duplicate_object then null; end $$;
do $$ begin create type public.product_status as enum ('draft', 'published', 'archived'); exception when duplicate_object then null; end $$;
do $$ begin create type public.order_status as enum ('pending', 'paid', 'failed', 'cancelled', 'refunded'); exception when duplicate_object then null; end $$;
do $$ begin create type public.payment_status as enum ('pending', 'success', 'failed', 'user_dropped', 'refunded'); exception when duplicate_object then null; end $$;
do $$ begin create type public.review_status as enum ('pending', 'approved', 'rejected'); exception when duplicate_object then null; end $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin new.updated_at := now(); return new; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 100),
  avatar_path text,
  role public.user_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists profiles_role_idx on public.profiles(role) where role = 'admin';

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, left(coalesce(new.raw_user_meta_data->>'display_name', ''), 100))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created_bookivo on auth.users;
create trigger on_auth_user_created_bookivo after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_bookivo_admin()
returns boolean language sql stable security definer set search_path = pg_catalog, public as $$
  select exists(select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin');
$$;
revoke all on function public.is_bookivo_admin() from public, anon;
grant execute on function public.is_bookivo_admin() to authenticated;

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description text not null default '',
  display_order integer not null default 0,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into public.categories(name,slug,display_order) values
  ('Lifestyle','lifestyle',1),('Personal Growth','personal-growth',2),('Career & Skills','career-skills',3),
  ('Cooking & Everyday Life','cooking-everyday-life',4),('Finance & Productivity','finance-productivity',5)
on conflict (slug) do nothing;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title text not null check (char_length(title) between 1 and 180),
  subtitle text not null default '' check (char_length(subtitle) <= 500),
  description text not null default '',
  author text not null default '',
  language text not null default 'en',
  category_id uuid references public.categories(id) on delete set null,
  tags text[] not null default '{}',
  price_paise bigint not null check (price_paise >= 0),
  compare_at_paise bigint check (compare_at_paise is null or compare_at_paise >= price_paise),
  cover_path text,
  preview_paths text[] not null default '{}',
  ebook_object_path text,
  benefits jsonb not null default '[]'::jsonb check (jsonb_typeof(benefits) = 'array'),
  check_benefits jsonb not null default '[]'::jsonb check (jsonb_typeof(check_benefits) = 'array'),
  details jsonb not null default '[]'::jsonb check (jsonb_typeof(details) = 'array'),
  faqs jsonb not null default '[]'::jsonb check (jsonb_typeof(faqs) = 'array'),
  status public.product_status not null default 'draft',
  featured boolean not null default false,
  display_order integer not null default 0,
  search_document tsvector generated always as (to_tsvector('simple', coalesce(title,'') || ' ' || coalesce(subtitle,'') || ' ' || coalesce(description,'') || ' ' || coalesce(array_to_string(tags,' '),''))) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status <> 'published' or price_paise > 0)
);
create index if not exists products_public_order_idx on public.products(status, display_order, created_at desc);
create index if not exists products_category_idx on public.products(category_id, status);
create index if not exists products_search_idx on public.products using gin(search_document);

create table if not exists public.coupons (
  id uuid primary key default gen_random_uuid(),
  code extensions.citext not null unique check (code::text ~ '^[A-Z0-9][A-Z0-9_-]{2,31}$'),
  discount_type text not null check (discount_type in ('percent', 'fixed')),
  discount_value bigint not null check (discount_value > 0),
  minimum_subtotal_paise bigint not null default 0 check (minimum_subtotal_paise >= 0),
  eligible_product_ids uuid[],
  usage_limit integer check (usage_limit is null or usage_limit > 0),
  per_user_limit integer not null default 1 check (per_user_limit > 0),
  starts_at timestamptz,
  expires_at timestamptz,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((discount_type = 'percent' and discount_value < 10000) or discount_type = 'fixed'),
  check (expires_at is null or starts_at is null or expires_at > starts_at)
);
create index if not exists coupons_enabled_expiry_idx on public.coupons(enabled, expires_at);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('BK-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
  user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  status public.order_status not null default 'pending',
  payment_status public.payment_status not null default 'pending',
  currency char(3) not null default 'INR' check (currency = 'INR'),
  subtotal_paise bigint not null check (subtotal_paise >= 0),
  discount_paise bigint not null default 0 check (discount_paise >= 0),
  amount_due_paise bigint not null check (amount_due_paise >= 0 and amount_due_paise = subtotal_paise - discount_paise),
  coupon_id uuid references public.coupons(id) on delete set null,
  customer_name text not null check (char_length(customer_name) between 1 and 100),
  customer_email extensions.citext not null,
  customer_phone text not null check (customer_phone ~ '^\+?[0-9 ()-]{8,20}$'),
  gateway_order_id text unique,
  payment_session_id text,
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, idempotency_key)
);
create index if not exists orders_user_created_idx on public.orders(user_id, created_at desc);
create index if not exists orders_status_expiry_idx on public.orders(status, expires_at);
create index if not exists orders_coupon_status_idx on public.orders(coupon_id, status, expires_at);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  slug_snapshot text not null,
  title_snapshot text not null,
  quantity integer not null check (quantity between 1 and 10),
  unit_price_paise bigint not null check (unit_price_paise >= 0),
  discount_paise bigint not null default 0 check (discount_paise >= 0),
  currency char(3) not null default 'INR' check (currency = 'INR'),
  created_at timestamptz not null default now(),
  unique(order_id, product_id)
);
create index if not exists order_items_order_idx on public.order_items(order_id);
create index if not exists order_items_product_idx on public.order_items(product_id);

create table if not exists public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  provider text not null default 'cashfree' check (provider = 'cashfree'),
  cf_payment_id text not null unique,
  status public.payment_status not null,
  amount_paise bigint not null check (amount_paise >= 0),
  currency char(3) not null check (currency = 'INR'),
  failure_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists payment_attempts_order_idx on public.payment_attempts(order_id, created_at desc);

create table if not exists public.payment_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  event_type text not null,
  order_id uuid references public.orders(id) on delete set null,
  cf_payment_id text,
  payload_sha256 text not null,
  received_at timestamptz not null default now()
);
create index if not exists payment_events_order_idx on public.payment_events(order_id, received_at desc);

create table if not exists public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','sending','sent','failed')),
  attempts smallint not null default 0 check (attempts between 0 and 10),
  last_attempt_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.purchase_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  order_id uuid not null references public.orders(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(order_id, product_id)
);
create index if not exists entitlements_user_idx on public.purchase_entitlements(user_id, granted_at desc);

create table if not exists public.download_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  entitlement_id uuid not null references public.purchase_entitlements(id) on delete restrict,
  requested_at timestamptz not null default now()
);
create index if not exists download_events_user_time_idx on public.download_events(user_id, requested_at desc);

create table if not exists public.coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references public.coupons(id) on delete restrict,
  order_id uuid not null unique references public.orders(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  redeemed_at timestamptz not null default now(),
  unique(coupon_id, user_id, order_id)
);
create index if not exists coupon_redemptions_user_idx on public.coupon_redemptions(coupon_id, user_id);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  body text not null check (char_length(body) between 8 and 3000),
  status public.review_status not null default 'pending',
  purchase_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(product_id, user_id)
);
create index if not exists reviews_public_idx on public.reviews(product_id, status, created_at desc);
create or replace function public.mark_verified_purchase_review()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.user_id is null then new.user_id := (select auth.uid()); end if;
  new.purchase_verified := exists (
    select 1 from public.purchase_entitlements e join public.orders o on o.id=e.order_id
    where e.user_id=new.user_id and e.product_id=new.product_id and e.revoked_at is null and o.status='paid'
  );
  return new;
end $$;
revoke all on function public.mark_verified_purchase_review() from public, anon, authenticated;
drop trigger if exists mark_verified_purchase_review on public.reviews;
create trigger mark_verified_purchase_review before insert on public.reviews
for each row execute function public.mark_verified_purchase_review();

create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  message text not null check (char_length(message) between 1 and 300),
  enabled boolean not null default false,
  starts_at timestamptz,
  expires_at timestamptz,
  image_path text,
  popup_enabled boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at is null or starts_at is null or expires_at > starts_at)
);
create index if not exists promotions_active_idx on public.promotions(enabled, starts_at, expires_at, updated_at desc);

create table if not exists public.store_settings (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,63}$'),
  value jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  sender_name text not null check (char_length(sender_name) between 1 and 100),
  sender_email extensions.citext not null,
  message text not null check (char_length(message) between 10 and 5000),
  status text not null default 'unread' check (status in ('unread','read','replied','archived')),
  received_at timestamptz not null default now()
);
create index if not exists contact_messages_status_idx on public.contact_messages(status, received_at desc);

do $$ declare t text; begin
foreach t in array array['profiles','categories','products','coupons','orders','order_items','payment_attempts','payment_events','email_outbox','purchase_entitlements','download_events','coupon_redemptions','reviews','promotions','store_settings','contact_messages'] loop
    execute format('drop trigger if exists %I_touch_updated_at on public.%I', t, t);
    if t in ('profiles','categories','products','coupons','orders','payment_attempts','reviews','promotions','store_settings','email_outbox') then
      execute format('create trigger %I_touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()', t, t);
    end if;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
  end loop;
end $$;

-- Least-privilege public product projection: the private ebook object path is deliberately not selectable.
grant select(id,slug,title,subtitle,description,author,language,category_id,tags,price_paise,compare_at_paise,cover_path,preview_paths,benefits,check_benefits,details,faqs,status,featured,display_order,search_document,created_at,updated_at) on public.products to anon, authenticated;
grant select(id,name,slug,description,display_order,enabled,created_at,updated_at) on public.categories to anon, authenticated;
grant select(id,message,enabled,starts_at,expires_at,image_path,popup_enabled,created_at,updated_at) on public.promotions to anon, authenticated;
grant select(id,product_id,user_id,rating,body,status,purchase_verified,created_at,updated_at) on public.reviews to anon, authenticated;
grant insert(product_id,rating,body) on public.reviews to authenticated;
grant select(id,role,display_name,avatar_path,created_at,updated_at) on public.profiles to authenticated;
grant update(display_name,avatar_path) on public.profiles to authenticated;
grant select(id,order_number,user_id,status,payment_status,currency,subtotal_paise,discount_paise,amount_due_paise,coupon_id,customer_name,customer_email,customer_phone,expires_at,created_at,updated_at) on public.orders to authenticated;
grant select(id,order_id,product_id,slug_snapshot,title_snapshot,quantity,unit_price_paise,discount_paise,currency,created_at) on public.order_items to authenticated;
grant select(id,user_id,order_id,product_id,granted_at,revoked_at) on public.purchase_entitlements to authenticated;
grant select(id,user_id,product_id,entitlement_id,requested_at) on public.download_events to authenticated;
grant insert(sender_name,sender_email,message) on public.contact_messages to anon, authenticated;

-- Admin writes go through authenticated RLS; private file paths and all payment mutations stay server-only.
grant insert, update, delete on public.categories to authenticated;
grant insert, update, delete on public.products to authenticated;
grant select(id,code,discount_type,discount_value,minimum_subtotal_paise,eligible_product_ids,usage_limit,per_user_limit,starts_at,expires_at,enabled,created_at,updated_at) on public.coupons to authenticated;
grant insert, update, delete on public.coupons to authenticated;
grant select(id,message,enabled,starts_at,expires_at,image_path,popup_enabled,created_by,created_at,updated_at) on public.promotions to authenticated;
grant insert, update, delete on public.promotions to authenticated;
grant select(key,value,updated_by,updated_at) on public.store_settings to authenticated;
grant insert, update, delete on public.store_settings to authenticated;
grant update(status) on public.reviews to authenticated;
grant select(id,user_id,sender_name,sender_email,message,status,received_at) on public.contact_messages to authenticated;
grant update(status) on public.contact_messages to authenticated;

create policy "categories enabled are public" on public.categories for select to anon, authenticated using (enabled or (select public.is_bookivo_admin()));
create policy "admins manage categories" on public.categories for all to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
create policy "published products are public" on public.products for select to anon, authenticated using (status = 'published' or (select public.is_bookivo_admin()));
create policy "buyers retain access to purchased product details" on public.products for select to authenticated using (
  exists (select 1 from public.purchase_entitlements e join public.orders o on o.id=e.order_id
    where e.product_id=products.id and e.user_id=(select auth.uid()) and e.revoked_at is null and o.status='paid')
);
create policy "admins manage products" on public.products for all to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
create policy "own profile read" on public.profiles for select to authenticated using (id = (select auth.uid()) or (select public.is_bookivo_admin()));
create policy "own profile update safe columns" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "public promotions active" on public.promotions for select to anon, authenticated using (enabled and (starts_at is null or starts_at <= now()) and (expires_at is null or expires_at > now()));
create policy "admins manage promotions" on public.promotions for all to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
create policy "admins manage coupons" on public.coupons for all to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
create policy "admins manage store settings" on public.store_settings for all to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
create policy "approved reviews public" on public.reviews for select to anon, authenticated using (status = 'approved' or user_id = (select auth.uid()) or (select public.is_bookivo_admin()));
create policy "customers submit verified review" on public.reviews for insert to authenticated with check (
  user_id = (select auth.uid()) and status = 'pending' and purchase_verified = true and exists (
    select 1 from public.purchase_entitlements e join public.orders o on o.id=e.order_id
    where e.user_id=(select auth.uid()) and e.product_id=reviews.product_id and e.revoked_at is null and o.status='paid'
  )
);
create policy "admins moderate reviews" on public.reviews for update to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
create policy "own orders read" on public.orders for select to authenticated using (user_id = (select auth.uid()) or (select public.is_bookivo_admin()));
create policy "admins read order items" on public.order_items for select to authenticated using ((select public.is_bookivo_admin()));
create policy "own order items read" on public.order_items for select to authenticated using (exists(select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid())));
create policy "own entitlement read" on public.purchase_entitlements for select to authenticated using (user_id = (select auth.uid()) or (select public.is_bookivo_admin()));
create policy "own download history read" on public.download_events for select to authenticated using (user_id = (select auth.uid()) or (select public.is_bookivo_admin()));
create policy "public contact submission" on public.contact_messages for insert to anon, authenticated with check ((user_id is null or user_id = (select auth.uid())));
create policy "admins manage contact messages" on public.contact_messages for all to authenticated using ((select public.is_bookivo_admin())) with check ((select public.is_bookivo_admin()));
-- Payment attempts/events and coupon redemptions have RLS enabled and no anon/authenticated grants or policies.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('product-media','product-media',true,10485760,array['image/jpeg','image/png','image/webp','image/avif']),
       ('paid-ebooks','paid-ebooks',false,104857600,array['application/pdf'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "public media read" on storage.objects;
create policy "public media read" on storage.objects for select to anon, authenticated using (bucket_id = 'product-media');
drop policy if exists "admins upload product media" on storage.objects;
create policy "admins upload product media" on storage.objects for insert to authenticated with check (bucket_id = 'product-media' and (select public.is_bookivo_admin()));
drop policy if exists "admins update product media" on storage.objects;
create policy "admins update product media" on storage.objects for update to authenticated using (bucket_id = 'product-media' and (select public.is_bookivo_admin())) with check (bucket_id = 'product-media' and (select public.is_bookivo_admin()));
drop policy if exists "admins delete product media" on storage.objects;
create policy "admins delete product media" on storage.objects for delete to authenticated using (bucket_id = 'product-media' and (select public.is_bookivo_admin()));
drop policy if exists "admins upload private ebooks" on storage.objects;
create policy "admins upload private ebooks" on storage.objects for insert to authenticated with check (bucket_id = 'paid-ebooks' and (select public.is_bookivo_admin()));
drop policy if exists "admins update private ebooks" on storage.objects;
create policy "admins update private ebooks" on storage.objects for update to authenticated using (bucket_id = 'paid-ebooks' and (select public.is_bookivo_admin())) with check (bucket_id = 'paid-ebooks' and (select public.is_bookivo_admin()));
drop policy if exists "admins delete private ebooks" on storage.objects;
create policy "admins delete private ebooks" on storage.objects for delete to authenticated using (bucket_id = 'paid-ebooks' and (select public.is_bookivo_admin()));
-- No customer policy exists for paid-ebooks. Only the entitlement-checking Edge Function uses service role to sign downloads.

create or replace function public.create_checkout_order(
  p_user_id uuid, p_idempotency_key uuid, p_items jsonb, p_customer_name text,
  p_customer_email text, p_customer_phone text, p_coupon_code text default null
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare
  v_existing public.orders%rowtype; v_order public.orders%rowtype; v_coupon public.coupons%rowtype;
  v_subtotal bigint := 0; v_discount bigint := 0; v_remaining_discount bigint := 0;
  v_line_count integer; v_n integer := 0; v_line record; v_line_discount bigint;
  v_code text := nullif(upper(trim(p_coupon_code)), '');
begin
  if p_user_id is null or p_idempotency_key is null or p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'Invalid checkout request' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || p_idempotency_key::text, 0));
  if length(trim(p_customer_name)) not between 1 and 100 or length(trim(p_customer_email)) not between 3 and 254
     or p_customer_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or p_customer_phone !~ '^\+?[0-9 ()-]{8,20}$' then raise exception 'Invalid customer details' using errcode='22023'; end if;

  select * into v_existing from public.orders where user_id = p_user_id and idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('id',v_existing.id,'order_number',v_existing.order_number,'status',v_existing.status,
    'gateway_order_id',v_existing.gateway_order_id,'payment_session_id',v_existing.payment_session_id,'amount_due_paise',v_existing.amount_due_paise,'currency',v_existing.currency); end if;

  select count(*) into v_line_count from jsonb_array_elements(p_items);
  if exists (select 1 from jsonb_array_elements(p_items) i group by i->>'product_id' having count(*) > 1) then
    raise exception 'Duplicate product lines are not allowed' using errcode='22023';
  end if;
  for v_line in select (i->>'product_id')::uuid as product_id, (i->>'quantity')::integer as quantity
    from jsonb_array_elements(p_items) i loop
    if v_line.quantity not between 1 and 10 then raise exception 'Invalid item quantity' using errcode='22023'; end if;
    perform 1 from public.products p where p.id = v_line.product_id and p.status = 'published' and p.price_paise > 0;
    if not found then raise exception 'One or more products are unavailable' using errcode='22023'; end if;
    select v_subtotal + (price_paise * v_line.quantity) into v_subtotal from public.products where id=v_line.product_id;
  end loop;
  if v_subtotal <= 0 or v_subtotal > 1000000000 then raise exception 'Invalid order amount' using errcode='22023'; end if;

  if v_code is not null then
    if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,31}$' then raise exception 'Coupon is invalid or unavailable' using errcode='22023'; end if;
    select * into v_coupon from public.coupons where code = v_code for update;
    if not found or not v_coupon.enabled or (v_coupon.starts_at is not null and v_coupon.starts_at > now())
      or (v_coupon.expires_at is not null and v_coupon.expires_at <= now())
      or v_subtotal < v_coupon.minimum_subtotal_paise
      or (v_coupon.eligible_product_ids is not null and exists (select 1 from jsonb_array_elements(p_items) i where not ((i->>'product_id')::uuid = any(v_coupon.eligible_product_ids))))
      or (v_coupon.usage_limit is not null and (select count(*) from public.orders o where o.coupon_id=v_coupon.id and (o.status='paid' or (o.status='pending' and o.expires_at>now()))) >= v_coupon.usage_limit)
      or (select count(*) from public.orders o where o.coupon_id=v_coupon.id and o.user_id=p_user_id and (o.status='paid' or (o.status='pending' and o.expires_at>now()))) >= v_coupon.per_user_limit then
      raise exception 'Coupon is invalid or unavailable' using errcode='22023';
    end if;
    if v_coupon.discount_type='percent' then v_discount := floor(v_subtotal * v_coupon.discount_value / 10000.0)::bigint;
    else v_discount := least(v_subtotal,v_coupon.discount_value); end if;
    if v_discount >= v_subtotal then raise exception 'Coupon must leave an amount payable' using errcode='22023'; end if;
  end if;

  insert into public.orders(user_id,idempotency_key,status,payment_status,subtotal_paise,discount_paise,amount_due_paise,coupon_id,customer_name,customer_email,customer_phone)
    values(p_user_id,p_idempotency_key,'pending','pending',v_subtotal,v_discount,v_subtotal-v_discount,v_coupon.id,trim(p_customer_name),lower(trim(p_customer_email)),trim(p_customer_phone))
    returning * into v_order;
  v_remaining_discount := v_discount;
  for v_line in
    select p.id,p.slug,p.title,p.price_paise,(i->>'quantity')::integer as quantity,
           row_number() over(order by p.id) as rn,count(*) over() as line_count
    from jsonb_array_elements(p_items) i join public.products p on p.id=(i->>'product_id')::uuid
    where p.status='published' order by p.id
  loop
    if v_discount=0 then v_line_discount:=0;
    elsif v_line.rn=v_line.line_count then v_line_discount:=v_remaining_discount;
    else v_line_discount:=floor(v_discount * (v_line.price_paise*v_line.quantity)::numeric / v_subtotal)::bigint; v_remaining_discount:=v_remaining_discount-v_line_discount;
    end if;
    insert into public.order_items(order_id,product_id,slug_snapshot,title_snapshot,quantity,unit_price_paise,discount_paise)
      values(v_order.id,v_line.id,v_line.slug,v_line.title,v_line.quantity,v_line.price_paise,v_line_discount);
  end loop;
  return jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'status',v_order.status,
    'gateway_order_id',null,'payment_session_id',null,'amount_due_paise',v_order.amount_due_paise,'currency',v_order.currency);
end $$;
revoke all on function public.create_checkout_order(uuid,uuid,jsonb,text,text,text,text) from public, anon, authenticated;
grant execute on function public.create_checkout_order(uuid,uuid,jsonb,text,text,text,text) to service_role;

create or replace function public.attach_cashfree_session(p_order_id uuid,p_gateway_order_id text,p_payment_session_id text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update public.orders set gateway_order_id=p_gateway_order_id,payment_session_id=p_payment_session_id
  where id=p_order_id and status='pending' and (gateway_order_id is null or gateway_order_id=p_gateway_order_id);
  return found;
end $$;
revoke all on function public.attach_cashfree_session(uuid,text,text) from public, anon, authenticated;
grant execute on function public.attach_cashfree_session(uuid,text,text) to service_role;

create or replace function public.process_cashfree_payment(
  p_gateway_order_id text,p_cf_payment_id text,p_event_key text,p_event_type text,
  p_payment_status text,p_amount_paise bigint,p_currency text,p_payload_sha256 text
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_order public.orders%rowtype; v_newly_paid boolean:=false; v_status public.payment_status;
begin
  if p_gateway_order_id is null or length(p_gateway_order_id)>64 or p_cf_payment_id is null or length(p_cf_payment_id)>80
    or p_event_key is null or length(p_event_key)>200 or p_payload_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'Invalid payment event' using errcode='22023'; end if;
  if p_currency <> 'INR' or p_amount_paise < 0 or p_payment_status not in ('SUCCESS','FAILED','USER_DROPPED','PENDING') then raise exception 'Invalid payment state' using errcode='22023'; end if;
  select * into v_order from public.orders where gateway_order_id=p_gateway_order_id for update;
  if not found then raise exception 'Unknown payment order' using errcode='P0002'; end if;
  insert into public.payment_events(event_key,event_type,order_id,cf_payment_id,payload_sha256)
    values(p_event_key,p_event_type,v_order.id,p_cf_payment_id,p_payload_sha256) on conflict(event_key) do nothing;
  if not found then return jsonb_build_object('order_id',v_order.id,'status',v_order.status,'duplicate',true,'newly_paid',false); end if;
  v_status := case p_payment_status when 'SUCCESS' then 'success'::public.payment_status when 'FAILED' then 'failed'::public.payment_status when 'USER_DROPPED' then 'user_dropped'::public.payment_status else 'pending'::public.payment_status end;
  if p_payment_status='SUCCESS' and (p_amount_paise<>v_order.amount_due_paise or p_currency<>v_order.currency) then
    raise exception 'Verified amount does not match the pending order' using errcode='22023';
  end if;
  insert into public.payment_attempts(order_id,cf_payment_id,status,amount_paise,currency)
    values(v_order.id,p_cf_payment_id,v_status,p_amount_paise,p_currency)
    on conflict(cf_payment_id) do update set status=excluded.status,amount_paise=excluded.amount_paise,currency=excluded.currency,updated_at=now()
    where payment_attempts.order_id=v_order.id;
  if not found then raise exception 'Payment reference is already associated with another order' using errcode='23505'; end if;
  if p_payment_status='SUCCESS' and v_order.status<>'refunded' then
    v_newly_paid := v_order.status<>'paid';
    update public.orders set status='paid',payment_status='success' where id=v_order.id;
    insert into public.purchase_entitlements(user_id,order_id,product_id)
      select v_order.user_id,v_order.id,oi.product_id from public.order_items oi where oi.order_id=v_order.id and oi.product_id is not null
      on conflict(order_id,product_id) do nothing;
    if v_newly_paid then
      insert into public.email_outbox(order_id) values(v_order.id) on conflict(order_id) do nothing;
    end if;
    if v_order.coupon_id is not null then
      insert into public.coupon_redemptions(coupon_id,order_id,user_id) values(v_order.coupon_id,v_order.id,v_order.user_id) on conflict(order_id) do nothing;
    end if;
  elsif p_payment_status='FAILED' and v_order.status='pending' then
    update public.orders set status='failed',payment_status='failed' where id=v_order.id;
  elsif p_payment_status='USER_DROPPED' and v_order.status='pending' then
    update public.orders set payment_status='user_dropped' where id=v_order.id;
  end if;
  select * into v_order from public.orders where id=v_order.id;
  return jsonb_build_object('order_id',v_order.id,'status',v_order.status,'duplicate',false,'newly_paid',v_newly_paid);
end $$;
revoke all on function public.process_cashfree_payment(text,text,text,text,text,bigint,text,text) from public, anon, authenticated;
grant execute on function public.process_cashfree_payment(text,text,text,text,text,bigint,text,text) to service_role;

create or replace function public.claim_order_confirmation_email(p_order_id uuid)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  update public.email_outbox e set status='sending',attempts=e.attempts+1,last_attempt_at=now(),updated_at=now()
  from public.orders o
  where e.order_id=p_order_id and o.id=e.order_id and o.status='paid' and e.attempts<5
    and (e.status in ('pending','failed') or (e.status='sending' and e.last_attempt_at < now()-interval '5 minutes'))
    and (e.last_attempt_at is null or e.last_attempt_at < now()-interval '5 minutes');
  return found;
end $$;
revoke all on function public.claim_order_confirmation_email(uuid) from public, anon, authenticated;
grant execute on function public.claim_order_confirmation_email(uuid) to service_role;

create or replace function public.finish_order_confirmation_email(p_order_id uuid,p_sent boolean,p_error_code text default null)
returns void language sql security definer set search_path = pg_catalog, public as $$
  update public.email_outbox set status=case when p_sent then 'sent' else 'failed' end,
    last_error_code=case when p_sent then null else left(coalesce(p_error_code,'delivery_failed'),40) end, updated_at=now()
  where order_id=p_order_id and status='sending';
$$;
revoke all on function public.finish_order_confirmation_email(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.finish_order_confirmation_email(uuid,boolean,text) to service_role;
