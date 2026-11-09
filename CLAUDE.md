# CLAUDE.md — asistent-ai-installer

Kit de instalare pentru asistenți virtuali AI on-premise (Dify + model local) pe servere Ubuntu. Specificația completă este în `SPEC.md`; citește-o înainte de orice modificare și lucrează pe etapele din secțiunea „Milestones”, una câte una.

## Context

- Livrăm câte o instanță separată pentru fiecare client (primării, instituții publice). Niciodată o instanță comună pentru mai mulți clienți: licența Dify interzice SaaS multi-tenant fără autorizare scrisă.
- Prototipul a fost validat pe un laptop (Ollama + Dify 1.19.0 în WSL). Lecțiile de acolo sunt în `SPEC.md`, secțiunea 10; nu le reînvăța pe cale grea.

## Stack

- Bash (scripturi de instalare și operare), Docker Engine + Docker Compose v2.
- Dify self-hosted, versiune fixată (implicit `1.19.0`), din repo-ul oficial `langgenius/dify`.
- Inferență: profil GPU = vLLM (chat) + server de embeddings/rerank; profil CPU = Ollama. Vezi `SPEC.md` §4.3.
- Țintă: Ubuntu Server 24.04 LTS, x86_64.

## Reguli de cod

- Toate scripturile: `#!/usr/bin/env bash` + `set -Eeuo pipefail`, funcții mici, `shellcheck` fără avertismente.
- **Idempotent**: rularea de două ori a `install.sh` nu strică nimic și nu regenerează secretele existente.
- Mesajele către utilizator: **în română**. Codul, numele de variabile și comentariile: în engleză.
- Fiecare etapă loghează în `/var/log/asistent-ai/install.log` și afișează un rezumat clar (OK / AVERTISMENT / EROARE + ce trebuie făcut).
- `--dry-run` afișează ce s-ar face, fără să modifice sistemul.
- Configurarea per client vine dintr-un singur fișier `client.yaml` (sau flaguri CLI care îl suprascriu).

## Securitate — nenegociabil

- **Nu scrie niciodată secrete în repo** sau în loguri. Se generează la instalare cu `openssl rand -hex 32` și se păstrează în `/opt/asistent-ai/secrets/` cu permisiuni `600`, proprietar root.
- În `.env`-ul Dify, **toate** valorile implicite din `.env.example` care sunt secrete se înlocuiesc (inclusiv `SECRET_KEY`, parolele bazei de date și Redis, cheile sandbox și plugin daemon, `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN`).
- Porturile modelelor (vLLM 8000, Ollama 11434, embeddings) **nu se expun** în afara rețelei Docker. Firewall: doar 22, 80, 443.
- Consola Dify (`/console`, `/install`, `/signin`) accesibilă doar din IP-urile de administrare din `client.yaml`.
- Nu dezactiva și nu modifica logo-ul / copyright-ul din consola Dify.
- Nu configura unelte de execuție de cod sau shell pentru agenții publici.
- Nu folosi Docker Desktop (licență comercială peste 250 angajați / 10 mil. USD venit). Doar Docker Engine.

## Comenzi

- `make lint` — shellcheck pe toate scripturile.
- `make test` — teste unitare `bats` din `tests/unit/`.
- `make vm-test` — instalare completă într-o mașină virtuală Ubuntu curată (Multipass), profil CPU.
- `make eval` — rulează setul de întrebări de test pe o instanță instalată (`scripts/run-eval.sh`).

## Cum lucrezi

- O etapă (milestone) pe rând; la final rulezi `make lint` și `make test` și îmi spui ce ai verificat.
- Când un API Dify nu e documentat public (API-ul consolei), izolează apelul în `lib/dify_console.sh`, documentează versiunea testată și oferă un pas manual de rezervă.
- Dacă o decizie din `SPEC.md` §12 („Întrebări deschise”) blochează lucrul, întreabă înainte să alegi.
