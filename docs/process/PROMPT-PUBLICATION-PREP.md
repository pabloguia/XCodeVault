# Preparar o XCodeVault para publicação pública

> **Sessão concluída em 2026-09-17. Este documento é o registro do briefing, não instruções vigentes.**
> A decisão e os números corrigidos estão em `docs/adr/0005-public-open-source-release.md`.
> O inventário da tabela abaixo foi **medido antes** da execução e tinha cinco erros, corrigidos
> naquele ADR — em particular `mac-ssd-rescue` não é uma pasta pessoal (é a ferramenta de prior-art
> que o `doctor` detecta), a contagem de seriais de disco era zero, e quase todos os UUIDs listados
> são identificadores gerados pelo CoreSimulator, que devem ser preservados.
> Os marcadores `<vault>`, `<user>` e `<vault-uuid>` no texto abaixo são resultado da própria
> redação que este briefing pediu; onde a frase ficou estranha, essa é a causa.

Prompt para uma sessão limpa. O inventário abaixo foi **medido em 2026-09-17**; reverifique antes de
agir, porque nesta semana um número medido de manhã já estava errado à noite.

---

Projeto: `~/projects/XCodeVault`. Responda em português; arquivos e commits em inglês.

Leia `docs/adr/0005-public-open-source-release.md` primeiro — é a decisão que motiva este trabalho —
e depois `CLAUDE.md` (regras não-negociáveis) e `docs/process/SESSION-HANDOFF.md` (estado da
máquina, lições reincidentes).

**A decisão já está tomada: o repositório será público e open source.** Sua tarefa é deixá-lo
publicável. Não crie o remote e **não faça push** — isso é irreversível e fica comigo.

## Restrições permanentes

- **Nunca `sudo`, nunca peça minha senha.** Se algo exigir root, escreva o script e me entregue o
  comando.
- **Antes de tocar em qualquer device de simulador:** `pgrep -fl xcodebuild`,
  `xcrun simctl list devices`, e me diga qual device você vai tocar. (Este trabalho não deveria
  precisar de nenhum.)
- **Commite só com `swift build && swift test` verdes, conferindo o código de saída real, não um
  grep.** O shell aqui é zsh: `${PIPESTATUS[0]}` devolve vazio. Use `cmd > log 2>&1; rc=$?`.
- Mudanças que copiam/movem/apagam/montam dados vão para `migration-safety-reviewer` antes do
  commit; mudanças no helper vão para `helper-security-reviewer`.

## Duas decisões minhas que bloqueiam partes do trabalho

Pergunte antes de assumir qualquer uma:

1. **Licença.** Não existe nenhuma. Sem licença o código é "source available", não open source, e
   ninguém pode usá-lo legalmente. Me apresente as opções com o trade-off real (MIT é a mais simples
   e permissiva; Apache-2.0 acrescenta concessão explícita de patentes e exigência de NOTICE) e
   recomende uma. Nada mais depende disso, mas é o item que torna a publicação legítima.

2. **Autoria no histórico.** Todos os commits carregam o nome e o e-mail pessoal do autor.
   Publicar publica isso. Reescrever só é possível **antes do primeiro push**, e exige reescrever
   todos os commits. Me diga as opções (manter; trocar para um e-mail `@users.noreply.github.com`;
   trocar nome e e-mail) e o custo de cada uma. **Não reescreva nada sem eu decidir.**

## Inventário medido do que é pessoal

Números de 2026-09-17, com `--exclude-dir=.git`:

| o quê | ocorrências | onde (não exaustivo) |
|---|---|---|
| `~` (caminho home) | **3 arquivos** | `Tests/XCodeVaultCoreTests/M2Tests.swift`, `docs/research/LOCATIONS-KEYS-2026-09-06.md`, `.codex/hooks.json` |
| usuário `<user>` solto | **5 arquivos** | os três acima + `STATUS.md` + `evidence/e4a-seal-survives-external-relocation-*.txt` |
| UUID do vault `<vault-uuid>` | **9 arquivos** | docs de arquitetura e evidências |
| pastas pessoais (`backup-ios`, `parallels`, `mac-ssd-rescue`) | **18 arquivos** | docs e evidências |
| `/Volumes/<vault>` e `<vault>` | **33 arquivos** | o mais espalhado; é o meu primeiro nome como rótulo de volume |
| UUIDs de device/volume em evidências | **30 arquivos** | `docs/research/evidence/` |
| seriais de disco | **4 arquivos** | `docs/research/evidence/` |

Sem e-mails no código. Sem MAC addresses. 178 arquivos versionados.

### Como redigir, e o que **não** estragar

O ponto difícil não é achar — é redigir **sem destruir a evidência**. Regras:

- Substitua por **marcadores estáveis e legíveis**, não por `<redacted>` genérico: `~` para o home
  (é o que o `xcv_redact` já faz), `<user>` para a conta, `/Volumes/<vault>` para o volume,
  `<vault-uuid>` para o UUID. Um leitor externo tem que continuar entendendo o experimento.
- **Um UUID de volume redigido perde a função de identificador, e isso importa:** vários docs dizem
  "identifique pelo UUID, nunca pelo nome". Mantenha essa instrução e deixe claro que o valor
  concreto era meu e foi removido. Não reescreva a regra.
- **Não redija os UUIDs de runtime nem de device de simulador.** Eles não são meus — são
  identificadores gerados pelo CoreSimulator, e o F10 e o round-trip do E8 dependem de mostrar que
  um deles muda (`90F2566D…` → `99ABCCEF…`). Redigir isso apagaria um achado.
- Distinga *pessoal* de *específico*. `macOS 26.7 (25G229)` é específico e deve ficar. `/Volumes/<vault>`
  é pessoal.
- Depois de redigir, **releia pelo menos duas evidências inteiras** e confirme que ainda se entende
  o que foi medido. Uma evidência ilegível é pior que nenhuma.

### O `xcv_redact` tem uma lacuna que agora é de publicação

`scripts/experiments/common.sh` já redige home e nome de conta (e foi corrigido em 16/09 para
funcionar sob `sudo`). Ele **não** cobre rótulo de volume, UUID de volume nem nomes de pasta. Como
toda evidência futura será publicada, isso deixou de ser asseio. Estenda-o — e **teste a extensão**,
porque a última correção dele tinha três defeitos que só apareceram sob teste (truncava home com
espaço, comia palavras curtas por falta de fronteira, obedecia `SUDO_USER` fora de sessão sudo).

## Infraestrutura open source que falta

Nada disto existe hoje:

- **`LICENSE`** — bloqueado pela decisão 1.
- **`CONTRIBUTING.md`** — como rodar os testes, o portão de commit, a disciplina de experimentos
  (`docs/architecture/EXPERIMENTS.md`), e o aviso de que scripts com `--i-understand` mutam devices.
- **`SECURITY.md`** — este projeto tem um helper privilegiado; precisa de canal de reporte e do
  apontamento para `docs/architecture/SECURITY_MODEL.md`.
- **`CODE_OF_CONDUCT.md`** — Contributor Covenant serve.
- `.github/ISSUE_TEMPLATE/` e `.github/PULL_REQUEST_TEMPLATE.md` — o de issue deve pedir macOS
  build, versão do Xcode e arquitetura, porque é exatamente disso que a matriz de compatibilidade
  vive.

O `README.md` existe (47 linhas) e descreve bem o produto, mas foi escrito para mim. Revise a porta
de entrada pública: o que é, o que **não** é (leia `docs/product/NON_GOALS_AND_SAFETY.md`), estado
real (pesquisa fechada ou bloqueada, CLI funcional, GUI parcial, helper não ligado), como construir,
e o aviso de que vários achados são `probable` numa máquina só — que é justamente o que a publicação
pretende destravar.

## Ferramenta local versionada — decida comigo

15 arquivos sob `.claude/` e `.codex/` estão versionados (agentes, hooks, skills, settings). Parte é
genuinamente útil para quem for contribuir; `.codex/hooks.json` contém meu caminho home. Me
apresente o que faz sentido publicar e o que sai.

## Critérios de aceitação

1. `swift build` e `swift test` verdes, código de saída conferido. São 236 testes hoje.
2. Varredura limpa: nenhuma ocorrência das categorias pessoais da tabela acima fora de `.git/`.
3. Duas evidências lidas na íntegra depois da redação, e ainda compreensíveis.
4. `LICENSE` presente, coerente com a decisão 1.
5. Decisão 2 registrada — mesmo que a decisão seja "manter como está".
6. `ADR-0005` atualizado com as três sub-decisões resolvidas.
7. `STATUS.md` e `SESSION-HANDOFF.md` atualizados.
8. **Nenhum push. Nenhum remote criado.** Me entregue o comando e eu rodo.

## Uma advertência, porque esta semana custou caro

O histórico é publicado junto com a árvore. Redigir o estado atual **não** redige os 79 commits
anteriores. Se o inventário aparece em commits antigos — e aparece —, a redação de hoje não o remove
do histórico. Me diga explicitamente o que continua visível no histórico depois do seu trabalho, e
qual seria o custo de reescrevê-lo. Não decida isso sozinho: publicação é irreversível, e o
histórico é a parte que ninguém consegue despublicar depois.
