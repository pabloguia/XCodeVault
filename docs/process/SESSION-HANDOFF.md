# XCodeVault — continuar o trabalho

Ponto de partida para uma sessão nova. Projeto em `~/projects/XCodeVault`.

> **Estado verificado em 2026-09-15** (vault, espaço, devices, árvore git). Os números de categoria
> são desta data; o resto continua sendo ponto-no-tempo — reverifique antes de agir.**
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

### 1. ~~Os ~5,4 GB regeneráveis dentro dos devices~~ — FEITO 2026-09-13, com o resultado invertido

Catalogado e reportado; **não limpável, e por um motivo melhor do que o previsto.** As três
categorias (`simulatorDeadContainers`, `simulatorMobileAssets`, `simulatorLogStore`) são
somente-relatório: `scan` mede por device, `doctor` imprime o detalhamento e o motivo, `clean` não
oferece nada.

O `Dead` **é varrido às vezes, e não se sabe por quê** — duas versões anteriores deste parágrafo
diziam saber e ambas foram derrubadas por remedir. Uma varredura em massa foi observada (15 entradas
/ 1,5 GB → 3 / 306 MB, contra um device desligado que não mudou um byte), mas o mesmo device,
bootado por mais três horas, voltou a 2,0 GB sem varrer nada. Nenhuma das três categorias oferece
remediação. O número sólido é o **crescimento**: ~2 GB/hora num loop de `xcodebuild test`. Ver F22.

~~Aberto: reproduzir `log erase --all` via `simctl spawn`~~ — **fechado 2026-09-15, negativo.** As
três formas documentadas são recusadas pelo `logd` dentro do device (`Operation not permitted`),
enquanto `log stats` no mesmo device funciona. As três categorias por-device seguem só-relatório, e
agora nenhuma delas por falta de tentativa. Ver E18.

### 2. E14b e E14c — FECHADOS em 2026-09-15. Nada aqui para rodar

**H12 falsificado para armazenamento externo:** `create` falha no vault e funciona num set
alternativo interno, comandos idênticos. Fase 3 inalcançável, E15 sem efeito em decisão de v1.

**E14c estreitou o H6, rodado duas vezes:** uma imagem APFS case-sensitive cujo arquivo está no
vault hospeda o device que o vault recusa. Case sensitivity, `Device Location=External`, opções de
mount, a *classe* de path (ambos sob `/Volumes`; os paths em si diferem) e o SSD físico todos
mantidos iguais. `Removable Media` variou, mas ver a ressalva abaixo
(o volume chamado `Removable` é o que funciona). Sobra `Protocol`: dispositivo real contra virtual.
Evidência: `evidence/e14c-image-on-vault-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

**O que falta para o H6 sair de *probable* precisa de hardware:** um externo **não-USB** (gaveta
Thunderbolt/NVMe). Todo externo já testado é USB, então "removível" e "USB" continuam sendo a mesma
variável. Isso é o E14d, e o projeto não tem a gaveta.

#### Histórico (o caminho até aqui)

`create` falha no vault e funciona num set alternativo **interno** (exit 0, container `data` de
17 MB), com comandos idênticos. O mecanismo de set alternativo funciona; o volume é a variável.
**H12 falsificado para armazenamento externo**, fase 3 inalcançável, E15 deixou de gatilhar decisão
de v1. Evidência: `evidence/e14b-control-internal-create-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

O H6 ganhou a **segunda reprodução independente, com mecanismo nomeado**: `tccd` consultado 3× para
`kTCCServiceSystemPolicyRemovableVolumes` sobre o CoreSimulatorService, `deny(1) file-write-create`
do kernel, depois EPERM — sem `xctest` em lugar nenhum. Continua **probable**: uma máquina, um
dispositivo físico.

*(Tudo abaixo é registro do caminho até o resultado acima. **Não há nada aqui para rodar** — o
controle `e14b-control-internal-create.sh` já rodou e está fechado.)*

A fase 2 do E14b falhou no vault: `create` sai 22. **O arquivo de evidência do run só contém
isso** — o harness só capturava log em falha de fase 3/4. O mecanismo foi lido à mão do
`CoreSimulator.log` e está em `evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`, com proveniência declarada: o CoreSimulatorService
falha ao copiar o conteúdo inicial para `<set>/<UDID>/data` com `NSPOSIXErrorDomain Code=1` (EPERM,
não EACCES) e destrói o device meio-criado. Isso exclui os bits de permissão do diretório — o
script escreveu ali no passo anterior, como o mesmo usuário — e nada além disso. A captura de log unificado **não** está
vazia, e diferente do E2 ela **nomeia o mecanismo**: três consultas do `tccd` a
`service=kTCCServiceSystemPolicyRemovableVolumes` atribuídas ao CoreSimulatorService, e um
`deny(1) file-write-create` do kernel sobre o path do set, milissegundos antes da falha
(`evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`). O que isso autoriza concluir sobre o H6 **não** foi decidido — é uma
observação, um volume, uma máquina, controle ainda não rodado. **A fase 3, o portão de boot,
nunca foi alcançada.**

#### Histórico da primeira tentativa (void)

`scripts/experiments/e14b-device-set-external.sh` rodou e abortou na fase 1, por um portão errado
dele mesmo: exigia `device_set.plist` depois de um `list` puro, e esse arquivo só nasce no primeiro
`create`. Um controle no disco interno deu diretório igualmente vazio, exit 0, saída idêntica — o
portão separava set vazio de set cheio, não externo de interno. **As fases 2 e 3 nunca rodaram.**
A fase 1 hoje é um smoke test declarado, que não é portão de nada: medido, `simctl --set … list`
sai 1 só quando o path não existe e 0 para qualquer diretório existente, e o script cria o
diretório na linha anterior. Não cite exit 0 dali como aceitação de armazenamento externo.

Duas revisões de segurança sobre essa correção acharam defeitos graves e antigos no script, já
corrigidos: `mkdir -p` **adotava** diretório existente para o `rm -rf`; a recusa de path era
textual, e `/Volumes/<vault>/../../Users/<você>/Library/Developer/CoreSimulator` passava; o
`cleanup` apagava o set confiando num código de retorno em vez de perguntar quantos devices
restam; e não havia `trap`. **Não rode uma cópia antiga deste script.**

~15 min, sem sudo, escreve só no vault, nunca endereça o device set padrão. Exige `--i-understand`.
Os guardas dele **não têm cobertura em CI** — `ci.yml` roda só `e1` e `e8`; foram exercidos à mão
em 2026-09-15 e estão registrados em `COMPATIBILITY_MATRIX.md`.

Se o device de teste não chegar a `Booted` a partir do USB, o H12 morre — e o H6 sugere que morre
mesmo, porque em teste com destino de simulador o bundle `.xctest` é instalado **dentro do
container de dados do device**, que é a configuração do E2 uma camada adentro.

Contexto: o F1 dizia que não há evidência do Xcode honrar device set customizado. **Isso foi
parcialmente derrubado** — `DVTSimulatorSetLocation` existe no `IDEiOSSupportCore` do Xcode 26.5.
Mas o Xcode não repassa o caminho ao Simulator.app, que lê seu próprio `DeviceSetPath`: split
brain silencioso, rule 6, desqualificante sozinho.

### 3. ~~E13 — a sonda de reboot do cache dyld órfão~~ — FEITO 2026-09-16, negativo

**O órfão sobreviveu ao restart.** Captura antes do reboot e outra 5h46m depois: a árvore de cache
voltou byte-a-byte idêntica — mesmos tamanhos, mesmos mtimes, mesmo `newest file write` dentro do
órfão. O `diff` dá exatamente dois hunks, ambos no cabeçalho (timestamp/boottime e
`internal free: 17Gi → 16Gi`, que é uso normal de seis horas, não a árvore — ela seguiu em 9.4G).

Foram **dois** restarts, não um: o órfão nasceu em 7/09 e o `kern.boottime` da captura *de antes* já
marcava 15/09. A premissa em que o experimento foi escrito ("criado depois do último boot, nunca
passou por um restart") era verdadeira em 9/09 e tinha expirado sozinha antes de a sonda rodar —
ninguém editou nada, só o tempo passou.

Consequência de produto, já aplicada: **o `doctor` não manda mais reiniciar** para esse achado, porque
foi medido que não adianta. E o H11 saiu de *open* para **falsificado como regra geral** — o GC de
startup é específico por caminho: recolhe o Inbox e não recolhe o `inc/`, com os dois carecendo de
flag BSD e ausentes do `rootless.conf`.

Evidência: `evidence/e13-dyld-reboot-20260916T100005.txt` (antes) e `…T155821.txt` (depois).

**O que sobrou é o E13b**, a deleção como root. O script existe e *não* foi rodado aqui —
`scripts/experiments/e13b-dyld-orphan-root-delete.sh`, escrito em 2026-09-16:

```
# inspeção, não apaga nada:
sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <dir-do-órfão> --i-understand
# e então, se o relatório fizer sentido:
sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <dir-do-órfão> --i-understand --delete
```

Ele mede **errno** em vez de usar `rm -f` (que suprime justamente a resposta procurada: EPERM=1 é
recusa de política, EACCES=13 é permissão comum), apaga do **menor arquivo para o maior** — o primeiro
costuma ter zero byte, então uma recusa chega sem destruir nada — e para na primeira recusa. Antes de
tocar em qualquer coisa exige que **cinco testemunhas** concordem que o runtime sumiu, incluindo os
bundles `.simruntime` dentro de cada Xcode, que o `simctl` não enxerga. O formato do caminho não
estabelece que é órfão: o cache **vivo** do iOS passa por todos os guardas de caminho e só é barrado
ali.

Uma recusa é o resultado mais interessante: seria o segundo caminho onde root é bloqueado sem flag de
SIP nem entrada no `rootless.conf` — comportamento de OS para reportar à Apple, não detalhe de
limpeza.

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
