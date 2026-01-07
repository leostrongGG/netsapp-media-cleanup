# 🧹 Netsapp Media Cleanup Manager

Sistema automatizado de gerenciamento, backup e limpeza de mídias antigas do [Ticketz](https://github.com/ticketz-oss/ticketz) (sistema tipo WhatsApp para atendimento).

## 📋 Sobre

Este projeto foi criado para gerenciar o crescimento descontrolado de arquivos de mídia no Ticketz, oferecendo uma solução segura para:

- ✅ Identificar mídias antigas vinculadas a tickets
- ✅ Criar backups locais timestamped
- ✅ Mover arquivos para quarentena
- ✅ Upload automático para storage remoto (Backblaze B2 via rclone)
- ✅ Gerar scripts de restauração automaticamente
- ✅ Manter histórico completo de todas as operações

## 🏗️ Arquitetura

```
┌─────────────────────────────────────────────────────────┐
│  PostgreSQL (Docker)                                    │
│  └─ Messages table (mediaUrl + ticketId)                │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│  cleanup_media_manager.sh                               │
│  ├─ Query DB (messages > N days)                        │
│  ├─ Scan filesystem                                     │
│  ├─ Intersect DB ∩ FS → candidates                      │
│  └─ Generate CSV + scripts                              │
└─────────────────────────────────────────────────────────┘
                         ↓
        ┌────────────────┼────────────────┐
        ↓                ↓                ↓
    [Backup]         [Move]          [Upload]
   rsync local     quarantine      rclone → B2
        ↓                ↓                ↓
   backups/        quarantine/     Backblaze B2
        └────────────────┴────────────────┘
                         ↓
            [Restore Scripts Gerados]
         backup / quarantine / remote
```

## 📦 Estrutura de Pastas

```
cleanup/
├── cleanup_media_manager.sh      # Script principal
├── restore_helper.sh             # Helper de restauração
├── run_dry.sh                    # Wrapper para dry-run
├── runs/                         # Artefatos de cada execução
│   └── run_20260107_150000/
│       ├── media_ticket_candidates.csv
│       ├── media_ticket_candidates.txt
│       ├── preview_move_cmds.sh
│       ├── do_move_cmds.sh
│       ├── restore_from_*.sh    # Scripts de restauração
│       └── run.log
├── backups/                      # Backups locais timestamped
│   └── media_backup_20260107_150000/
├── quarantine/                   # Staging antes do upload
└── tmp_restore/                  # Temp para restores remotos
```

## 🚀 Instalação

### Pré-requisitos

- Ubuntu/Debian Linux
- Docker com container PostgreSQL do Ticketz rodando
- rclone configurado (para upload remoto)
- Acesso sudo

### Setup

1. **Clone o repositório**
```bash
git clone https://github.com/leostrongGG/netsapp-media-cleanup.git
cd netsapp-media-cleanup
```

2. **Configure permissões**
```bash
chmod +x cleanup_media_manager.sh restore_helper.sh run_dry.sh
```

3. **Configure rclone (se usar upload remoto)**
```bash
rclone config
# Configure seu remote Backblaze B2, S3, etc.
```

4. **Edite variáveis no script (opcional)**

Abra [cleanup_media_manager.sh](cleanup_media_manager.sh) e ajuste:

```bash
DAYS=15                           # Dias para considerar mídia antiga
HOME_BASE="/home/ubuntu/cleanup"  # Pasta base
MEDIA_ROOT="/var/lib/docker/volumes/ticketz-docker-acme_backend_public/_data"
DB_CONTAINER="ticketz-docker-acme-postgres-1"
DB_NAME="ticketz"
DB_USER="ticketz"

# Rclone remote (configure uma vez)
RCLONE_REMOTE="cleanup:cleanup/media"
RCLONE_CONFIG="/home/ubuntu/.config/rclone/rclone.conf"
```

## 💡 Uso

### 1️⃣ Dry-Run (Recomendado e PADRÃO)

**Por segurança, o script por padrão NÃO executa ações - apenas gera relatórios:**

```bash
# Executar sem flags = dry-run automático
sudo ./cleanup_media_manager.sh --days 5

# Ou usar wrapper explícito
sudo ./run_dry.sh --days 5
```

**Saída:**
- CSV com candidatos (tamanho, data, path)
- Scripts de preview (`preview_move_cmds.sh`)
- Scripts de ação (não-executáveis)
- Scripts de restauração

### 2️⃣ Apenas Backup

```bash
sudo ./cleanup_media_manager.sh --days 5 --do-backup
```

Cria backup timestamped em `backups/media_backup_YYYYMMDD_HHMMSS/`

### 3️⃣ Apenas Mover para Quarentena

```bash
# Mover TODOS os candidatos
sudo ./cleanup_media_manager.sh --days 5 --do-move

# Testar com limite de 10 arquivos
sudo ./cleanup_media_manager.sh --days 5 --do-move --limit 10
```

### 4️⃣ Pipeline Completo (Move + Upload + Cleanup)

```bash
sudo ./cleanup_media_manager.sh \
  --days 5 \
  --do-move \
  --push-remote \
  --delete-quarantine-after-push
```

Executa:
1. Move arquivos → quarentena
2. Upload para Backblaze B2 via rclone
3. Deleta arquivos da quarentena (só deste run) após sucesso

### 5️⃣ Testar Upload Rclone (Dry-Run Manual)

```bash
RUN=$(ls -1dt /home/ubuntu/cleanup/runs/run_* | head -n1)
sudo rclone --config /home/ubuntu/.config/rclone/rclone.conf \
  copy /home/ubuntu/cleanup/quarantine \
  yourremote:yourbucket/path/to/media \
  --files-from "${RUN}/media_ticket_candidates.txt" \
  --dry-run --progress \
  --log-file "${RUN}/rclone_upload_dryrun.log"
```

## 🔄 Restauração

### Usando restore_helper.sh (Recomendado)

#### Restaurar todos os arquivos de um run (do remote)
```bash
sudo ./restore_helper.sh \
  --from remote \
  --run /home/ubuntu/cleanup/runs/run_20260107_150000
```

#### Restaurar apenas arquivos da empresa 1
```bash
sudo ./restore_helper.sh \
  --from remote \
  --run /home/ubuntu/cleanup/runs/run_20260107_150000 \
  --company 1
```

#### Restaurar um único arquivo (do remote)
```bash
sudo ./restore_helper.sh \
  --from remote \
  --run /home/ubuntu/cleanup/runs/run_20260107_150000 \
  --file "2/416/28/Yvx4NCwMLp/vendas ernesto.xls"
```

#### Restaurar de backup local
```bash
sudo ./restore_helper.sh \
  --from backup \
  --backup-dir /home/ubuntu/cleanup/backups/media_backup_20260107_150000 \
  --file "1/374/8/TCsKn-1765832675438.jpeg"
```

### Restauração Manual

Os scripts gerados automaticamente em cada run também podem ser usados:

```bash
cd /home/ubuntu/cleanup/runs/run_20260107_150000

# Do backup local
sudo bash restore_from_backup_20260107_150000.sh \
  /home/ubuntu/cleanup/backups/media_backup_20260107_150000 \
  /home/ubuntu/cleanup/runs/run_20260107_150000

# Da quarentena
sudo bash restore_from_quarantine_20260107_150000.sh \
  /home/ubuntu/cleanup/runs/run_20260107_150000

# Do remote (Backblaze B2)
sudo bash restore_from_remote_20260107_150000.sh \
  yourremote:yourbucket/path/to/media \
  /home/ubuntu/cleanup/runs/run_20260107_150000
```

## ⚙️ Automação com Cron

Para rodar automaticamente, use o crontab do usuário (mesma forma que outros scripts):

**Primeiro, crie o arquivo de log:**
```bash
touch /home/ubuntu/cleanup/cleanup_media.log
chmod 644 /home/ubuntu/cleanup/cleanup_media.log
```

**Depois configure o cron:**
```bash
crontab -e
```

Adicione uma das opções:

```cron
# Opção 1: Cleanup semanal (domingo às 03:00) - RECOMENDADO
0 3 * * 0 /home/ubuntu/cleanup/cleanup_media_manager.sh --days 15 --do-move --push-remote --delete-quarantine-after-push >> /home/ubuntu/cleanup/cleanup_media.log 2>&1

# Opção 2: Cleanup diário às 03:00
0 3 * * * /home/ubuntu/cleanup/cleanup_media_manager.sh --days 15 --do-move --push-remote --delete-quarantine-after-push >> /home/ubuntu/cleanup/cleanup_media.log 2>&1

# Opção 3: Apenas dry-run diário (para monitoramento)
0 3 * * * /home/ubuntu/cleanup/run_dry.sh --days 15 >> /home/ubuntu/cleanup/cleanup_dry.log 2>&1
```

**Verificar se está ativo:**
```bash
# Ver suas tarefas agendadas
crontab -l

# Acompanhar logs em tempo real
tail -f /home/ubuntu/cleanup/cleanup_media.log

# Ver últimas execuções
ls -lht /home/ubuntu/cleanup/runs/ | head -5
```

**Exemplos de agendamento:**
- `0 3 * * *` - Todo dia às 03:00
- `0 3 * * 0` - Todo domingo às 03:00 (semanal) ⭐
- `0 3 1 * *` - Todo dia 1 do mês às 03:00 (mensal)
- `0 */6 * * *` - A cada 6 horas

## 🔍 Arquivos Gerados por Run

Cada execução cria em `runs/run_YYYYMMDD_HHMMSS/`:

| Arquivo | Descrição |
|---------|-----------|
| `media_ticket_candidates.csv` | CSV com candidatos (size, mtime, path) |
| `media_ticket_candidates.txt` | Lista de paths relativos |
| `media_ticket_db_raw.txt` | Query raw do DB |
| `media_ticket_db.txt` | Paths normalizados do DB |
| `media_fs.txt` | Scan do filesystem |
| `preview_move_cmds.sh` | Preview (echo) dos comandos de move |
| `preview_delete_cmds.sh` | Preview (echo) dos comandos de delete |
| `do_move_cmds.sh` | Script de ação (move) - **não-executável** |
| `do_delete_cmds.sh` | Script de ação (delete) - **não-executável** |
| `restore_from_backup_*.sh` | Restaurar de backup local |
| `restore_from_quarantine_*.sh` | Restaurar da quarentena |
| `restore_from_remote_*.sh` | Restaurar do remote (B2) |
| `moved_list.txt` | Lista de arquivos efetivamente movidos |
| `rclone_upload.log` | Log do upload rclone |
| `run.log` | Log geral da execução |

## 🛡️ Segurança

- ✅ **Scripts de ação não são executáveis por padrão** - evita acidentes
- ✅ **Dry-run mode** - sempre teste antes
- ✅ **Quarentena** - staging seguro antes de deletar
- ✅ **Backups timestamped** com retenção configurável (`--prune-keep N`)
- ✅ **Logs completos** de todas as operações
- ✅ **Scripts de restauração** gerados automaticamente

## 🔧 Troubleshooting

### Arquivo restaurado ainda dá 404

Limpe caches do Nginx/Backend:
```bash
sudo docker restart ticketz-nginx-proxy
sudo docker restart ticketz-docker-acme-backend-1
```

### Erro de permissão no rclone

Certifique-se que o config do rclone está acessível:
```bash
ls -la /home/ubuntu/.config/rclone/rclone.conf
# Deve ter permissão 600 ou 644
```

### Verificar espaço disponível

```bash
df -h /home/ubuntu/cleanup
df -h /var/lib/docker/volumes
```

### Ver últimas execuções

```bash
ls -lht /home/ubuntu/cleanup/runs/ | head -10
```

## 📊 Opções do Script Principal

```bash
./cleanup_media_manager.sh [options]

Options:
  --days N                    Considerar mensagens > N dias (default: 15)
  --home-base PATH            Base dir para artifacts (default: /home/ubuntu/cleanup)
  --media-root PATH           Media root do Ticketz
  --do-backup                 Criar backup timestamped
  --do-move                   Mover arquivos para quarentena
  --push-remote               Upload para remote via rclone
  --rclone-remote NAME/PATH   Override RCLONE_REMOTE
  --delete-quarantine-after-push  Deletar arquivos da quarentena após upload
  --limit N                   Limitar a N arquivos (0 = todos)
  --prune-keep N              Manter últimos N backups locais (0 = disable)
  --quiet                     Menos output
  --verbose                   Mais output (default)
  --help                      Mostrar ajuda
```

## 🤝 Contribuindo

Contribuições são bem-vindas! Sinta-se livre para:

1. Fazer fork do projeto
2. Criar uma branch para sua feature (`git checkout -b feature/MinhaFeature`)
3. Commit suas mudanças (`git commit -m 'Add: MinhaFeature'`)
4. Push para a branch (`git push origin feature/MinhaFeature`)
5. Abrir um Pull Request

## 📝 Changelog

### v1.0.0 (2026-01-07)
- ✨ Release inicial
- Sistema completo de backup/move/upload
- Helper de restauração
- Wrapper dry-run
- Documentação completa

## 📄 Licença

MIT License - veja [LICENSE](LICENSE) para detalhes.

## ⚠️ Disclaimer

Este script é fornecido "como está", sem garantias. Sempre teste em ambiente não-produção primeiro. Mantenha backups regulares.

## 🔗 Links Úteis

- [Ticketz (Sistema original)](https://github.com/ticketz-oss/ticketz)
- [Rclone Documentation](https://rclone.org/docs/)
- [Backblaze B2 Setup](https://rclone.org/b2/)

---

