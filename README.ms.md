<div align="center">

<img src="docs/assets/logo.png" width="160" alt="Logo oFinder">

# oFinder

Pengurus fail macOS dengan benda-benda kecil yang Finder tak mahu buat.

[![Version](https://img.shields.io/badge/versi-0.0.1-blue)](https://github.com/afu-it/oFinder/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#keperluan)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](#bina-dari-sumber)
[![UI](https://img.shields.io/badge/UI-AppKit-8A2BE2)](#seni-bina)
[![Transfers](https://img.shields.io/badge/pemindahan-rsync-2E8B57)](#pemindahan-melalui-rsync)

[English](README.md) · **Bahasa Melayu**

</div>

---

## Kenapa app ini wujud

Dua puluh tahun Finder tak mahu buat benda-benda kecil yang sama. Tak boleh cut fail dengan Cmd+X. Tak boleh pilih dan salin laluan dari bar tajuk. Dan ia lupa cara anda suka paparan: susunan sort, susun atur lajur, saiz tetingkap.

oFinder ialah pengganti Finder yang dibina khusus untuk benda-benda itu:

- Cut dengan Cmd+X, paste untuk pindah, macam semua platform lain
- Bar laluan yang boleh dipilih dan disalin laluannya
- Paparan yang ingat pilihan anda: susunan sort, susunan dan lebar lajur, mod paparan, saiz tetingkap semuanya kekal
- Recents yang buka dengan fail terbaru di atas

## Pemindahan melalui rsync

Enjin pemindahan diwarisi dari projek asal fork ini: setiap salin dan pindah berjalan melalui `/usr/bin/rsync`, bukan API salin Finder.

```
rsync -a -P [--ignore-existing] [--remove-source-files] <sumber> <destinasi>/
```

Kesan sampingan yang menyenangkan: salinan ke Samba/NAS siap dengan boleh dipercayai (tiada error -36, yang Finder cetuskan sebab tolak metadata macOS yang banyak server SMB tolak), pemindahan terputus sambung semula bukan mula dari kosong, dan operasi pindah padam sumber hanya selepas destinasi siap ditulis penuh.

## Ciri-ciri

**Pemindahan**
- Salin dan pindah melalui rsync, dengan tetingkap kemajuan yang tunjuk kelajuan dan ETA
- Cancel betul-betul batal: proses rsync dan anak prosesnya dihentikan, bukan ditinggal
- Cut dengan Cmd+X, copy dan paste, termasuk fail yang disalin dari Finder; item yang di-cut jadi pudar sampai ia di-paste atau dilepaskan
- Drag and drop antara tetingkap dan ke atau dari app lain

**Melayar**
- Paparan grid, senarai dan lajur; app ingat yang mana anda guna terakhir
- Lajur senarai (Name, Date Modified, Type, Size) boleh ditarik ikut susunan sendiri, dan susunan, lebar serta pilihan sort semuanya kekal
- Recents terbuka dengan yang terbaru di atas
- Tab, panel bersebelahan dan berbilang tetingkap bebas
- Sidebar dengan favorites dan volume yang dilekap, dikemas kini bila mount dan unmount
- Undur dan maju guna butang toolbar, Cmd+[ dan Cmd+], atau butang tepi tetikus
- Bar laluan yang memang boleh disalin laluannya

**Fail**
- Pratonton Quick Look dengan Space
- Namakan semula terus di tempat, folder baharu (Cmd+Shift+N), Get Info
- Cipta dan ekstrak arkib 7z
- Tunjuk atau sembunyi dotfile
- Antara muka ikut bahasa sistem Mac anda

## Pasang

Belum ada release berbungkus. oFinder mula semula pada v0.0.1 bawah nama sendiri, dan DMG akan muncul di [halaman releases](https://github.com/afu-it/oFinder/releases) bila siap dibina. Buat masa ini, bina dari sumber ikut langkah di bawah.

App ini tidak dinotarikan, jadi macOS kuarantin ia pada pelancaran pertama. Buang flag itu sebelum buka:

```bash
xattr -d com.apple.quarantine /Applications/oFinder.app
```

Sesetengah folder (Desktop, Documents, Trash dan lain-lain) kekal tak boleh dibaca selagi app tidak diberi Full Disk Access dalam System Settings → Privacy & Security.

## Keperluan

- macOS 13 ke atas
- Toolchain Swift 6.0 (Xcode command line tools) untuk bina dari sumber

## Bina dari sumber

```bash
# Jalan terus (debug; guna bin/rsync dan bin/7zz dalam repo)
swift run

# Build release
swift build -c release

# Cipta oFinder.app dalam .build/ dan buka
Scripts/bundle.sh
open ".build/oFinder.app"

# Ujian unit (servis: penyenaraian, pemindahan, arkib, parser)
swift test
```

Bundle `.app` itu lengkap sendiri; salin `.build/oFinder.app` ke mana-mana untuk pasang. Kalau nak beri Full Disk Access, jalankan `Scripts/make-signing-cert.sh` sekali dulu supaya setiap build kekal identiti tandatangan yang sama, dan pasang guna `Scripts/install.sh`, bukan padam bundle lama.

## Seni bina

App ini 100% Swift, dipindahkan dari Zig dan Objective-C (ceritanya dalam `SWIFT_MIGRATION.md`), dan dibina dalam mod bahasa Swift 6 dengan strict concurrency.

| Lapisan | Tanggungjawab |
|---------|---------------|
| `Sources/OFinderServices/` | Servis sistem fail: penyenaraian, pemindahan rsync, padam, mkdir, namakan semula, volume, arkib 7z |
| `Sources/OFinder/` | App: titik masuk dan UI AppKit (tetingkap, toolbar, sidebar, paparan fail, kemajuan, Quick Look) |

Pemindahan berjalan atas thread latar dalam lapisan servis; UI terima callback kemajuan di main queue dan kekal responsif semasa salinan besar.

## Apa beza dengan yang asal

oFinder bermula sebagai fork [r2_finder](https://github.com/carmonac/r2_finder) oleh Carlos Carmona, dan idea rsync-dahulu datang dari projek itu. Sejak fork, ia dah berubah begini:

| | r2_finder | oFinder |
|---|---|---|
| Cancel semasa pemindahan | rsync terus jalan di belakang | Hentikan proses rsync dan anak prosesnya |
| Undur / maju | Butang toolbar sahaja | Tambah Cmd+[ / Cmd+] dan butang tepi tetikus |
| Bar laluan | Paparan sahaja | Laluan boleh dipilih dan disalin |
| Sort | Reset setiap kali masuk | Pilihan kekal; Recents buka yang terbaru dulu |
| Lajur | Susunan tetap: Name, Size, Date, Kind | Name, Date Modified, Type, Size; tarik untuk susun, susunan dan lebar disimpan |
| Tetingkap | Buka pada lebar minimum setiap kali | Buka cukup lebar untuk semua lajur, kemudian ingat saiz anda |
| Mod paparan | Senarai setiap kali buka | Grid secara lalai, paparan terakhir diingati |
| Identiti app | `com.example.r2finder`, tandatangan ad-hoc | `dev.afuit.ofinder` dengan sijil tandatangan kekal, jadi Full Disk Access tahan rebuild |

## Kredit

Terima kasih kepada Carlos Carmona untuk r2_finder, projek asal yang melahirkan yang ini.
