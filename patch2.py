import re
old = '''  P=$(grep -aoE '/[^ "'"'"']*/venv/bin/python[0-9.]*' "$HERMES_BIN" 2>/dev/null | head -1)'''
new = '''  P=$(grep -aoE '/[^ "'"'"']*/venv/bin/(python[0-9.]*|hermes)' "$HERMES_BIN" 2>/dev/null | head -1)'''
for p in ("/root/hermes-tools/hermes-migrate.sh", "/root/hermes-tools/hermes-upgrade.sh"):
    s = open(p).read()
    if 'venv/bin/python[0-9.]*' in s:
        s = s.replace('venv/bin/python[0-9.]*', 'venv/bin/(python[0-9.]*|hermes)')
        open(p, "w").write(s)
        print(f"{p}: pola grep diperbaiki")
    else:
        print(f"{p}: sudah benar / tidak ketemu pola lama")
# tampilkan blok deteksi untuk verifikasi
s = open("/root/hermes-tools/hermes-upgrade.sh").read()
i = s.index("VENV=\"\"")
print(s[i-90:i+520])
