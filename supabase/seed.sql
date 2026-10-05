-- Seed file untuk akun staf dan profil awal.
-- Jalankan setelah schema utama selesai dieksekusi.

-- Contoh: buat profil admin berdasarkan email auth.users
insert into public.staff_profiles (user_id, display_name, role)
select id, 'Admin Kedai', 'admin'
from auth.users
where email = 'admin@kedai.example'
on conflict (user_id) do update
set display_name = excluded.display_name,
    role = excluded.role;

-- Contoh: buat profil kasir berdasarkan email auth.users
insert into public.staff_profiles (user_id, display_name, role)
select id, 'Kasir 1', 'cashier'
from auth.users
where email = 'kasir1@kedai.example'
on conflict (user_id) do update
set display_name = excluded.display_name,
    role = excluded.role;

-- Contoh: ubah pengaturan pajak/layanan opsional
update public.cafe_settings
set tax_rate_bps = 0,
    service_rate_bps = 0,
    updated_at = now()
where singleton = true;
