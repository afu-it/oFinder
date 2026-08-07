<div align="center">

<img src="docs/assets/logo.png" width="160" alt="Logo oFinder">

# oFinder

Pengurus fail macOS yang salin ke SMB tanpa masalah.

[![Version](https://img.shields.io/badge/versi-0.0.1-blue)](https://github.com/afu-it/oFinder/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#keperluan)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](#bina-dari-sumber)
[![UI](https://img.shields.io/badge/UI-AppKit-8A2BE2)](#seni-bina)
[![Transfers](https://img.shields.io/badge/pemindahan-rsync-2E8B57)](#kenapa-rsync-boleh-finder-tak-boleh)

[English](README.md) · **Bahasa Melayu**

</div>

---

## Kenapa app ini wujud

Salin folder besar ke NAS atau Samba share guna Finder, lambat laun keluar benda ini:

> *"The operation can't be completed because an unexpected error occurred (error code -36)."*

Kadang-kadang tiada ralat langsung. Pemindahan tersangkut separuh jalan dan tinggalkan fail separuh siap atas share. Puncanya: Finder berkeras nak salin metadata khusus macOS (resource fork, extended attribute, entri `.DS_Store`) bersama data fail, dan banyak konfigurasi SMB menolak tulisan itu.

oFinder ialah pengurus fail yang hantar setiap operasi salin dan pindah melalui `rsync`, bukan API salin Finder. Pemindahan ke Samba share siap sampai habis, dan kalau terputus, ia sambung semula, bukan mula dari kosong.

## Kenapa rsync boleh, Finder tak boleh

macOS memang sediakan `/usr/bin/rsync`. oFinder panggil ia begini:

```
rsync -a -P [--ignore-existing] [--remove-source-files] <sumber> <destinasi>/
```

- `-a` (mod arkib) kekalkan permission, timestamp dan symlink tanpa cuba tolak resource fork macOS yang Samba tolak
- `-P` sambung semula pemindahan terputus dan lapor kemajuan setiap fail
- `--ignore-existing` salin tanpa tindih bila tiada pilihan ganti dibuat
- `--remove-source-files` padam sumber hanya selepas destinasi siap ditulis penuh, jadi operasi pindah tak akan hilangkan data separuh jalan

## Ciri-ciri

**Pemindahan**
- Salin dan pindah melalui rsync, dengan tetingkap kemajuan yang tunjuk kelajuan dan ETA
- Cancel betul-betul batal: proses rsync dan anak prosesnya dihentikan, bukan ditinggal
- Cut, copy, paste, termasuk fail yang disalin dari Finder
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
- Terjemahan Inggeris dan Sepanyol

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

## Kredit

oFinder bermula sebagai fork [r2_finder](https://github.com/carmonac/r2_finder) oleh Carlos Carmona, kemudian ambil nama dan garis versi sendiri. Idea rsync-dahulu datang dari projek itu.
