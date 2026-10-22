USE NusantaraFresh_DW;
-- CLEANING stg_penjualan
UPDATE stg_penjualan
SET Tgl_Transaksi = TRY_CAST(Tgl_Transaksi AS DATE)
WHERE TRY_CAST(Tgl_Transaksi AS DATE) IS NOT NULL;

UPDATE stg_penjualan
SET Total_Penjualan = CAST(
    CAST(REPLACE(Qty_kg, ',', '') AS BIGINT) *
    CAST(REPLACE(Harga_Satuan, ',', '') AS BIGINT)
AS NVARCHAR(50))
WHERE (Total_Penjualan IS NULL OR Total_Penjualan = '')
    AND Qty_kg IS NOT NULL
    AND Harga_Satuan IS NOT NULL;

UPDATE stg_penjualan
SET Kategori = CONCAT(UPPER(LEFT(LOWER(Kategori),1)),
		SUBSTRING(LOWER(Kategori),2,LEN(Kategori)));
UPDATE stg_penjualan
SET Kota = CONCAT(UPPER(LEFT(LOWER(Kota),1)),
		SUBSTRING(LOWER(Kota),2,LEN(Kota)));

ALTER TABLE stg_penjualan
ADD Bulan_Num INT, Bulan_Nama VARCHAR(20), Tahun INT;

UPDATE stg_penjualan
SET Bulan_Num   = MONTH(TRY_CAST(Tgl_Transaksi AS DATE)),
	Bulan_Nama  = DATENAME(MONTH, TRY_CAST(Tgl_Transaksi AS DATE)),
	Tahun		= YEAR(TRY_CAST(Tgl_Transaksi AS DATE));


SELECT *
FROM stg_penjualan;

-- CLEANING Gudang
UPDATE stg_gudang
SET Qty_Tersedia = [Qty_Masuk_kg] * (1 - [Susut]/100.0)
WHERE Qty_Tersedia IS NULL OR Qty_Tersedia = 0;

ALTER TABLE stg_gudang 
ADD Flag_Susut_Abnormal BIT DEFAULT 0;

UPDATE stg_gudang
SET Flag_Susut_Abnormal = 1
WHERE [Susut] > 8.0; 

SELECT *
FROM stg_gudang;

-- CLEANING Komplain
UPDATE stg_komplain
SET Lama_Resolve_hari = DATEDIFF(DAY,
	TRY_CAST(Tgl_Masuk AS DATE),
	TRY_CAST(Tgl_Resolve AS DATE))
WHERE Tgl_Resolve IS NOT NULL
	AND Lama_Resolve_hari iS NULL;

ALTER TABLE stg_komplain ADD Flag_SLA_Breach BIT DEFAULT 0;

UPDATE stg_komplain
SET Flag_SLA_Breach = 1
WHERE (Prioritas = 'CRITICAL' AND Lama_Resolve_hari > 3)
	OR (Prioritas= 'HIGH'     AND Lama_Resolve_hari > 5)
	OR Status = 'PENDING';

SELECT *
FROM stg_penjualan;

USE NusantaraFresh_DW;

SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME != 'sysdiagrams'
ORDER BY TABLE_NAME;

-- Normalisasi: Membuat Tabel Dimensi & Fakta
SELECT DISTINCT Produk, Kategori
INTO dim_produk
FROM stg_penjualan;
ALTER TABLE dim_produk ADD id_produk INT IDENTITY(1,1) PRIMARY KEY;

SELECT DISTINCT (Nama_Customer), Kota
INTO dim_pelanggan
FROM stg_penjualan;
ALTER TABLE dim_pelanggan ADD id_pelanggan INT IDENTITY(1,1) PRIMARY KEY;

SELECT DISTINCT	
	TRY_CAST(Tgl_Transaksi AS DATE) AS tanggal,
	MONTH(TRY_CAST(Tgl_Transaksi AS DATE)) AS bulan,
	DATENAME(MONTH,TRY_CAST(Tgl_Transaksi AS DATE)) AS nama_bulan,
	DATEPART(WEEK,TRY_CAST(Tgl_Transaksi AS DATE)) AS minggu,
	YEAR(TRY_CAST(Tgl_Transaksi AS DATE)) AS tahun
INTO dim_tanggal
FROM stg_penjualan;

SELECT
    s.ID_Transaksi,
    TRY_CAST(s.Tgl_Transaksi AS DATE) AS tanggal,
    p.id_produk, c.id_pelanggan,
    s.[Qty_kg], s.Harga_Satuan,
    ISNULL(
        TRY_CAST(s.Total_Penjualan AS BIGINT),
        CAST(REPLACE(s.[Qty_kg], ',', '') AS BIGINT) *
        CAST(REPLACE(s.Harga_Satuan, ',', '') AS BIGINT)
    ) AS total_penjualan,
    s.Sales_Rep, s.Channel,
    s.[Status_Bayar], s.Bulan_Num, s.Tahun
INTO fact_penjualan 
FROM stg_penjualan s
LEFT JOIN dim_produk p ON s.Produk = p.Produk
LEFT JOIN dim_pelanggan c ON s.[Nama_Customer] = c.[Nama_Customer];

SELECT TOP 10
    ID_Transaksi,
    tanggal,
    id_produk,
    id_pelanggan,
    Qty_kg,
    Harga_Satuan,
    total_penjualan
FROM fact_penjualan;

-- || BAGIAN ANALISIS ||----------------------------------------------------------------
SELECT 
    c.Nama_Customer, c.Kota,
    SUM(f.total_penjualan) AS total_revenue,
    SUM(CASE WHEN f.Bulan_Num=1 THEN f.total_penjualan ELSE 0 END) AS jan,
    SUM(CASE WHEN f.Bulan_Num=2 THEN f.total_penjualan ELSE 0 END) AS feb,
    SUM(CASE WHEN f.Bulan_Num=3 THEN f.total_penjualan ELSE 0 END) AS mar,
    COUNT(DISTINCT f.ID_Transaksi) AS jumlah_transaksi,
    AVG(f.total_penjualan) AS avg_per_transaksi
FROM fact_penjualan f
JOIN dim_pelanggan c ON f.id_pelanggan = c.id_pelanggan
GROUP BY c.Nama_Customer, c.Kota
ORDER BY total_revenue DESC;

SELECT
    p.Produk,
    p.Kategori,
    SUM(f.total_penjualan)                              AS revenue_total,
    SUM(CAST(REPLACE(f.Qty_kg, ',', '') AS BIGINT))     AS volume_kg,
    COUNT(DISTINCT f.ID_Transaksi)                      AS jumlah_order,
    ISNULL(MAX(k.jumlah_komplain), 0)                        AS jumlah_komplain,
    ISNULL(MAX(k.total_kompensasi), 0)                       AS total_kompensasi,
    MAX (g.avg_susut)                                    AS avg_susut,
    ISNULL(MAX(g.batch_susut_abnormal), 0)                   AS batch_susut_abnormal
FROM fact_penjualan f
JOIN dim_produk p 
    ON f.id_produk = p.id_produk

-- Pre-aggregate komplain dulu sebelum JOIN
LEFT JOIN (
    SELECT 
        Produk_Terkait,
        COUNT(ID_Komplain)      AS jumlah_komplain,
        SUM(ISNULL(Kompensasi,0)) AS total_kompensasi
    FROM stg_komplain
    GROUP BY Produk_Terkait
) k ON k.Produk_Terkait = p.Produk

-- Pre-aggregate gudang dulu sebelum JOIN
LEFT JOIN (
    SELECT
        Nama_Produk,
        AVG(Susut)                          AS avg_susut,
        SUM(CAST(Flag_Susut_Abnormal AS INT)) AS batch_susut_abnormal
    FROM stg_gudang
    GROUP BY Nama_Produk
) g ON g.Nama_Produk = p.Produk

GROUP BY 
    p.Produk, 
    p.Kategori
ORDER BY revenue_total DESC;
-- ||| Ngecek doank, bukan analisis
SELECT *
FROM stg_gudang;

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('fact_penjualan', 'stg_gudang', 'stg_komplain')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

SELECT COLUMN_NAME
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'stg_gudang'
  AND COLUMN_NAME LIKE 'Flag%'
ORDER BY ORDINAL_POSITION;

-- Lanjut analisis
SELECT 
    g.[Nama_Produk],
    AVG(g.[Susut])                  AS avg_susut,
    MAX(g.[Susut])                  AS max_susut,
    COUNT(g.ID_Batch)               AS jumlah_batch,
    COUNT(k.ID_Komplain)            AS total_komplain_kualitas,
    SUM(ISNULL(k.Kompensasi,0))     AS total_kompensasi,
    CASE
        WHEN AVG (g.[Susut]) > 10 THEN 'Tinggi'
        WHEN AVG (g.[Susut]) > 5 THEN 'Sedang'
        ELSE 'Normal'
    END AS kategori_risiko
FROM stg_gudang g
LEFT JOIN stg_komplain k
    ON k.[Produk_Terkait] = g.[Nama_Produk]
    AND k.[Kategori_Komplain] LIKE '%Kualitas%'
GROUP BY g.[Nama_Produk]
ORDER BY avg_susut DESC;

SELECT
    MONTH (TRY_CAST(Tgl_Order AS DATE)) AS bulan,
    DATENAME(MONTH,TRY_CAST(Tgl_Order AS DATE)) AS nama_bulan,
    COUNT(*) AS total_pengiriman,
    SUM(CASE WHEN Status='Terlambat' THEN 1 ELSE 0 END) AS terlambat,
    CAST(ROUND(
    100.0 * SUM(CASE WHEN Status='Terlambat' THEN 1 ELSE 0 END)
    / COUNT(*), 1)
AS DECIMAL(5,1)) AS pct_terlambat,
    AVG(ISNULL([Biaya_Kirim],0)) AS avg_biaya_kirim
FROM stg_logistik
GROUP BY
    MONTH(TRY_CAST(Tgl_Order AS DATE)),
    DATENAME(MONTH, TRY_CAST(Tgl_Order AS DATE))
ORDER BY bulan;

SELECT
    Sales_Rep, Channel,
    COUNT(DISTINCT ID_Transaksi) AS jumlah_deal,
    SUM(total_penjualan) AS total_revenue,
    AVG(total_penjualan) AS avg_deal_size,
    SUM([Qty_kg]) AS total_volume_kg,
    SUM(CASE WHEN [Status_Bayar]='Pending'
            THEN total_penjualan ELSE 0 END) AS nilai_pending
FROM fact_penjualan
GROUP BY Sales_Rep, Channel
ORDER BY total_revenue DESC;

SELECT
    Sales_Rep, Channel,
    COUNT(DISTINCT ID_Transaksi)                            AS jumlah_deal,
    SUM(CAST(total_penjualan AS BIGINT))                    AS total_revenue,
    AVG(CAST(total_penjualan AS BIGINT))                    AS avg_deal_size,
    SUM(CAST(REPLACE(Qty_kg, ',', '') AS BIGINT))           AS total_volume_kg,
    SUM(CASE WHEN Status_Bayar = 'Pending'
             THEN CAST(total_penjualan AS BIGINT)
             ELSE 0 END)                                    AS nilai_pending
FROM fact_penjualan
GROUP BY Sales_Rep, Channel
ORDER BY total_revenue DESC;


SELECT tanggal, bulan, nama_bulan, tahun
FROM dim_tanggal
ORDER BY tanggal;

-- Update nama_bulan di dim_tanggal ke Bahasa Indonesia
UPDATE dim_tanggal
SET nama_bulan = CASE bulan
    WHEN 1  THEN 'Januari'
    WHEN 2  THEN 'Februari'
    WHEN 3  THEN 'Maret'
    WHEN 4  THEN 'April'
    WHEN 5  THEN 'Mei'
    WHEN 6  THEN 'Juni'
    WHEN 7  THEN 'Juli'
    WHEN 8  THEN 'Agustus'
    WHEN 9  THEN 'September'
    WHEN 10 THEN 'Oktober'
    WHEN 11 THEN 'November'
    WHEN 12 THEN 'Desember'
END;

-- Verifikasi
SELECT tanggal, bulan, nama_bulan, tahun
FROM dim_tanggal
ORDER BY tanggal;

SELECT 
    Bulan_Num,
    COUNT(ID_Transaksi) AS jumlah_transaksi,
    SUM(total_penjualan) AS revenue
FROM fact_penjualan
GROUP BY Bulan_Num
ORDER BY Bulan_Num;

SELECT *
FROM fact_penjualan;

SELECT 
    p.Produk,
    p.Kategori,
    SUM(f.total_penjualan) AS total_revenue,
    COUNT(f.ID_Transaksi)  AS jumlah_order
FROM fact_penjualan f
JOIN dim_produk p ON f.id_produk = p.id_produk
GROUP BY p.Produk, p.Kategori
ORDER BY total_revenue ASC;

-- Tambah kolom bulan ke stg_komplain
ALTER TABLE stg_komplain
ADD Bulan_Masuk INT, Nama_Bulan_Masuk NVARCHAR(20);

-- Isi dengan data dari Tgl_Masuk
UPDATE stg_komplain
SET 
    Bulan_Masuk = MONTH(Tgl_Masuk),
    Nama_Bulan_Masuk = CASE MONTH(Tgl_Masuk)
        WHEN 1 THEN 'Januari'
        WHEN 2 THEN 'Februari'
        WHEN 3 THEN 'Maret'
    END;

-- Verifikasi
SELECT ID_Komplain, Tgl_Masuk, Bulan_Masuk, 
       Nama_Bulan_Masuk, Kategori_Komplain
FROM stg_komplain
ORDER BY Bulan_Masuk;

-- Mengecek kebenaran komplain apel fuji
SELECT Produk_Terkait, COUNT(*) AS komplain
FROM stg_komplain
GROUP BY Produk_Terkait
ORDER BY komplain DESC;

-- cek jumlah % pengiriman terlambat per bulan 
SELECT 
    MONTH(TRY_CAST(Tgl_Order AS DATE)) AS bulan,
    COUNT(*) AS jumlah_baris
FROM stg_logistik
GROUP BY MONTH(TRY_CAST(Tgl_Order AS DATE))
ORDER BY bulan;

SELECT *
FROM stg_logistik;
