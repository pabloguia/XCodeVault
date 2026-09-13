# XCodeVault — continuar o trabalho

Ponto de partida para uma sessão nova. Projeto em `~/projects/XCodeVault`.

> **Os números aqui são de 2026-09-13 e sustentam a recomendação — reverifique antes de agir.**
> Em quatro dias os containers `Dead` foram de 836 MB a 2,1 GB e o espaço livre de 14 a 21 GiB.
> Um comando: `du -shcx ~/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches/com.apple.containermanagerd/Dead`
> Se a ordem de prioridade mudar por causa disso, siga a evidência e não este documento.
> Ao terminar um item, atualize esta página junto com o `STATUS.md`.

## Leia antes de agir, nesta ordem

1. `CLAUDE.md` — regras não-negociáveis de segurança (especialmente 3, 5, 6, 7).
2. `STATUS.md` — **leia as três últimas seções**, que são de 2026-09-09: o fechamento do E4,
   a pesquisa pós-E4 com o ranking, e as lições de processo. Elas contêm o essencial.
3. `docs/research/FINDINGS-2026-09-05.md` §F10–F21 (os achados recentes).
4. `docs/architecture/HYPOTHESES.md` — H6, H9, H12, H13.

Não releia o resto de `docs/research`.

## Onde o projeto chegou

O produto hoje faz: contabilidade (`scan`/`doctor`), limpeza de dados regeneráveis, e o fluxo
Runtime Library (exporta instalador para o vault externo → `runtime offload` → `runtime import`
quando precisar). Isso funciona e liberou ~23 GiB.

**A relocação de runtime está fechada, negativamente e com motivo:** root não consegue escrever
`/Library/Developer/CoreSimulator/Images/images.plist` (`Operation not permitted`, sem flag BSD,
sem ACL, ausente do `rootless.conf`) enquanto o `simdiskimaged` o reescreve à vontade (F16). A
barreira é **autorização, não integridade** — o E4a provou que a imagem mantém selo APFS válido
copiada byte a byte para volume externo. ADR-0004 ganhou adendo, não reversão.

## Estado da máquina (verificado 2026-09-13)

- Interno: 21 GiB livres. Vault em `/Volumes/<vault>` (registrado, VERIFIED por UUID+sentinela).
- Dois runtimes instalados (iOS 26.5 + watchOS 26.5, 14.8 GB). Instaladores no vault.
- Device set: **9,9 GB** — era 8,5 GB em 09/09.

## O que fazer, em ordem de prioridade

### 1. Os ~5,4 GB regeneráveis dentro dos devices (recomendação principal)

Medido hoje em `~/Library/Developer/CoreSimulator/Devices`:

| | 09/09 | 13/09 |
|---|---|---|
| `*/data/Library/Caches/com.apple.containermanagerd/Dead` | 836 MB | **2,1 GB** |
| `*/data/private/var/MobileAsset` | 3,3 GB | 3,3 GB |

Os `Dead` **triplicaram em quatro dias** — é acúmulo recorrente, não um resíduo pontual. Isso é
dado do usuário, sem root, e recuperável **sem apagar device nenhum** (`simctl erase` apagaria
tudo; o alvo aqui é cirúrgico).

Trabalho: catalogar essas categorias (skill `add-catalog-category`), fazer o `scan`/`doctor`
reportarem, e avaliar se o `clean` deve oferecê-las — com a pergunta honesta de **se são mesmo
seguras de apagar e se regeneram**, verificada, não assumida. Rode `migration-safety-reviewer`
antes de commitar.

### 2. E14b fases 0–3 — o portão que mata a relocação de device set

`scripts/experiments/e14b-device-set-external.sh` está escrito e **não rodado**. ~15 min, sem
sudo, escreve só no vault, nunca endereça o device set padrão. Exige `--i-understand`.

Se o device de teste não chegar a `Booted` a partir do USB, o H12 morre — e o H6 sugere que morre
mesmo, porque em teste com destino de simulador o bundle `.xctest` é instalado **dentro do
container de dados do device**, que é a configuração do E2 uma camada adentro.

Contexto: o F1 dizia que não há evidência do Xcode honrar device set customizado. **Isso foi
parcialmente derrubado** — `DVTSimulatorSetLocation` existe no `IDEiOSSupportCore` do Xcode 26.5.
Mas o Xcode não repassa o caminho ao Simulator.app, que lê seu próprio `DeviceSetPath`: split
brain silencioso, rule 6, desqualificante sozinho.

### 3. E13 — a sonda de reboot dos 2,48 GB de cache dyld órfão

`scripts/experiments/e13-dyld-cache-reboot.sh`. Roda antes e depois de um restart, compara.
Só precisa que o usuário reinicie em algum momento.

## Restrições (valem sempre)

- **Nunca peça nem aceite a senha do usuário. Nunca rode `sudo`.** Se algo exigir root, isso é um
  achado: escreva o script, entregue o comando, o usuário roda. Nunca toque em `/System`.
- Toda mudança que copia/move/apaga/monta dados vai para `migration-safety-reviewer` antes do
  commit. Mudanças no helper privilegiado vão para `helper-security-reviewer`.
- Commite só com `swift build && swift test` verdes — confira o código de saída real, não um grep.
  Sem push.
- Teste por mutação o que escrever, e conte crashes além de falhas de asserção.
- Responda em português; arquivos e commits em inglês.

## Três lições que reincidiram e estão documentadas no STATUS

1. **Afirmação herdada não é fato.** Cinco rodadas de revisão nesta sessão; em três delas o
   problema era uma correção anterior que mudou de lugar em vez de sumir. E várias entradas
   `[COMMUNITY-REPRO]` dos nossos docs não resistiram ao exame.
2. **Costura não testa o que ela substitui.** Um guard foi enviado que *não podia disparar*
   (`statfs` nunca devolve `/` para caminho sob `/Volumes`, que é firmlink) e os testes concordavam
   com ele, porque construíam à mão um valor que o sistema não produz. Todo default injetado
   precisa de um teste que não passe costura nenhuma.
3. **Ensaio em contexto diferente não é ensaio.** Um `--dry-run` como usuário passou e o run real
   como root recusou, porque comandos liam o home errado. E confirmar o contrato de um verbo
   invocando ele não é diagnóstico — `simctl runtime unmount` não é read-only.

Comece pelo item 1.
