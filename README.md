# Kasir Cafe

Aplikasi kasir web untuk satu kedai dengan akun staf, menu dan transaksi bersama melalui Supabase.

## Menyiapkan Supabase

1. Buat proyek Supabase, lalu buka **SQL Editor** dan jalankan seluruh isi [`supabase/schema.sql`](./supabase/schema.sql). Skrip membuat tabel, Row Level Security, fungsi transaksi atomik, dan menu contoh. Untuk bootstrap lewat Supabase CLI, gunakan migration [`supabase/migrations/20261006195005_initial_schema.sql`](./supabase/migrations/20261006195005_initial_schema.sql), yang disinkronkan dengan skema tersebut. Pilih salah satu cara saja; jangan jalankan keduanya pada database yang sama.
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

## Mengaktifkan transaksi offline

Pada database yang sudah memakai skema lama, jalankan versi terbaru [`supabase/schema.sql`](./supabase/schema.sql) satu kali lewat SQL Editor sebelum menerbitkan frontend ini. Perubahan tersebut memperbarui fungsi transaksi agar sinkronisasi offline memeriksa kembali harga, pajak, biaya layanan, dan waktu transaksi. Jika migration awal sudah tercatat oleh Supabase CLI, mengubah file migration lama tidak menjalankannya ulang; gunakan `schema.sql` untuk memperbarui database yang sudah ada. Transaksi dan riwayat yang tersimpan tidak dihapus oleh pembaruan fungsi ini.

Setelah itu, buka aplikasi saat online, login dengan akun kasir, dan tunggu hingga katalog berhasil disinkronkan. Gunakan HTTPS dan browser yang mendukung IndexedDB. Saat offline, hanya tunai yang dapat dicatat. Transaksi antrean diikat ke akun kasir pembuatnya dan harus disinkronkan dengan akun yang sama. Waktu perangkat harus benar; transaksi lebih dari 30 hari atau dengan waktu perangkat yang tidak wajar perlu pemeriksaan. Jika katalog/harga/pajak berubah atau akun tidak lagi berhak, aplikasi mempertahankan transaksi di perangkat untuk pemeriksaan manual; jangan menghapus atau mengubah data situs. Data browser tidak terenkripsi, jadi lindungi perangkat dengan kunci layar dan jangan tinggalkan kasir terbuka.

## Aturan operasional

- Harga, pilihan ukuran/gula, dan status ketersediaan menu dibaca dari database. Admin dapat menambah menu, menyembunyikan/menampilkan kembali menu, atau menghapus menu yang belum memiliki riwayat transaksi melalui tab **Menu**. Produk yang telah terjual tidak bisa dihapus karena terhubung ke riwayat transaksi; sembunyikan produk tersebut agar riwayat tetap utuh. Foto menu dapat berupa ID Unsplash, URL HTTPS, atau hasil kamera/perangkat yang dikompres dan disimpan bersama data menu serta katalog offline pada browser. Tarif pajak/layanan diatur dalam basis poin di `cafe_settings` (contoh `1000` = 10%); nilai awal keduanya 0 agar aplikasi tidak mengasumsikan tarif kedai.
- Pembuatan transaksi dan item pesanan dilakukan atomik di database; server menghitung ulang harga dan total. ID permintaan transaksi mencegah transaksi tercatat ganda saat browser mencoba ulang setelah koneksi terputus. Jika layar menyatakan hasil transaksi belum pasti, tekan **Coba lagi** dan jangan muat ulang/menutup tab sampai server menjawab.
- Tunai ditandai lunas setelah jumlah uang diterima divalidasi. QRIS/EDC **belum terhubung ke payment gateway**: transaksi dicatat sebagai menunggu dan harus dikonfirmasi staf setelah dana benar-benar terlihat di aplikasi merchant atau mesin EDC.
- Data menu dan transaksi online tersinkron lewat Supabase; halaman memuat ulang data tiap 30 detik dan saat kembali aktif. Login pertama, pengelolaan menu, laporan, QRIS/EDC, dan konfirmasi pembayaran memerlukan internet.
- **Mode offline satu perangkat:** setelah aplikasi pernah dibuka online, kasir sudah login, katalog tersimpan, dan browser mendukung IndexedDB, kasir dapat mencatat transaksi **tunai saja** tanpa internet. Transaksi dan harga yang dipakai disimpan lokal di perangkat; struk menandainya belum tersinkron. Saat online kembali, transaksi dikirim otomatis atau lewat tombol **Sinkronkan**. Server memeriksa ulang harga, pilihan menu, pajak, dan layanan sebelum menyimpan. Jika ada perubahan, transaksi tetap tersimpan lokal dengan status perlu pemeriksaan dan tidak diam-diam diubah atau dihapus. Laporan Supabase belum memuat transaksi lokal sebelum sinkronisasi berhasil. Kembali gunakan akun kasir yang sama untuk menyinkronkan.
- Offline tidak dapat memproses QRIS/EDC, mengubah menu, atau membuka laporan terbaru. Gunakan HTTPS; transaksi antrean offline hanya tersedia pada browser dan perangkat yang sama. Jangan hapus data situs/browser, mengganti profil browser, atau mengandalkan penyimpanan lokal sebagai backup. Perangkat dapat rusak atau browser dapat menghapus data; siapkan pencatatan dan backup cadangan.
- Laporan dapat difilter per tanggal dan dicetak dari tab **Laporan**. Batas harinya mengikuti zona waktu perangkat kasir; pastikan perangkat menggunakan zona waktu kedai. Filter laporan memerlukan koneksi.
- Kunci anon aman hanya jika RLS tetap aktif. Jangan nonaktifkan RLS atau memberi hak tulis publik. Batasi akses dashboard Supabase dan siapkan prosedur backup database.

## Sebelum dipakai melayani pelanggan

Uji login dan akses role, tambah/nonaktifkan menu, transaksi tunai (termasuk uang kurang/kembalian), QRIS/EDC tertunda dan konfirmasi, serta cetak struk pada printer yang akan digunakan. Untuk mode offline, login dan sinkronkan katalog lebih dahulu, putuskan internet, catat transaksi tunai, muat ulang aplikasi saat masih offline untuk memastikan antrean tetap ada, lalu pulihkan internet dan pastikan transaksi muncul tepat satu kali di laporan. Uji juga bahwa QRIS/EDC tetap tidak dapat dicatat offline dan bahwa perubahan harga/pajak sebelum sinkronisasi menandai transaksi untuk pemeriksaan. Cocokkan tarif, label pajak/layanan, menu, dan alur pemulihan data dengan kebijakan kedai. Integrasi payment gateway, pembatalan/refund dengan audit, dan pengujian printer khusus belum termasuk.
