# XCodeVault — continuar o trabalho

Ponto de partida para uma sessão nova. Projeto em `~/projects/XCodeVault`.

> **Estado verificado em 2026-09-16 20:01** (OS, vault, espaço, devices, cache dyld, árvore git).
> Ponto-no-tempo — reverifique antes de agir, inclusive o que está escrito aqui.
> Um comando: `du -shcx ~/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches/com.apple.containermanagerd/Dead`
> Se a ordem de prioridade mudar por causa disso, siga a evidência e não este documento.
> Ao terminar um item, atualize esta página junto com o `STATUS.md`.
>
> **Em 16/09 isto custou caro duas vezes no mesmo dia.** A máquina foi de macOS 26.6.2 (25G83) para
> 26.7 (25G229) no meio da sessão, e um comando apontado para o caminho medido de manhã já não
> existia à noite. E uma medição feita durante a janela de reconstrução do cache dyld virou a
> afirmação "9,4 GB recuperados / 29 GiB livres" — oito minutos depois eram 7,1 GB reconstruídos e
> 19 GiB. **Número medido dentro de uma janela transitória não é estado.** Meça duas vezes, separado
> no tempo, antes de escrever um número aqui.

## Publicação — preparada em 2026-09-17, **falta só o push**

O repositório está publicável. As três sub-decisões do ADR-0005 estão fechadas (MIT; autoria
mantida; evidências redigidas e histórico reescrito) e há uma quarta: `.claude/` e `.codex/` são
publicados. Detalhes e o inventário corrigido estão no ADR; as lições estão no `STATUS.md`.

**O que falta é meu, não da próxima sessão:** criar o remote e empurrar. Nada foi empurrado, e
nenhum remote existe.

```bash
git remote add origin git@github.com:<usuário>/XCodeVault.git
```

```bash
git push -u origin master
```

> **O backup do histórico não redigido já saiu do repositório** (17/09): `refs/original` foi
> apagado e os objetos podados, então o commit pré-reescrita não existe mais aqui e nenhum
> `git push`, nem mesmo `--mirror`, consegue publicá-lo. A única cópia é
> `~/projects/XCodeVault-pre-rewrite-2026-09-17.bundle`, fora do repositório — **não apague esse
> arquivo antes de conferir o push, e nunca o mova para dentro da árvore.**
>
> Para restaurar a partir dele, se precisar:
> `git fetch ~/projects/XCodeVault-pre-rewrite-2026-09-17.bundle master:pre-rewrite`

Antes de rodar o push, três coisas valem conferir:

- **É irreversível.** Um repositório público é clonado e indexado em minutos. Toda a árvore e todo o
  histórico ficam públicos ao mesmo tempo.
- **Ative o private vulnerability reporting** (Settings ▸ Code security) antes ou logo depois. O
  `SECURITY.md` aponta para esse canal e não publica endereço de e-mail nenhum.
- **A autoria continua visível**, por decisão: nome e e-mail pessoal em todos os commits.

O que ficou deliberadamente por fazer está em `docs/process/KNOWN-ISSUES-AT-PUBLICATION.md`, com
quem achou cada item e o que o torna não-bloqueante *hoje* — vários deixam de ser no momento em que
o helper for empacotado. Esse arquivo existe para virar issues públicas depois do push.

Uma inconsistência que a publicação expõe e que não me cabia resolver sozinho: **este arquivo e os
`PROMPT-*.md` estão em português, e todo o resto do repositório está em inglês.** Para um leitor
externo isso é ruído. Traduzi-los, ou marcá-los como notas internas, é uma decisão em aberto.

O `PROMPT-PUBLICATION-PREP.md` ficou com um cabeçalho dizendo que está superado: seu inventário
tinha cinco erros, corrigidos no ADR-0005. Ele pode ser apagado sem perda — o que havia de durável
nele já está no ADR.

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

## Estado da máquina (medido 2026-09-16 22:15)

- **macOS 26.7 (25G229)** — atualizou de 26.6.2 (25G83) nesta sessão, reboot às 19:14.
  Xcode 26.5 (17F42).
- Interno: **20 GiB livres** (eram 16 GiB antes da atualização; 19 GiB duas horas antes desta
  medição — o número se move o tempo todo, não o cite como estado sem a hora).
- Vault `/Volumes/<vault>` montado: Case-sensitive APFS, USB, External,
  UUID `<vault-uuid>`, 349 GiB livres.
- Dois runtimes instalados (iOS 26.5 + watchOS 26.5, 14,8 GB). Instaladores no vault.
- Device set: **8,2 GB**.
- Cache dyld: **7,1 GB**, todo sob `25G229` — a árvore do build anterior sumiu na atualização e os
  caches dos runtimes instalados se reconstruíram nos mesmos tamanhos (4,4G iOS + 2,7G watchOS).
  `inc/` está em 0B e o órfão do tvOS não voltou.

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

**Segunda confirmação independente, 2026-09-16, por outro mecanismo e noutro OS.** O E2 re-rodado
no macOS 26.7 dá o mesmo resultado por um caminho diferente — carregamento de bundle `.xctest` em
vez de `simctl create` — e dois dos nove casos dele carregam o argumento:

- **Caso E falha:** um caminho *interno* que é symlink para o vault falha exatamente como o vault.
  A restrição segue o **dispositivo**, não o texto do caminho. Reescrever path não escapa dela.
- **Caso F passa:** uma imagem de disco cujo **arquivo de lastro está no SSD USB** funciona. Os
  bytes atravessam o mesmo dispositivo físico, pelo mesmo caminho de I/O, e o teste roda. Isso
  **inocenta o hardware e o barramento** e deixa a classificação DiskArbitration do volume.

Então o H6 tem hoje dois mecanismos concordando em duas versões de macOS. Continua **probable** —
uma máquina, um dispositivo físico — mas não é mais uma observação só.

**O que ainda falta para sair de *probable* precisa de hardware:** um externo **não-USB** (gaveta
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

### 3b. O E13b rodou em modo inspeção e perdeu o alvo — e aí veio o achado de verdade

**A atualização do macOS levou a árvore inteira.** Entre a captura do E13 (15:58, em 25G83) e o run
do E13b (19:53, já em 25G229) a máquina atualizou e rebootou às 19:14. Às 19:53 `Caches/dyld/` tinha
só `25G229/inc`, vazio: os 9,4 GB do build anterior, órfão incluído, não existiam mais. Esses caches
são indexados pelo build do host, então uma atualização de OS supersede o diretório inteiro.

**Mas só a parte do órfão é espaço durável, e isso é o que importa.** Oito minutos depois os dois
runtimes instalados já tinham reconstruído no build novo, nos mesmos tamanhos (4,4G iOS, 2,7G
watchOS); o `inc/` ficou em 0B. Ganho líquido ≈ **2,3 GB**, livre 16 → 19 GiB. O `0B` / `29 GiB`
visível na janela entre a atualização e a reconstrução era transitório e **não pode ser citado como
recuperação**. Uma primeira versão desta seção citou, e estava errada por uma hora.

De quebra, é a confirmação mais limpa que a categoria já teve: cache de runtime **instalado** volta
sozinho (compra boot lento, não disco); cache de runtime **ausente** não volta. As duas metades
medidas no mesmo antes/depois, por acidente.

Não estabelecido: **quem** apagou — o instalador ou o CoreSimulatorService na primeira utilização
depois da atualização. O mtime do `dyld/` é 19:53, a hora em que o próprio run acordou o `simctl`, o
que é compatível com as duas leituras. Consulta ao log unificado na janela não devolveu nada.

**Três guardas do E13b falharam abertos nesse run, e ele parou por acidente** — todos corrigidos,
ver o commit. A allowlist de conteúdo aprovou uma leitura vazia e imprimiu "every entry is a known
cache artifact" sobre a leitura de nada; o veto do `lsof` disparou com o banner de erro do próprio
`lsof`, capturado por um `2>&1`; e o `home_of` devolvia dois caminhos para root
(`/var/root /private/var/root`), deixando a testemunha 2 com `HOME` inválido — e *não fez diferença*,
o que é pior, porque a verificação de visão dividida rodou quebrada e reportou concordância. Além
disso o descasamento de build era calculado, impresso e ignorado.

**Onde o E13b ainda vale:** numa máquina onde um órfão persista. Aqui não há mais alvo.

O script está em `scripts/experiments/e13b-dyld-orphan-root-delete.sh`, escrito em 2026-09-16:

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

## Quatro lições que reincidiram e estão documentadas no STATUS

1. **Afirmação herdada não é fato.** Cinco rodadas de revisão nesta sessão; em três delas o
   problema era uma correção anterior que mudou de lugar em vez de sumir. E várias entradas
   `[COMMUNITY-REPRO]` dos nossos docs não resistiram ao exame.
2. **Costura não testa o que ela substitui.** Um guard foi enviado que *não podia disparar*
   (`statfs` nunca devolve `/` para caminho sob `/Volumes`, que é firmlink) e os testes concordavam
   com ele, porque construíam à mão um valor que o sistema não produz. Todo default injetado
   precisa de um teste que não passe costura nenhuma.
3. **Ensaio em contexto diferente não é ensaio.** Um `--dry-run` como usuário passou e o run real
   como root recusou, porque comandos liam o home errado. E confirmar o contrato de um verbo
   invocando ele não é diagnóstico — `simctl runtime unmount` não é read-only. Em 16/09 isto
   reincidiu duas vezes num script só: `sudo -u` sem `-H` fazia as duas testemunhas lerem o mesmo
   store, e uma função bash foi testada no zsh interativo, onde falhou por um motivo que não existe
   no bash.
4. **Medição dentro de janela transitória não é estado** *(nova, 16/09, reincidiu no mesmo dia)*.
   O cabeçalho do E13 afirmava "criado depois do último boot, nunca passou por restart" — duas
   datas, verdadeiras quando escritas, expiradas sozinhas sem ninguém editar nada. Horas depois eu
   medi o cache dyld em `0B` na janela entre a atualização do macOS e a reconstrução, e escrevi
   "9,4 GB recuperados / 29 GiB livres" em quatro arquivos. Oito minutos depois eram 7,1 GB e
   19 GiB, e o ganho real era 2,3 GB. **Antes de escrever um número que afirma permanência, meça
   duas vezes separado no tempo, ou escreva a janela junto com o número.**

## Por onde começar

### Re-baseline no macOS 26.7 — feito 2026-09-16, cinco entradas

Toda entrada do `COMPATIBILITY_MATRIX` dizia **26.6.2 (25G83)**, e a máquina foi para 26.7 (25G229)
no meio da sessão sem nada perceber. Um arquivo cuja função é registrar *em quais combinações isto
foi verificado* tinha uma combinação só, e ela tinha deixado de ser a em uso.

Re-rodados os cinco que não precisam de device, root nem evento — **E1, E8, E14a, E2, E12**. Nenhum
simulador tocado, nenhum `sudo`. **Todos sobrevivem ao bump:**

| | resultado no 26.7 |
|---|---|
| E1 | achados idênticos — sem flags BSD, ausente do `rootless.conf`, sem mounts aninhados |
| E8 | **zero** diferenças substantivas |
| E14a | 22/25 seções de achado idênticas |
| E2 | **9/9 veriditos idênticos** — ver o H6 acima |
| E12 | 19/20 seções idênticas; case-sensitive APFS segue ok nas duas superfícies |

**Cuidado ao repetir isto:** um `diff` cru acusou 64 diferenças no E1 e 39 no E14a, e *parece* que os
achados mudaram. Não mudaram — era inventário da máquina (os `.dmg` de runtime voltaram ao `Images/`,
o device set encolheu). Compare as seções que carregam achado, com tamanhos e timestamps
normalizados fora, e não o arquivo inteiro.

**Lacuna registrada e não consertada:** o `e2-external-xctest.sh` não tem `trap` — morrer no meio
deixa imagens esparsas montadas. Não é destrutivo. Não mexi de propósito: ele estava sendo re-rodado
*como está* para re-verificar um resultado registrado, e editar o instrumento durante a
re-verificação é como uma comparação deixa de ser uma.

**Estado do matrix: 5 de ~21 entradas re-verificadas no 26.7.** O resto muta device, precisa de root,
ou precisa de um evento — e deve ser lido como 26.6.2-only até alguém rodar. Isso é menos do que "o
matrix está atualizado", e é o que foi medido.

### O resto

Os itens 1–3 acima estão **fechados**, e os três fecharam negativamente. O que resta na pesquisa de
armazenamento está bloqueado por hardware (E14d: um externo **não-USB**, para separar removibilidade
de barramento) ou por evento (a terceira sonda do F10: se um *build de runtime* superseded deixa
cache para trás — nenhuma máquina aqui exibiu um).

### O e8c foi reescrito em 16/09, e eu tinha errado ao chamá-lo de "decisão em aberto"

As duas decisões já estavam tomadas e escritas; o script é que nunca foi atualizado. O
`EXPERIMENTS.md:363` já dizia **"never `bootstatus -b`"**, e o `STATUS.md:125`, de 13/09, registra
que você não reusou o e8c porque ele "unconditionally deletes the runtime + runs `simctl delete
unavailable` at the end — both wrong here" e rodou os passos à mão. Ele ficou lá como armadilha.

O `simctl delete unavailable` era o problema sério, não o `bootstatus`: ele varre **todo** device
indisponível do set padrão, e offload de runtime é justamente o que deixa os seus iPhones
indisponíveis — eles voltam sozinhos no reimport, a menos que algo os apague antes. O `doctor` é
testado para recusar recomendar esse comando nesse exato estado, e o produto já removeu esse padrão
três vezes. O experimento continuava fazendo.

Agora ele é platform-general (o tipo de device vem do `supportedDeviceTypes` do simctl, não de um
`"Apple TV"` hardcoded), faz polling por `Booted`, apaga só o device que criou pelo UDID, e
**recusa** se o runtime do instalador já estiver instalado — porque aí "restaurar estado anterior"
seria tirar algo seu. Exercitado contra os dois instaladores reais do vault: **exit 3, nada tocado**,
porque iOS 26.5 e watchOS 26.5 estão os dois instalados. Para rodar de verdade é preciso um
instalador de um runtime que você **não** tenha.

A revisão de segurança achou a minha reescrita pior que o original em três pontos, todos em caminhos
que eu não tinha executado — inclusive um `$rid` minúsculo que impedia a sonda de rodar, e o
`runtime delete` recebendo o identificador errado (ele quer o **UUID da imagem**, coisa que o script
original acertava). Corrigidos. E o lint desta sessão pegou um backtick sem escape que eu mesmo
escrevi ao corrigir.

Com isso, o próximo trabalho real é de produto, não de pesquisa — ver as milestones no `STATUS.md`.
