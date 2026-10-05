create extension if not exists pgcrypto;

create table if not exists public.staff_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null check (role in ('admin', 'cashier')),
  created_at timestamptz not null default now()
);

create table if not exists public.cafe_settings (
  singleton boolean primary key default true check (singleton),
  tax_rate_bps integer not null default 0 check (tax_rate_bps between 0 and 10000),
  service_rate_bps integer not null default 0 check (service_rate_bps between 0 and 10000),
  updated_at timestamptz not null default now()
);

insert into public.cafe_settings (singleton) values (true)
on conflict (singleton) do nothing;

create table if not exists public.menu_items (
  id text primary key,
  name text not null,
  category text not null,
  price integer not null check (price >= 0),
  tag text,
  image text not null,
  variants jsonb not null default '[{"name":"Reguler","extra":0}]'::jsonb,
  sugars text[] not null default '{}',
  is_available boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  receipt_number text not null unique default (
    'KS-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS') || '-' ||
    upper(substr(gen_random_uuid()::text, 1, 6))
  ),
  cashier_id uuid not null references public.staff_profiles(user_id),
  payment_method text not null check (payment_method in ('Tunai', 'QRIS', 'EDC')),
  payment_status text not null check (payment_status in ('pending', 'paid')),
  subtotal integer not null check (subtotal >= 0),
  tax integer not null check (tax >= 0),
  service_charge integer not null check (service_charge >= 0),
  total integer not null check (total = subtotal + tax + service_charge),
  cash_received integer,
  change_amount integer,
  confirmed_by uuid references public.staff_profiles(user_id),
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  check (
    (payment_method = 'Tunai' and payment_status = 'paid'
      and cash_received is not null and change_amount is not null
      and cash_received >= total and change_amount = cash_received - total)
    or (payment_method <> 'Tunai' and cash_received is null and change_amount is null)
  ),
  check (
    (payment_method = 'Tunai' and confirmed_by is null and confirmed_at is null)
    or (payment_method <> 'Tunai' and payment_status = 'pending'
      and confirmed_by is null and confirmed_at is null)
    or (payment_method <> 'Tunai' and payment_status = 'paid'
      and confirmed_by is not null and confirmed_at is not null)
  )
);

create table if not exists public.sale_items (
  id bigint generated always as identity primary key,
  sale_id uuid not null references public.sales(id) on delete cascade,
  menu_item_id text not null references public.menu_items(id),
  item_name text not null,
  quantity integer not null check (quantity between 1 and 99),
  unit_price integer not null check (unit_price >= 0),
  variant text not null,
  sugar text not null default '',
  note text not null default ''
);

create index if not exists sales_created_at_idx on public.sales (created_at desc);
create index if not exists sale_items_sale_id_idx on public.sale_items (sale_id);

create or replace function public.current_staff_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.staff_profiles where user_id = (select auth.uid())
$$;

create or replace function public.create_sale(
  p_items jsonb,
  p_payment_method text,
  p_request_id uuid,
  p_cash_received integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  menu public.menu_items%rowtype;
  variant_option jsonb;
  variant_name text;
  sugar_name text;
  quantity_value integer;
  unit_price_value integer;
  subtotal_value integer := 0;
  tax_value integer;
  service_value integer;
  total_value integer;
  sale_id_value uuid;
  sale_record public.sales%rowtype;
  sale_items_value jsonb := '[]'::jsonb;
begin
  if (select auth.uid()) is null or public.current_staff_role() is null then
    raise exception 'Akun ini tidak memiliki akses kasir.';
  end if;
  if p_request_id is null then
    raise exception 'ID permintaan transaksi wajib diisi.';
  end if;
  select * into sale_record from public.sales where request_id = p_request_id;
  if found then
    if sale_record.cashier_id <> (select auth.uid()) then
      raise exception 'ID permintaan transaksi sudah digunakan.';
    end if;
    select coalesce(jsonb_agg(to_jsonb(si) - 'sale_id'), '[]'::jsonb)
      into sale_items_value from public.sale_items si where si.sale_id = sale_record.id;
    return jsonb_build_object(
      'id', sale_record.id,
      'receipt_number', sale_record.receipt_number,
      'created_at', sale_record.created_at,
      'payment_method', sale_record.payment_method,
      'payment_status', sale_record.payment_status,
      'subtotal', sale_record.subtotal,
      'tax', sale_record.tax,
      'service_charge', sale_record.service_charge,
      'total', sale_record.total,
      'cash_received', sale_record.cash_received,
      'change_amount', sale_record.change_amount,
      'items', sale_items_value
    );
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Daftar pesanan tidak valid.';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Pesanan kosong.';
  end if;
  if p_payment_method not in ('Tunai', 'QRIS', 'EDC') then
    raise exception 'Metode pembayaran tidak dikenal.';
  end if;
  sale_id_value := gen_random_uuid();

  for item in select value from jsonb_array_elements(p_items)
  loop
    quantity_value := (item->>'quantity')::integer;
    if quantity_value < 1 or quantity_value > 99 then
      raise exception 'Jumlah item harus antara 1 dan 99.';
    end if;

    select * into menu from public.menu_items
      where id = item->>'menu_item_id' and is_available;
    if not found then
      raise exception 'Menu tidak tersedia: %.', item->>'menu_item_id';
    end if;

    variant_name := coalesce(item->>'variant', '');
    select option_value into variant_option
      from jsonb_array_elements(menu.variants) as options(option_value)
      where option_value->>'name' = variant_name
      limit 1;
    if variant_option is null then
      raise exception 'Pilihan ukuran tidak valid untuk %.', menu.name;
    end if;

    sugar_name := coalesce(item->>'sugar', '');
    if cardinality(menu.sugars) > 0 and not (sugar_name = any(menu.sugars)) then
      raise exception 'Pilihan gula tidak valid untuk %.', menu.name;
    elsif cardinality(menu.sugars) = 0 and sugar_name <> '' then
      raise exception 'Menu ini tidak memiliki pilihan gula.';
    end if;

    unit_price_value := menu.price + coalesce((variant_option->>'extra')::integer, 0);
    if unit_price_value < 0 then
      raise exception 'Harga pilihan menu tidak valid untuk %.', menu.name;
    end if;
    subtotal_value := subtotal_value + unit_price_value * quantity_value;
    sale_items_value := sale_items_value || jsonb_build_array(jsonb_build_object(
      'menu_item_id', menu.id,
      'item_name', menu.name,
      'quantity', quantity_value,
      'unit_price', unit_price_value,
      'variant', variant_name,
      'sugar', sugar_name,
      'note', left(coalesce(item->>'note', ''), 240)
    ));
  end loop;

  select round(subtotal_value * tax_rate_bps / 10000.0)::integer,
         round(subtotal_value * service_rate_bps / 10000.0)::integer
    into tax_value, service_value
    from public.cafe_settings where singleton;
  tax_value := coalesce(tax_value, 0);
  service_value := coalesce(service_value, 0);
  total_value := subtotal_value + tax_value + service_value;

  if p_payment_method = 'Tunai' then
    if p_cash_received is null or p_cash_received < total_value then
      raise exception 'Nominal tunai kurang dari total tagihan.';
    end if;
  elsif p_cash_received is not null then
    raise exception 'Nominal tunai hanya berlaku untuk pembayaran tunai.';
  end if;

  insert into public.sales (
    id, request_id, cashier_id, payment_method, payment_status, subtotal, tax,
    service_charge, total, cash_received, change_amount
  ) values (
    sale_id_value, p_request_id, (select auth.uid()), p_payment_method,
    case when p_payment_method = 'Tunai' then 'paid' else 'pending' end,
    subtotal_value, tax_value, service_value, total_value,
    p_cash_received, case when p_payment_method = 'Tunai' then p_cash_received - total_value else null end
  ) returning * into sale_record;

  insert into public.sale_items (
    sale_id, menu_item_id, item_name, quantity, unit_price, variant, sugar, note
  )
  select sale_id_value,
      expanded_item->>'menu_item_id',
      expanded_item->>'item_name',
      (expanded_item->>'quantity')::integer,
      (expanded_item->>'unit_price')::integer,
      expanded_item->>'variant',
      expanded_item->>'sugar',
      expanded_item->>'note'
    from jsonb_array_elements(sale_items_value) as expanded(expanded_item);

  select coalesce(jsonb_agg(to_jsonb(si) - 'sale_id'), '[]'::jsonb)
    into sale_items_value from public.sale_items si where si.sale_id = sale_id_value;
  return jsonb_build_object(
    'id', sale_record.id,
    'receipt_number', sale_record.receipt_number,
    'created_at', sale_record.created_at,
    'payment_method', sale_record.payment_method,
    'payment_status', sale_record.payment_status,
    'subtotal', sale_record.subtotal,
    'tax', sale_record.tax,
    'service_charge', sale_record.service_charge,
    'total', sale_record.total,
    'cash_received', sale_record.cash_received,
    'change_amount', sale_record.change_amount,
    'items', sale_items_value
  );
end;
$$;

create or replace function public.confirm_sale_payment(p_sale_id uuid)
returns public.sales
language plpgsql
security definer
set search_path = ''
as $$
declare
  sale_record public.sales%rowtype;
begin
  if (select auth.uid()) is null or public.current_staff_role() is null then
    raise exception 'Akun ini tidak memiliki akses kasir.';
  end if;
  update public.sales
    set payment_status = 'paid',
        confirmed_by = (select auth.uid()),
        confirmed_at = now()
    where id = p_sale_id and payment_status = 'pending'
    returning * into sale_record;
  if not found then
    raise exception 'Transaksi tidak ditemukan atau sudah diproses.';
  end if;
  return sale_record;
end;
$$;

alter table public.staff_profiles enable row level security;
alter table public.cafe_settings enable row level security;
alter table public.menu_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

drop policy if exists "Staff can read own profile" on public.staff_profiles;
drop policy if exists "Staff can read settings" on public.cafe_settings;
drop policy if exists "Staff can update settings" on public.cafe_settings;
drop policy if exists "Staff can read menu" on public.menu_items;
drop policy if exists "Admins can manage menu" on public.menu_items;
drop policy if exists "Staff can read sales" on public.sales;
drop policy if exists "Staff can read sale items" on public.sale_items;

create policy "Staff can read own profile"
  on public.staff_profiles for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Staff can read settings"
  on public.cafe_settings for select to authenticated
  using (public.current_staff_role() is not null);
create policy "Staff can update settings"
  on public.cafe_settings for update to authenticated
  using (public.current_staff_role() = 'admin')
  with check (public.current_staff_role() = 'admin');
create policy "Staff can read menu"
  on public.menu_items for select to authenticated
  using (public.current_staff_role() is not null);
create policy "Admins can manage menu"
  on public.menu_items for all to authenticated
  using (public.current_staff_role() = 'admin')
  with check (public.current_staff_role() = 'admin');
create policy "Staff can read sales"
  on public.sales for select to authenticated
  using (public.current_staff_role() is not null);
create policy "Staff can read sale items"
  on public.sale_items for select to authenticated
  using (public.current_staff_role() is not null);

revoke all on public.staff_profiles, public.cafe_settings, public.menu_items,
  public.sales, public.sale_items from anon;
grant select on public.staff_profiles, public.cafe_settings, public.menu_items,
  public.sales, public.sale_items to authenticated;
grant update on public.cafe_settings to authenticated;
grant insert, update, delete on public.menu_items to authenticated;
grant execute on function public.create_sale(jsonb, text, uuid, integer) to authenticated;
grant execute on function public.confirm_sale_payment(uuid) to authenticated;
grant execute on function public.current_staff_role() to authenticated;
revoke all on function public.create_sale(jsonb, text, uuid, integer) from public, anon;
revoke all on function public.confirm_sale_payment(uuid) from public, anon;
revoke all on function public.current_staff_role() from public, anon;

insert into public.menu_items (id, name, category, price, tag, image, variants, sugars)
values
  ('aren','Kopi Susu Aren','Kopi',24000,'Favorit','photo-1461023058943-07fcbe16d735','[{"name":"Regular","extra":0},{"name":"Large","extra":6000}]','{"Normal","Less sugar","Tanpa gula"}'),
  ('latte','Caffe Latte','Kopi',28000,null,'photo-1511920170033-f8396924c348','[{"name":"Regular","extra":0},{"name":"Large","extra":6000}]','{"Normal","Less sugar","Tanpa gula"}'),
  ('americano','Americano','Kopi',22000,null,'photo-1514432324607-a09d9b4aefdd','[{"name":"Regular","extra":0},{"name":"Large","extra":5000}]','{"Tanpa gula","Normal"}'),
  ('matcha','Matcha Cloud','Non-Kopi',30000,'Baru','photo-1515823064-d6e0c04616a7','[{"name":"Regular","extra":0},{"name":"Large","extra":6000}]','{"Normal","Less sugar","Tanpa gula"}'),
  ('chocolate','Cokelat Hangat','Non-Kopi',27000,null,'photo-1542990253-0b8be7e9c4bb','[{"name":"Regular","extra":0},{"name":"Large","extra":5000}]','{"Normal","Less sugar","Tanpa gula"}'),
  ('lemon','Es Teh Lemon','Non-Kopi',20000,null,'photo-1513558161293-cdaf765edfd7','[{"name":"Regular","extra":0},{"name":"Large","extra":4000}]','{"Normal","Less sugar","Tanpa gula"}'),
  ('croissant','Butter Croissant','Camilan',19000,null,'photo-1555507036-ab1f4038808a','[{"name":"Reguler","extra":0}]','{}'),
  ('toast','Roti Panggang','Makanan',26000,null,'photo-1525351484163-7529414344d8','[{"name":"Reguler","extra":0}]','{}'),
  ('chicken','Chicken Sandwich','Makanan',34000,'Favorit','photo-1553909489-cd47e0ef937f','[{"name":"Reguler","extra":0}]','{}'),
  ('brownie','Fudge Brownie','Camilan',22000,null,'photo-1606313564200-e75d5e30476c','[{"name":"Reguler","extra":0}]','{}'),
  ('donut','Donat Gula','Camilan',15000,null,'photo-1551024506-0bcf8e8e4c0d','[{"name":"Reguler","extra":0}]','{}')
on conflict (id) do nothing;
