
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from sqlalchemy import create_engine

engine = create_engine(
    'mssql+pyodbc://localhost/NusantaraFresh_DW'
    '?driver=ODBC+Driver+17+for+SQL+Server'
    '&trusted_connection=yes'
)

df_gudang   = pd.read_sql('SELECT * FROM stg_gudang', engine)
df_komplain = pd.read_sql('SELECT * FROM stg_komplain', engine)

susut_avg = df_gudang.groupby('Nama_Produk')['Susut'].mean()

komplain_cnt = (
    df_komplain[
        df_komplain['Kategori_Komplain'].str.contains('Kualitas', na=False)
    ]
    .groupby('Produk_Terkait')
    .size()
)

corr_df = pd.DataFrame({
    'avg_susut'  : susut_avg,
    'n_komplain' : komplain_cnt
}).dropna()

pearson_r = corr_df['avg_susut'].corr(corr_df['n_komplain'])
print(f'\n Koefisien Korelasi Pearson: {pearson_r:.3f}')

fig, ax = plt.subplots(figsize=(9, 6))

ax.scatter(
    corr_df['avg_susut'],
    corr_df['n_komplain'],
    color='steelblue', s=100, zorder=3
)

for produk, row in corr_df.iterrows():
    ax.annotate(
        produk,
        (row['avg_susut'], row['n_komplain']),
        textcoords='offset points',
        xytext=(6, 4),
        fontsize=8
    )

m, b = np.polyfit(corr_df['avg_susut'], corr_df['n_komplain'], 1)
x_line = np.linspace(corr_df['avg_susut'].min(),
                     corr_df['avg_susut'].max(), 100)
ax.plot(x_line, m * x_line + b,
        color='tomato', linestyle='--', linewidth=1.5,
        label='Garis Tren')

ax.set_title(
    f'Korelasi Susut Gudang vs Komplain Kualitas\n'
    f'Pearson r = {pearson_r:.3f} (Korelasi Lemah)',
    fontsize=13, fontweight='bold'
)
ax.set_xlabel('Rata-rata Susut (%)', fontsize=11)
ax.set_ylabel('Jumlah Komplain Kualitas', fontsize=11)
ax.legend()
ax.grid(True, linestyle='--', alpha=0.4)

plt.tight_layout()
plt.savefig('korelasi_susut_komplain.png', dpi=150)
plt.show()
print('Chart tersimpan: korelasi_susut_komplain.png')


df_jual = pd.read_sql('''
    SELECT
        f.ID_Transaksi,
        f.total_penjualan,
        f.Qty_kg,
        f.Harga_Satuan,
        f.Bulan_Num,
        f.Tahun,
        f.Channel,
        f.Sales_Rep,
        f.Status_Bayar,
        p.Produk,
        p.Kategori
    FROM fact_penjualan f
    JOIN dim_produk p ON f.id_produk = p.id_produk
''', engine)

df_jual['Harga_Satuan'] = pd.to_numeric(
    df_jual['Harga_Satuan'].astype(str).str.replace(',', '', regex=False),
    errors='coerce'
)
df_jual['Qty_kg'] = pd.to_numeric(
    df_jual['Qty_kg'].astype(str).str.replace(',', '', regex=False),
    errors='coerce'
)
df_jual['total_penjualan'] = pd.to_numeric(
    df_jual['total_penjualan'], errors='coerce'
)

def detect_outlier(group):
    Q1  = group.quantile(0.25)
    Q3  = group.quantile(0.75)
    IQR = Q3 - Q1
    return (group < Q1 - 1.5 * IQR) | (group > Q3 + 1.5 * IQR)

df_jual['is_outlier'] = (
    df_jual
    .groupby('Produk')['Harga_Satuan']
    .transform(detect_outlier)
)

outliers = df_jual[df_jual['is_outlier']]
print(f'\n Ditemukan {len(outliers)} transaksi harga outlier')
print(outliers[['ID_Transaksi', 'Produk', 'Harga_Satuan']].to_string())

produk_list = sorted(df_jual['Produk'].unique())
data_per_produk = [
    df_jual[df_jual['Produk'] == p]['Harga_Satuan'].dropna().values
    for p in produk_list
]

fig, ax = plt.subplots(figsize=(14, 6))

bp = ax.boxplot(
    data_per_produk,
    labels=produk_list,
    patch_artist=True,
    boxprops=dict(facecolor='steelblue', alpha=0.6),
    medianprops=dict(color='navy', linewidth=2),
    flierprops=dict(marker='o', color='tomato',
                    markerfacecolor='tomato', markersize=7)
)

ax.set_title(
    'Distribusi Harga Satuan per Produk\n'
    '(Titik merah = outlier IQR)',
    fontsize=13, fontweight='bold'
)
ax.set_xlabel('Produk', fontsize=11)
ax.set_ylabel('Harga Satuan (Rp)', fontsize=11)
ax.tick_params(axis='x', rotation=45)
ax.grid(True, linestyle='--', alpha=0.4, axis='y')
ax.yaxis.set_major_formatter(
    plt.FuncFormatter(lambda x, _: f'Rp {x:,.0f}')
)

plt.tight_layout()
plt.savefig('outlier_harga_boxplot.png', dpi=150)
plt.show()
print('Chart tersimpan: outlier_harga_boxplot.png')

df_tren = (
    df_jual
    .groupby(['Bulan_Num', 'Channel'])
    .agg(
        revenue    = ('total_penjualan', 'sum'),
        transaksi  = ('ID_Transaksi',    'count')
    )
    .reset_index()
)

monthly = df_jual.groupby('Bulan_Num')['total_penjualan'].sum()
growth  = monthly.pct_change() * 100

print('\n Revenue per Bulan per Channel:')
print(df_tren.to_string(index=False))

print('\n Month-over-Month Growth (%):')
print(growth.round(1).to_string())

print('\n Visualisasi tren revenue → Power BI Dashboard')


print('\n==============================')
print('Python EDA NusantaraFresh selesai.')
print('Output files:')
print('  - korelasi_susut_komplain.png')
print('  - outlier_harga_boxplot.png')
print('==============================')