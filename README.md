# Hermes Tools

Backup, restore/migrasi, dan upgrade **Hermes Agent** — dengan **deteksi otomatis** (HERMES_HOME, user pemilik, install dir, venv, service systemd, port). Tidak perlu mengarahkan path manual.

Terverifikasi pada migrasi nyata: **server produksi → VM App Catalog IDCloudHost** (Hermes v0.21.2, `state.db` 226 MB, 4.220 file).

```bash
# 1) Lihat apa yang terdeteksi (tidak mengubah apa pun)
curl -sS -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/ujang0311/hermes-tools/contents/hermes-migrate.sh?ref=main" | bash -s -- detect

# 2) Backup di server sumber
… | bash -s -- backup                      # arsip zip di /root/hermes-backups
… | bash -s -- backup --transfer root@IP-TUJUAN:/root/hermes-backups

# 3) Restore di server tujuan (platform dimatikan otomatis)
… | bash -s -- restore --archive /root/hermes-<tanggal>.zip --safe-channels

# 4) Update versi (termasuk memperbaiki instalasi yang rusak)
curl -sS -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/ujang0311/hermes-tools/contents/hermes-upgrade.sh?ref=main" | bash -s -- --check
… | bash
```

---

## Berkas di repo ini

| Berkas | Fungsi |
|---|---|
| `hermes-migrate.sh` | aksi `detect` · `backup` · `restore` (auto-detect + rollback otomatis + mode aman platform) |
| `hermes-upgrade.sh` | self-heal instalasi rusak → cek syarat Python → backup → `hermes update` → health check → rollback bila gagal |
| `hermes-remap-paths.py` | memetakan path `HERMES_HOME` lama di database & file (dipakai otomatis saat restore) |
| `scan-hermes-paths.py` | audit: cari path absolut lama sebelum/sesudah restore |
| `verify-restore.py` | verifikasi hasil restore: isi `state.db`, jumlah sesi, sisa path lama |

## Yang dideteksi otomatis

| Aspek | Sumber (berurutan) |
|---|---|
| `HERMES_HOME` | env `HERMES_HOME` → unit systemd → env proses gateway (`/proc/<pid>/environ`) → `hermes config path` → pemindaian (`/home/hermes`, `/root/.hermes`, `/opt/hermes-agent/.hermes`) |
| Install dir & venv | path biner `hermes` (symlink **atau** script wrapper), lalu lokasi umum (`/opt/hermes-agent`, `/usr/local/lib/hermes-agent`) |
| User pemilik | `User=` unit systemd → owner `HERMES_HOME` → user `hermes` → root |
| Service | unit yang **aktif** dulu (`hermes-agent`, `hermes-gateway`) — system scope lalu user scope |
| Port | env unit → `/etc/idch-app-info` → `/etc/hermes-agent/hermes-agent.env` → default 18790 |

Contoh keluaran (VM App Catalog, tanpa flag):

```
  ◆ Deteksi otomatis  0s
    ├ hermes home  /home/hermes  (975M)
    │ └ sumber      unit systemd
    ├ owner        hermes:hermes  (unit system)
    ├ versi        Hermes Agent v0.21.2 (2026.9.11)
    ├ install dir  /opt/hermes-agent  (python 3.12.3)
    ├ service      hermes-agent  (unit system) · port 18790 · active
    └ cli          /opt/hermes-agent/venv/bin/hermes
```

## Hasil uji nyata (nexus-ujang → VM App Catalog `203.145.35.35`)

| Tahap | Hasil |
|---|---|
| Backup (sumber) | arsip **211 MB**, **38 detik** (HERMES_HOME 728 MB) |
| Transfer `scp` | 1,2 detik |
| Verifikasi zip | lolos (fallback Python saat `unzip` tidak ada) |
| Restore | **4.220 file** dipulihkan, 39 detik |
| Remap path | **417.779 baris** database + **33 file** (`/root/.hermes` → `/home/hermes`) |
| `state.db` | **226 MB**, 365 sesi, 23.776 pesan, **0 sisa path lama** |
| Platform | telegram/discord/whatsapp/slack **off** (mode aman) |
| Service | `hermes-agent` **active**, `NRestarts=0` |
| Upgrade (VM App Catalog) | CLI rusak (`ModuleNotFoundError`) → sehat; update **91 detik** ke **v0.21.2** |

## Jebakan yang sudah ditangani

| Gejala | Sebab sebenarnya | Penanganan |
|---|---|---|
| CLI rusak saat user cuma mau backup | instalasi App Catalog rusak | `hermes-migrate.sh` menjalankan self-heal otomatis (lewati dengan `--no-repair`) |
| Env `HERMES_HOME` menunjuk install dir (`/opt/hermes-agent`) | `/etc/profile.d` salah set | kandidat home divalidasi (`config.yaml`/`state.db`); prioritas unit systemd → env valid → proses → CLI → pemindaian |
| Unduhan GitHub sangat lambat (±0,7 MB/menit) | routing VM buruk | relay: `git clone --depth 1` di mesin lain → `tar czf --exclude=.git --exclude=venv` → pipe SSH (`cat x.tgz | ssh root@VM 'tar xzf - -C /root'`) → `--source-archive` |
| `scp: Connection closed` ke VM App Catalog | scp/SFTP ditolak | kirim lewat pipe SSH seperti di atas |
| `ModuleNotFoundError: No module named 'hermes_cli'`, service crash-loop | instalasi App Catalog berupa *editable install* menunjuk `/tmp/hermes-agent-clone` yang hilang saat reboot | `hermes-upgrade.sh` clone ulang ke `$INSTALL_DIR/source` (permanen) + `pip install -e` |
| `hermes import` sukses tapi data tidak terpakai gateway | **login shell** (`bash -lc`) mereset `HERMES_HOME` → import mendarat di install dir | script memakai **non-login shell** + `export HERMES_HOME` + verifikasi lokasi + pemindahan otomatis |
| `PermissionError: … /root/hermes-*.zip` | user service tidak bisa membaca `/root` | arsip disalin ke home user service sebelum import |
| `Failed to fetch updates: dubious ownership` | repo milik root, update jalan sebagai user `hermes` | `chown` + `git config --global --add safe.directory` otomatis |
| Health check bilang gagal padahal gateway sehat | gateway Hermes bisa jalan **tanpa** membuka port TCP | kriteria sehat = service **aktif**; port hanya informasi |
| Deteksi memilih unit yang salah | unit system ada tapi idle; yang aktif unit **user** | deteksi memilih unit aktif lebih dulu (system → user) |
| `unzip: command not found` | paket dasar belum ada di VM | verifikasi zip memakai Python (`zipfile`) |
| Alur berhenti sendiri saat verifikasi menolak arsip | arsip dari versi berbeda | `--skip-verify` bila arsip dipercaya |

## Opsi lengkap

```
hermes-migrate.sh detect
hermes-migrate.sh backup  [--output DIR] [--transfer user@host:/dir] [--dry-run]
hermes-migrate.sh restore --archive FILE
    [--safe-channels] [--no-start] [--skip-verify] [--state-dir DIR] [--user USER] [--dry-run]

hermes-upgrade.sh [--check] [--repair-only] [--branch NAME] [--no-backup] [--no-restart] [--dry-run]
hermes-upgrade.sh --repair-only --source-archive /root/hermes-src.tgz   # VM yang lambat ke GitHub
```

Env: `HERMES_HOME`, `HERMES_SERVICE`, `HERMES_BACKUP_DIR`, `HERMES_START_TIMEOUT`, `HERMES_INSTALL_DIR`.

## Tip: hindari script basi dari cache CDN

`raw.githubusercontent.com` menyajikan cache beberapa menit. Contoh di atas memakai **GitHub API** (`Accept: application/vnd.github.raw`) yang selalu segar. Alternatif: tambahkan `?cb=$(date +%s)`. Cek versi di banner (`Hermes Migrate v1.4.1`).

## Referensi resmi

- FAQ (pindah mesin / ekspor profil): https://hermes-agent.nousresearch.com/docs/reference/faq
- CLI (`hermes backup`, `hermes import`): https://hermes-agent.nousresearch.com/docs/reference/cli-commands
- Checkpoints & rollback: https://hermes-agent.nousresearch.com/docs/user-guide/checkpoints-and-rollback
- Konfigurasi backup pre-update: https://hermes-agent.nousresearch.com/docs/user-guide/configuration
