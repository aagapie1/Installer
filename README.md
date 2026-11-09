# asistent-ai-installer

Kit de instalare pentru asistenți virtuali AI on-premise (Dify + model local) pe Ubuntu Server 24.04. Specificația completă: `SPEC.md`. Reguli de lucru: `CLAUDE.md`.

> Stadiu: **M1**. Există scheletul, configurarea și simularea (`--dry-run`); etapele P0–P7 sunt încă doar planificate.

## Utilizare

```bash
cp config/client.example.yaml clients/<client>/client.yaml   # completați valorile
sudo ./install.sh --config clients/<client>/client.yaml --dry-run
```

Opțiuni: `--dry-run`, `--non-interactive`, `--only P0,P1`, `--skip P5`, `--set cheie=valoare` (ex. `--set inference.profile=cpu`). Lista completă: `./install.sh --help`.

- Căile relative din `client.yaml` se rezolvă față de rădăcina kitului.
- Jurnal: `/var/log/asistent-ai/install.log` (fără secrete; valorile care arată a secrete sunt mascate). În `--dry-run` nu se scrie nimic pe disc.
- Coduri de ieșire: `0` OK, `1` eroare, `2` utilizare greșită (opțiuni, etape, `--set`).

## Dezvoltare

Necesită `shellcheck`, `bats`, `python3` + `python3-yaml` (prezent implicit pe Ubuntu Server 24.04).

```bash
make lint   # shellcheck pe scripturi și teste
make test   # teste bats din tests/unit/
```
