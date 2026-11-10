# asistent-ai-installer

Kit de instalare pentru asistenți virtuali AI on-premise (Dify + model local) pe Ubuntu Server 24.04. Specificația completă: `SPEC.md`. Reguli de lucru: `CLAUDE.md`.

> Stadiu: **M2**. Implementate: P0 (verificări preliminare) și P1 (sistem de bază, firewall, Docker Engine, driver NVIDIA + Container Toolkit pe GPU). Etapele P2–P7 sunt încă doar planificate.

## Utilizare

```bash
cp config/client.example.yaml clients/<client>/client.yaml   # completați valorile
sudo ./install.sh --config clients/<client>/client.yaml --dry-run
```

Opțiuni: `--dry-run`, `--non-interactive`, `--only P0,P1`, `--skip P5`, `--set cheie=valoare` (ex. `--set inference.profile=cpu`). Lista completă: `./install.sh --help`.

- Căile relative din `client.yaml` se rezolvă față de rădăcina kitului.
- Jurnal: `/var/log/asistent-ai/install.log` (fără secrete; valorile care arată a secrete sunt mascate). În `--dry-run` nu se scrie nimic pe disc.
- Coduri de ieșire: `0` OK, `1` eroare, `2` utilizare greșită (opțiuni, etape, `--set`), `3` e nevoie de repornire (după instalarea driverului NVIDIA; rulați din nou aceeași comandă după `sudo reboot`).
- P0 doar citește sistemul, deci rulează complet și în `--dry-run` (fără testul de descărcare de ~50 MB).
- Firewall: pe lângă 22/80/443, kitul deschide și portul pe care ascultă `sshd`, dacă e altul decât 22, ca să nu vă blocheze accesul (cu avertisment).
- Variabile utile: `AAI_NVIDIA_DRIVER=570-server` fixează versiunea driverului NVIDIA; `AAI_DOWNLOAD_TEST_URL` schimbă fișierul folosit la testul de descărcare.

## Dezvoltare

Necesită `shellcheck`, `bats`, `python3` + `python3-yaml` (prezent implicit pe Ubuntu Server 24.04).

```bash
make lint   # shellcheck pe scripturi și teste
make test   # teste bats din tests/unit/
make vm-test VM_ARGS="--keep"   # instalare în VM Multipass curată, de două ori (idempotență)
```

`make vm-test` verifică la început că `make` și `multipass` sunt instalate. Dacă lipsesc, afișează comanda de instalare și, dacă are drepturi (root sau sudo), se oferă să le instaleze (snap/apt pe Linux, Homebrew pe macOS); cu `VM_ARGS="--yes"` le instalează fără întrebare, iar `VM_ARGS="--check-deps"` face doar această verificare. Implicit creează un VM cu 4 CPU, 16 GB RAM, 80 GB disc (`AAI_VM_CPUS`, `AAI_VM_MEMORY`, `AAI_VM_DISK`). Avertismentele pentru RAM/disc sub recomandări sunt normale în VM.
