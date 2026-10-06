# Kasir Cafe

Aplikasi kasir web untuk satu kedai dengan akun staf, menu dan transaksi bersama melalui Supabase.

## Menyiapkan Supabase

1. Buat proyek Supabase, lalu buka **SQL Editor** dan jalankan seluruh isi [`supabase/schema.sql`](./supabase/schema.sql). Skrip membuat tabel, Row Level Security, fungsi transaksi atomik, dan menu contoh.
2. Di **Project Settings → API**, salin Project URL dan anon/public key ke [`supabase-config.js`](./supabase-config.js). Key tersebut memang digunakan browser; **jangan pernah** menaruh `service_role` key di aplikasi.
3. Di **Authentication → Users**, buat akun pengguna admin dan kasir. Pendaftaran publik sebaiknya tetap nonaktif.
4. Tambahkan setiap akun ke tabel profil lewat SQL Editor. Ganti email dan nama sesuai akun:

   ```sql
   insert into public.staff_profiles (user_id, display_name, role)
   select id, 'Admin Kedai', 'admin'
   from auth.users
   where email = 'admin@kedai.example';
   ```

   Gunakan role `cashier` untuk akun kasir. Pengguna tanpa profil staf tidak dapat mengakses menu atau transaksi.
5. Host folder ini pada web server statis dengan HTTPS. Untuk uji lokal, jalankan `python -m http.server 8000` dari folder proyek, lalu buka `http://localhost:8000`.

## Tahap berikutnya setelah setup dasar

Setelah project Supabase dibuat dan skema sudah dijalankan, langkah nyata berikutnya adalah:

1. Isi nilai yang benar di [`supabase-config.js`](./supabase-config.js).
2. Buka **Authentication → Users** lalu buat akun staf yang akan dipakai di kasir.
3. Pastikan profil staf sudah ada di `public.staff_profiles`:

   ```sql
   insert into public.staff_profiles (user_id, display_name, role)
   select id, 'Kasir 1', 'cashier'
   from auth.users
   where email = 'kasir1@kedai.example'
   on conflict (user_id) do update
   set display_name = excluded.display_name,
       role = excluded.role;
   ```

4. Buka aplikasi di browser, lalu login dengan email dan password akun yang baru dibuat.
5. Setelah login berhasil, pilih menu, buat transaksi, lalu pastikan data masuk ke tabel `sales` dan `sale_items`.

> Tanpa URL project dan anon key yang valid, aplikasi tetap akan menolak login karena Supabase belum terhubung. Setelah koneksi hidup, nama kasir dan data menu akan muncul dari database.

## Aturan operasional

- Harga, pilihan ukuran/gula, dan status ketersediaan menu dibaca dari database. Admin dapat menambah menu dan menonaktifkan atau mengaktifkan kembali menu melalui tab **Menu**; menu yang dinonaktifkan tetap disimpan agar riwayat transaksi terjaga. Tarif pajak/layanan diatur dalam basis poin di `cafe_settings` (contoh `1000` = 10%); nilai awal keduanya 0 agar aplikasi tidak mengasumsikan tarif kedai.
- Pembuatan transaksi dan item pesanan dilakukan atomik di database; server menghitung ulang harga dan total. ID permintaan transaksi mencegah transaksi tercatat ganda saat browser mencoba ulang setelah koneksi terputus. Jika layar menyatakan hasil transaksi belum pasti, tekan **Coba lagi** dan jangan muat ulang/menutup tab sampai server menjawab.
- Tunai ditandai lunas setelah jumlah uang diterima divalidasi. QRIS/EDC **belum terhubung ke payment gateway**: transaksi dicatat sebagai menunggu dan harus dikonfirmasi staf setelah dana benar-benar terlihat di aplikasi merchant atau mesin EDC.
- Data tersinkron lewat Supabase; halaman memuat ulang data tiap 30 detik dan saat kembali aktif. Koneksi internet diperlukan untuk masuk dan membuat transaksi.
- **Mode offline terbatas:** setelah aplikasi pernah dibuka online dan kasir sudah login, service worker menyimpan halaman/pustaka aplikasi dan katalog terakhir, sementara keranjang beserta catatan item disimpan di browser. Saat offline, kasir dapat mencari menu dan menyusun pesanan, tetapi checkout, laporan, dan manajemen menu tidak tersedia. Saat koneksi pulih, aplikasi memuat ulang harga, pilihan, serta ketersediaan; item yang sudah tidak tersedia atau pilihannya berubah akan dikeluarkan dari keranjang. Pastikan sinkronisasi berhasil sebelum menerima pembayaran. Gunakan HTTPS (atau localhost); data tersimpan hanya pada browser/perangkat yang sama.
- Laporan harian menggunakan zona waktu perangkat kasir. Pastikan perangkat menggunakan zona waktu kedai.
- Kunci anon aman hanya jika RLS tetap aktif. Jangan nonaktifkan RLS atau memberi hak tulis publik. Batasi akses dashboard Supabase dan siapkan prosedur backup database.

## Sebelum dipakai melayani pelanggan

Uji login beberapa kasir, akses role, tambah/nonaktifkan menu, transaksi tunai (termasuk uang kurang/kembalian), pembayaran QRIS/EDC tertunda dan konfirmasi, retry saat koneksi terganggu, sinkronisasi antarkasir, laporan, serta cetak struk pada printer yang akan digunakan. Cocokkan tarif, label pajak/layanan, dan menu dengan kebijakan kedai. Integrasi payment gateway, dukungan offline, pembatalan/refund dengan audit, dan pengujian printer khusus belum termasuk.
