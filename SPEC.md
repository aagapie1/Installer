# Specificație — asistent-ai-installer

Versiune 0.1 · 9 noiembrie 2026 · Smartbytesoft

## 1. Scop

Un kit care instalează, cu o singură comandă, un asistent virtual AI complet pe un server Ubuntu nou al unui client: model de limbaj local, Dify, documentele clientului, aplicația de chat configurată, HTTPS și scripturi de operare.

```
sudo ./install.sh --config client.yaml
```

Rezultat: la `https://<domeniu>` rulează asistentul, iar la final kitul afișează codul de embed pentru widget și locul unde sunt credențialele.

**În afara scopului (v1):** instalare pe mai multe servere / cluster, Kubernetes, mai mulți clienți pe aceeași instanță, zona de administrare (proiect separat: `asistent-admin`, integrat ulterior ca serviciu suplimentar în compose).

## 2. Mediul țintă

| Element | Cerință |
| --- | --- |
| OS | Ubuntu Server 24.04 LTS, x86_64, instalare curată |
| Profil GPU | NVIDIA cu ≥ 24 GB VRAM (recomandat 48–80 GB), driver instalat de kit dacă lipsește |
| Profil CPU (demo/dev) | ≥ 32 GB RAM; modele mici, lent, doar pentru teste |
| RAM | ≥ 32 GB (Dify singur folosește ~4–5 GB, plus modelele) |
| Disc | ≥ 200 GB SSD (modele, imagini Docker, baze de date, backup-uri locale) |
| Rețea | IP public sau acces prin reverse proxy al clientului; porturile 80 și 443; acces de ieșire la registry-urile Docker, GitHub, Hugging Face / Ollama (sau mod offline, vezi §12) |
| DNS | Înregistrare A pentru domeniul asistentului, creată de IT-ul clientului înainte de instalare |

## 3. Interfața

### 3.1 `client.yaml`

```yaml
client:
  name: "Primăria Municipiului Buzău"
  short_name: "primaria-buzau"          # folosit în nume de resurse
  phone_public_relations: "0238 411 015"
domain: "asistent.primariabuzau.ro"
admin:
  email: "admin@smartbytesoft.ro"
  allowed_ips: ["10.0.0.0/8", "192.0.2.10"]   # acces la consola Dify
tls:
  mode: "letsencrypt"                    # letsencrypt | custom | none
  email: "it@primariabuzau.ro"
  cert_file: ""                          # doar pentru custom
  key_file: ""
inference:
  profile: "auto"                        # auto | cpu | gpu
  chat_model: "auto"                     # auto = ales după VRAM (§4.3)
  embedding_model: "bge-m3"
  rerank_model: "bge-reranker-v2-m3"
documents_dir: "./clients/primaria-buzau/docs"
assistant:
  template: "templates/chatflow-primarie.yml"
  opener: "Bună ziua! Sunt asistentul virtual al {client.name}. Vă pot ajuta cu informații despre program, contacte și servicii."
  starter_questions:
    - "Care este programul cu publicul?"
    - "Unde pot plăti taxele?"
    - "Ce acte îmi trebuie pentru certificatul de urbanism?"
retention_days: 90
dify_version: "1.19.0"
```

### 3.2 CLI

`install.sh --config <fișier> [--dry-run] [--non-interactive] [--skip <etapă>] [--only <etapă>]`

Scripturi de operare: `status.sh`, `backup.sh`, `restore.sh <arhivă>`, `update.sh --dify-version <v>`, `run-eval.sh`, `uninstall.sh` (cu confirmare și opțiune de păstrare a datelor).

## 4. Etapele instalării

Fiecare etapă are criteriu de acceptare verificat automat la final. O etapă eșuată oprește instalarea cu un mesaj în română care spune cauza și ce trebuie făcut.

### 4.1 P0 — Verificări preliminare

- OS și versiune, arhitectură, RAM, disc liber, nuclee CPU.
- GPU: `nvidia-smi` (dacă există), VRAM total → decide profilul când `profile: auto`.
- Porturile 80/443 libere; domeniul rezolvă la IP-ul public al serverului (avertisment, nu eroare, dacă se folosește reverse proxy-ul clientului).
- Conectivitate de ieșire: test de descărcare a unui fișier de ~50 MB; la eroare TLS de tip `bad record MAC`, afișează diagnosticul din §10.
- **Acceptare:** raport P0 cu toate verificările, fiecare OK / AVERTISMENT / EROARE.

### 4.2 P1 — Sistemul de bază

- `apt update && apt upgrade`, pachete: `curl git jq openssl zstd ufw unattended-upgrades ethtool`.
- Firewall `ufw`: permis 22, 80, 443; restul blocat.
- Docker Engine din repository-ul oficial Docker (nu Docker Desktop), plugin Compose v2.
- Profil GPU: driver NVIDIA (dacă lipsește; poate cere repornire → kitul se oprește curat și spune să fie rulat din nou), NVIDIA Container Toolkit, test `docker run --gpus all ... nvidia-smi`.
- **Acceptare:** `docker run hello-world` OK; pe GPU, containerul de test vede placa.

### 4.3 P2 — Serviciile de inferență

Rulează într-un compose separat (`compose/inference.yml`) conectat la **aceeași rețea Docker cu Dify**, ca Dify să le acceseze după nume (`http://vllm:8000/v1`), nu prin IP-ul gazdei.

| Profil | Chat | Embeddings și rerank |
| --- | --- | --- |
| gpu | vLLM, API compatibil OpenAI, model ales după VRAM | Server de embeddings compatibil cu Dify (Hugging Face Text Embeddings Inference sau Ollama) cu `bge-m3` și `bge-reranker-v2-m3` |
| cpu | Ollama, `qwen3:8b` (sau mai mic) | Ollama, `bge-m3` (fără reranker) |

Selecția automată a modelului de chat se face dintr-un tabel în `config/models.yaml` (VRAM minim → model + cuantizare + `max_model_len`). **Tabelul se completează și se testează pe limba română înainte de v1** (vezi §12); valorile inițiale sunt doar propuneri.

- Modelele se descarcă în `/opt/asistent-ai/models/` (volum persistent), cu reluare la eroare de rețea.
- Context minim 8192 tokeni.
- **Acceptare:** cerere de test `/v1/chat/completions` cu un prompt în română primește răspuns; cerere de embeddings returnează un vector.

### 4.4 P3 — Dify

- Clonează `langgenius/dify` la tag-ul fixat (`--depth 1 --branch <versiune>`) în `/opt/asistent-ai/dify/`.
- Generează `.env` pornind de la `.env.example`:
  - toate secretele noi (§ „Securitate” din `CLAUDE.md`), inclusiv `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN` (gol = `agent_backend` și `local_sandbox` cad în buclă);
  - `CONSOLE_WEB_URL`, `CONSOLE_API_URL`, `APP_WEB_URL`, `APP_API_URL`, `SERVICE_API_URL` = `https://<domeniu>` (goale = link-uri greșite către `127.0.0.1:3000`);
  - `NGINX_SERVER_NAME`, setările HTTPS / Certbot conform `docker/certbot/README.md` din versiunea fixată.
- `docker compose up -d`, cu reluare automată la erori de descărcare.
- Așteaptă până când toate containerele sunt `Up` / `healthy` (timeout configurabil); orice container în `Restarting` → afișează ultimele 30 de linii de log și oprește.
- TLS: `letsencrypt` (profilul certbot din Dify), `custom` (fișierele clientului în `docker/nginx/ssl`), `none` (doar pentru teste interne).
- **Acceptare:** `https://<domeniu>` răspunde cu certificat valid; `docker compose ps` fără containere în `Restarting`/`Exited` (în afară de cele `init_*`).

### 4.5 P4 — Configurarea asistentului

1. Creează contul de administrator (pasul `/install` al Dify) cu parola generată.
2. Configurează providerii de modele (chat, embeddings, rerank) și modelele implicite.
3. Creează colecția Knowledge: chunk General, lungime 500, overlap 50, High Quality, căutare **hibridă cu rerank** pe profil GPU (vector Top K 3 pe CPU).
4. Încarcă documentele din `documents_dir` prin API-ul de Knowledge; așteaptă indexarea.
5. Importă Chatflow-ul din șablonul DSL, înlocuind variabilele (`{client.name}`, telefon, opener, întrebări de start, ID-ul colecției, numele modelului). Setări obligatorii în șablon: Temperature 0.2, max tokens 512, context 8192, variabila `{{#context#}}` în promptul de sistem, nodul Answer legat la textul LLM.
6. Publică aplicația, obține tokenul pentru widget, generează codul de embed.

Pașii 1, 2 și 5 folosesc API-ul consolei Dify, **nedocumentat public**: izolează-l în `lib/dify_console.sh`, testează-l pe versiunea fixată și, dacă eșuează, afișează instrucțiuni manuale clare și continuă cu restul. Pasul 4 folosește API-ul public de Knowledge (cheie de API pentru dataset).

- **Acceptare:** setul de evaluare (§7) rulat automat trece pragul configurat (implicit 100% la întrebările marcate „critic”, ≥ 90% total).

### 4.6 P5 — Securizare

- Configurare Nginx suplimentară (montată în containerul Nginx al Dify, fără a modifica fișierele din repo-ul Dify):
  - `/console`, `/install`, `/signin` doar din `admin.allowed_ips`;
  - `limit_req` pe rutele de chat publice (ex. 10 cereri/minut/IP, configurabil);
  - antete de securitate (HSTS, X-Content-Type-Options, Referrer-Policy).
- Dezactivează înregistrarea liberă de conturi în Dify.
- `unattended-upgrades` activ pentru actualizări de securitate.
- **Acceptare:** de pe un IP nepermis, `/console` răspunde 403; un test de încărcare depășește limita și primește 429.

### 4.7 P6 — Operare

- `backup.sh`: `pg_dump` al bazei Dify + arhivă a volumelor (fișiere încărcate, vector DB) + `.env` și secretele (criptate cu o cheie separată); rotație (ex. 7 zilnice, 4 săptămânale); cron zilnic.
- `restore.sh`: restaurare pe un server nou, testată în VM.
- `update.sh`: backup automat → schimbă tag-ul Dify → compară `.env.example` nou cu `.env` și raportează variabilele noi → `docker compose pull && up -d` → rulează setul de evaluare → la eșec, instrucțiuni de rollback.
- `status.sh`: containere, GPU, disc, memorie, ultimul backup, certificat (zile până la expirare).
- Retenție: job care șterge conversațiile mai vechi de `retention_days` (dacă nu e preluat de `asistent-admin`).
- `logrotate` pentru logurile kitului.

### 4.8 P7 — Raportul final

`/opt/asistent-ai/INSTALL-REPORT.md` (permisiuni 600): URL-uri, versiuni, model ales, rezultatul evaluării, locul secretelor, codul de embed, pașii manuali rămași (dacă există). Același rezumat, fără secrete, în consolă.

## 5. Structura repo-ului

```
asistent-ai-installer/
├── install.sh
├── scripts/            status.sh backup.sh restore.sh update.sh run-eval.sh uninstall.sh
├── lib/                common.sh preflight.sh system.sh docker.sh inference.sh dify.sh dify_console.sh dify_api.sh nginx.sh secrets.sh
├── compose/            inference-gpu.yml inference-cpu.yml
├── config/             models.yaml client.example.yaml
├── templates/          chatflow-primarie.yml system-prompt.md nginx-extra.conf.tmpl
├── eval/               primarie-default.yaml
├── clients/            (ignorat în git) date per client
├── tests/unit/         *.bats
└── tests/vm/           multipass-test.sh
```

## 6. Șabloanele

- `templates/chatflow-primarie.yml`: exportat (DSL) din Chatflow-ul validat pe prototip, cu valorile specifice înlocuite cu variabile.
- `templates/system-prompt.md`: promptul validat (mai jos), cu `{client.name}` și `{client.phone_public_relations}`.

```
Ești asistentul virtual al {client.name}. Răspunzi în limba română corectă.

Reguli:
- Te adresezi cetățeanului politicos, la persoana a II-a, cu "dumneavoastră". Nu repeta formularea întrebării la persoana I.
- Răspunde STRICT la întrebarea pusă, în 1-3 propoziții.
- Folosește EXCLUSIV informațiile din context.
- Dacă informația lipsește, spune: "Nu am această informație. Vă rog contactați Relații cu publicul la {client.phone_public_relations}."
- Nu inventa acte, taxe, termene sau programe.
- Atenție: în context pot apărea liste de acte pentru ALTE servicii. Folosește o listă de acte doar dacă titlul ei se referă exact la serviciul întrebat.

Context:
{{#context#}}
```

- Ghid pentru documentele clientului (de inclus în `docs/ghid-documente.md`): secțiune de întrebări frecvente la început, o secțiune pe serviciu, titluri care despart serviciile asemănătoare, ce lipsește spus explicit, sursa și data la final.

## 7. Setul de evaluare

```yaml
- id: program-vineri
  critic: true
  question: "Care este programul cu publicul vinerea?"
  must_contain: ["08:00", "14:00"]
  must_not_contain: ["16:30"]
- id: acte-certificat-urbanism
  critic: true
  question: "Ce acte îmi trebuie pentru certificatul de urbanism?"
  must_contain_any: ["formular", "0238 710 614"]
  must_not_contain: ["Certific amplasament", "Stereo"]
- id: refuz-informatie-lipsa
  critic: true
  question: "Cât costă abonamentul la sala de sport a primăriei?"
  must_contain: ["Nu am această informație"]
```

`run-eval.sh` trimite fiecare întrebare prin API-ul aplicației (`/v1/chat-messages`, mod `blocking`), verifică regulile, măsoară timpul și produce un raport Markdown + cod de ieșire ≠ 0 la eșec.

## 8. Testare

- `shellcheck` + teste `bats` pentru funcțiile din `lib/` (generare secrete, parsare `client.yaml`, generare `.env`, selecție model).
- Test de integrare într-o VM Ubuntu 24.04 curată (Multipass), profil CPU, cu documentele de test ale Primăriei Buzău.
- Test de idempotență: `install.sh` rulat a doua oară nu modifică secretele și nu dublează resursele.
- Test de restore: backup pe VM 1, restore pe VM 2, evaluarea trece.

## 9. Securitate și conformitate (cerințe)

- Nicio dată nu părăsește serverul clientului în timpul funcționării (descărcările de modele și imagini doar la instalare/actualizare).
- Secrete generate per instalare, niciodată valori implicite.
- Mesaj de transparență AI în widget (text configurabil) — cerință pentru `asistent-admin`/widget, dar kitul îl include în șablon.
- Jurnal de instalare fără date sensibile.
- Documentația pentru client: ce date se păstrează, cât timp, unde.

## 10. Lecții din prototip (de aplicat)

- RAG, nu fine-tuning; calitatea vine din documente → căutare → prompt → model, în această ordine.
- Function calling: pentru chatbot, modul clasic (fără unelte native) e mai rapid și mai precis; agenții beta cer modele mari.
- Fereastra de context implicită a Ollama e mică: setează explicit 8192.
- Modelul de embeddings implicit e pentru engleză: folosește `bge-m3`.
- WSL/VM cu memorie insuficientă → `plugin instance stopped` și blocarea interfeței; Dify + model 8B cer > 12 GB.
- Erori `bad record MAC` la descărcări mari în WSL: remediu `ethtool -K eth0 tx off rx off`; descărcările trebuie să poată fi reluate.
- Din containere, `localhost` e containerul: serviciile comunică prin rețeaua Docker.
- Variabilele `*_URL` goale în `.env` produc link-uri către `127.0.0.1:3000`.
- `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN` gol → `agent_backend` și `local_sandbox` în buclă de repornire.
- Sandbox-ul agenților din Community Edition are izolare slabă: fără unelte de cod/shell pentru agenți publici.

## 11. Milestones (ordinea de implementare)

1. **M1** — schelet repo, `common.sh` (log, mesaje, erori), parsare `client.yaml`, `--dry-run`, `make lint/test`.
2. **M2** — P0 + P1, testat în VM.
3. **M3** — P2 profil CPU (Ollama), apoi profil GPU (vLLM + embeddings).
4. **M4** — P3 Dify cu `.env` generat, HTTPS `none` și `custom`, apoi `letsencrypt`.
5. **M5** — P4: Knowledge prin API public, apoi API-ul consolei cu rezervă manuală; import DSL; cod embed.
6. **M6** — `run-eval.sh` și setul de evaluare.
7. **M7** — P5 securizare.
8. **M8** — P6 operare (backup/restore/update/status) + P7 raport.
9. **M9** — test complet în VM curată, idempotență, restore.

## 12. Întrebări deschise

- Modelul de chat implicit pentru fiecare treaptă de VRAM (de testat pe română cu setul de evaluare).
- Serverul de embeddings/rerank pe GPU: TEI vs. Ollama, în funcție de providerii disponibili în versiunea Dify fixată.
- Mod offline (instalare fără internet la client): pachet cu imagini Docker (`docker save`) și modele pre-descărcate?
- Confirmarea scrisă de la Dify pentru scenariul „instanță per client” și pentru widget-ul propriu.
- Reverse proxy al clientului în fața serverului: cine gestionează certificatul.
