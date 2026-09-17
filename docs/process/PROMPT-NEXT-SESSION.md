# XCodeVault — continuar (sessão limpa)

Projeto em `~/projects/XCodeVault`. Responda em português; arquivos e commits em inglês.

> **Estado verificado em 2026-09-15, minutos antes de escrever isto.** Reverifique mesmo assim
> antes de agir: é a regra central deste repo, e nesta última sessão ela pegou três afirmações
> erradas — duas delas escritas por mim uma hora antes.

## Estado da máquina, medido

- Vault `/Volumes/<vault>` **conectado e VERIFIED** (UUID `<vault-uuid>`,
  sentinela confere). 349 GiB livres nele. `/Volumes/<vault>/XCodeVault/` existe, contém `RuntimeLibrary`.
- Interno: **21 GiB livres**. Device set: **10 GB**.
- Três simuladores, **todos `Shutdown`**. Nenhum `xcodebuild`/`xctest` rodando.
- Categorias por-device: `Dead` 2,1 GB · `MobileAsset` 3,3 GB · log store 1,9 GB.
- Árvore git limpa em `eff78c1`. Sem push em nenhum commit.

## Leia antes de agir, nesta ordem

1. `CLAUDE.md` — regras não-negociáveis (3, 5, 6, 7 especialmente).
2. `STATUS.md` — **as quatro últimas seções**, de 2026-09-13/14. Elas contêm o essencial.
3. `docs/process/MUTATION-TESTING-NOTES.md` — curto, e evita repetir três erros.
4. `docs/research/FINDINGS-2026-09-05.md` §F16, F18, F22 — só esses.
5. `docs/architecture/HYPOTHESES.md` — H6, H12, H13.

Não releia o resto de `docs/research`.

## Prioridade 1 — escolha entre três, todas destravadas

O E14b e o E14c fecharam. **Não há experimento de armazenamento pronto para rodar**: o único que
falta (E14d) precisa de hardware que o projeto não tem — ver o fim desta seção.

1. ~~**`log erase --all` via `simctl spawn`**~~ — **FEITO 2026-09-15, resposta negativa.** O E18
   rodou as três formas documentadas (`--all`, `--ttl`, sem argumento) dentro de um device
   descartável: todas devolvem `Error from logd: Operation not permitted`. O `log stats` no mesmo
   device sai 0, então o binário roda e lê — é o `erase` que o daemon nega. `simulatorLogStore`
   continua só-relatório, agora porque foi tentado. Ver a entrada E18 na matriz.
2. ~~**Containment exato `<deviceSet>/<UDID>/<subpath>`**~~ — **FEITO 2026-09-15.** Ver a seção
   no `STATUS.md`. `StorageCategory.containsPath` é agora a única definição de "este path é esta
   categoria"; `PathSafety.requireContained` foi removido porque todo chamador dele passava
   `pathTemplates`, que para as por-device nomeia o device set inteiro.
3. ~~**E13**~~ — **feito 2026-09-16, negativo: o órfão sobreviveu ao reboot byte-a-byte.** O GC de
   startup é específico por caminho (recolhe o Inbox, não recolhe o `inc/`), o H11 caiu como regra
   geral e o `doctor` parou de mandar reiniciar para esse achado.
4. ~~**E13b**~~ — rodou em modo inspeção em 2026-09-16 e **perdeu o alvo**. A máquina atualizou para
   macOS 26.7 (25G229) no meio da sessão e a árvore `dyld/25G83/` inteira sumiu com a atualização,
   órfão incluído. Oito minutos depois os caches dos runtimes instalados já tinham reconstruído nos
   mesmos tamanhos e o `inc/` ficou em 0B: ganho durável ≈ **2,3 GB**, não os 9,4 GB da árvore.
   O script segue válido numa máquina onde um órfão persista.

**E14d, bloqueado por hardware:** `create` num volume externo **não-USB** (gaveta Thunderbolt ou
NVMe). É o único confundidor que o E14c não conseguiu quebrar — todo volume externo já testado é
USB, então "removível" e "USB" ainda são a mesma variável. Sem uma gaveta dessas, o H6 não sai de
*probable*.

## Já fechado — E14c: o que a restrição lê é o dispositivo, não o rótulo

> **2026-09-15, rodado duas vezes, resultados idênticos.** Uma imagem APFS case-sensitive cujo
> arquivo está no vault hospeda um device que o vault recusa. Mantidos iguais: case sensitivity,
> `Device Location=External`, opções de mount (`nodev,nosuid,journaled` nos dois), o path sob
> `/Volumes`, e o SSD físico que guarda os bytes. Variaram `Removable Media` e `Protocol`.
>
> **`Removable Media` sai por direção:** o volume que o macOS chama `Removable` é o que
> **funciona**; o que ele chama `Fixed` é o que **falha**. Sobra `Protocol` — dispositivo real
> contra virtual, que é a forma do E2 vista do outro lado. Evidência: `evidence/e14c-image-on-vault-macos26.6.2-25G83-xcode26.5-x86_64.txt`.
>
> A metade "não é o path" do H6 está estabelecida nesta máquina. A metade "é removibilidade" não —
> e o motivo é o E14d acima.

> **2026-09-15, fechado:** o E14b e seu controle rodaram. `create` **falha** no vault e
> **funciona** (exit 0, container `data` de 17 MB) num set alternativo interno, com comandos
> idênticos. **H12 está falsificado para armazenamento externo**; a fase 3 é inalcançável e o E15
> deixou de decidir qualquer coisa de v1. Evidência: `evidence/e14b-control-internal-create-macos26.6.2-25G83-xcode26.5-x86_64.txt`.
>
> E o H6 ganhou a segunda reprodução independente **com o mecanismo nomeado pela primeira vez**:
> `tccd` consultado 3× para `kTCCServiceSystemPolicyRemovableVolumes` sobre o CoreSimulatorService,
> depois `deny(1) file-write-create` do kernel sobre o path do set, depois o EPERM. O E2 nunca
> conseguiu nomear isso. H6 continua **probable**, não verified — uma máquina, um dispositivo
> físico.
>
> **O que falta é separar removibilidade das outras três diferenças.** O controle interno difere do
> vault em case sensitivity, opções de mount, barramento *e* removibilidade ao mesmo tempo; quem
> aponta para removibilidade é o log, não o desenho do experimento. O E2 já mostrou que **imagens
> de disco não reproduzem a falha dele nem com o arquivo da imagem no SSD USB**. Então:
>
> **E14c — repetir o `create` dentro de uma imagem APFS case-sensitive guardada no vault.**
> Se criar, removibilidade fica isolada de case sensitivity, de path, e do dispositivo físico que
> guarda os bytes. **Rodou em 2026-09-15 e não isolou removibilidade** — excluiu case sensitivity,
> opções de mount e a classificação `External`, e deixou removibilidade confundida com barramento.
> Ver a seção do E14c acima. Nada aqui para rodar.

## Já fechado — o controle interno do E14b (~1 min)

> **2026-09-15, segunda rodada:** o E14b rodou com o harness corrigido e **a fase 2 falhou** —
> `simctl --set <vault> create` sai 22. **O arquivo de evidência do run só contém isso**: o harness
> só capturava log em falha de fase 3/4. O mecanismo foi lido do `CoreSimulator.log` à mão, depois,
> e está em `evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` com cabeçalho de proveniência — cite esse arquivo, não o run.
> Ele mostra o CoreSimulatorService falhando ao copiar o conteúdo inicial para `<set>/<UDID>/data`
> com `NSPOSIXErrorDomain Code=1`, EPERM. Isso exclui **uma** alternativa — os bits de permissão do
> diretório, já que o script escreveu `.xcv-e14b` ali no passo anterior como o mesmo usuário — e só
> ela: uma cópia de conteúdo inicial também move xattrs, ACLs e flags.
>
> **A captura de log unificado não está vazia — e nomeia o mecanismo.** Uma consulta manual minha
> devolveu vazio e eu quase publiquei isso; a captura no formato do harness mostra três consultas
> do `tccd` a `service=kTCCServiceSystemPolicyRemovableVolumes` atribuídas ao CoreSimulatorService
> e um `deny(1) file-write-create` do kernel sobre o path do set, 40 ms antes do erro
> (`evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`). O E2 nunca conseguiu nomear o mecanismo. **O que isso autoriza sobre o H6
> ficou explicitamente em aberto na época** — o controle rodou depois e decidiu: ver a seção do
> E14c acima. Nada aqui para rodar.
>
> **Já rodado e fechado em 2026-09-15** (`scripts/experiments/e14b-control-internal-create.sh
> --i-understand`). Ele decidia se o achado era sobre o volume ou sobre sets alternativos em geral;
> a resposta foi o volume. Nada aqui para rodar de novo.
>
> Cria `XCV-E14b-ctl` num set `mktemp` interno, apaga tudo que criou, nunca toca `/Volumes` nem o
> set padrão. Se ele **criar**, o defeito é da **classe do volume** — e só isso: o set do controle é
> interno, case-insensitive, no volume de boot, com opções de mount padrão, enquanto o vault difere
> em removibilidade, case sensitivity, opções de mount e barramento **ao mesmo tempo**. Isso é
> consistente com H6 e **não é** uma segunda reprodução dele; para chegar lá é preciso um
> experimento que varie um fator por vez. Se ele **não criar**, o achado da fase 2 não é sobre
> armazenamento externo e a pergunta muda de assunto.

## Já fechado — E14b fase 3 nunca será alcançada

> **Atualizado 2026-09-15.** O script já rodou uma vez e **não produziu veredito**. Ele abortou na
> fase 1 por um portão errado dele mesmo — exigia `device_set.plist` depois de um `list` puro, e
> esse arquivo só nasce no primeiro `create`. Um controle no disco **interno** deu diretório
> igualmente vazio, exit 0, saída idêntica: o portão separava set vazio de set cheio, não externo
> de interno. O portão foi corrigido; a evidência inválida ficou no repo com uma correção anexada.
> **Não cite a linha de veredito dela.** E não cite exit 0 do `list` como aceitação: medido,
> esse comando só sai 1 quando o path **não existe** e sai 0 para qualquer diretório existente —
> e o script cria o diretório na linha anterior. Exit 0 ali significa que o `mkdir` funcionou.
> **As fases 2 e 3 nunca rodaram** — o portão de boot (H6), que é o que decide o H12, segue sem
> rodar, e nada moveu o H12 em nenhuma direção.
>
> A revisão de segurança dessa mesma correção achou dois defeitos graves e antigos no script, já
> corrigidos: `mkdir -p` **adotava** um diretório existente para o `rm -rf` do cleanup, e a recusa
> de path era textual, então `/Volumes/<vol>/../../Users/<você>/Library/Developer/CoreSimulator`
> passava e teria apagado os seus três devices. **Não rode uma cópia antiga deste script.**

`scripts/experiments/e14b-device-set-external.sh` rodou duas vezes e está encerrado: a fase 2
falha no vault e a fase 3 é inalcançável. **Não há motivo para rodar de novo** — exceto se for para
reproduzir o achado noutra máquina ou noutro dispositivo físico, que é justamente o que falta para
o H6. Nesse caso:

```
scripts/experiments/e14b-device-set-external.sh /Volumes/<outro-vault>/E14bSet --i-understand
```

Leia o script inteiro antes. Ele escreve **somente** sob o `--set` que você passa, e toda invocação
de `simctl` carrega `--set` — **nunca endereça o device set padrão**. Use a skill `run-experiment`
para o procedimento de registro (evidência em `docs/research/evidence/`, matriz, hipóteses).

**A fase 3 é a que decide.** Se o device de teste não chegar a `Booted` a partir do USB, o H12 morre
ali e a pergunta sobre a IDE nunca precisa ser respondida. O H6/E2 sugere que morre mesmo: em teste
com destino de simulador, o bundle `.xctest` é instalado **dentro do container de dados do device**,
que é a configuração do E2 uma camada adentro.

Duas armadilhas já registradas: **não use `simctl bootstatus -b`** (o E11 o viu travar em Data
Migration — faça poll de `list devices` por `"Booted"`), e o Xcode **não** repassa
`DVTSimulatorSetLocation` ao Simulator.app, que lê seu próprio `DeviceSetPath` — split brain
silencioso, regra 6, desqualificante sozinho mesmo se as duas metades funcionarem.

Registre o resultado nos dois sentidos. Um "não bootou" é resultado tão publicável quanto o outro.

## Depois do E14b

- ~~**E13**~~ — feito 2026-09-16. O órfão sobreviveu ao restart, árvore byte-a-byte idêntica. O
  **E13b** rodou em inspeção e perdeu o alvo: a atualização do macOS levou a árvore do build
  anterior. Sobra o E13b só onde um órfão persistir.
- **`log erase --all` via `simctl spawn`** — é o único dos três por-device com verbo estreito
  documentado. Reproduzi-lo transformaria `simulatorLogStore` de reportado em oferecível.
- ~~**Containment exato**~~ — feito 2026-09-15.

## Restrições (valem sempre)

- **Nunca peça nem aceite a senha do usuário. Nunca rode `sudo`.** Se algo exigir root, isso é um
  achado: escreva o script, entregue o comando, o usuário roda. Nunca toque em `/System`.
- **Antes de encostar em qualquer simulador**: `pgrep -fl xcodebuild` e `xcrun simctl list devices`,
  e **diga qual device você vai tocar antes de tocar**. O usuário roda suítes de teste nos mesmos
  simuladores, de `~/projects/smoke`. Na sessão passada eu bootei um device que o teste dele estava
  usando e tive que descartar a medição.
- Toda mudança que copia/move/apaga/monta dados vai para `migration-safety-reviewer` antes do
  commit; mudanças no helper vão para `helper-security-reviewer`. **Não edite a árvore enquanto o
  revisor lê** — isso invalidou uma revisão inteira nesta sessão.
- Commite só com `swift build && swift test` verdes, conferindo o **código de saída real**, não um
  grep. Sem push.
- Teste por mutação o que escrever, e conte crashes e erros de compilação separadamente das falhas
  de asserção.

## Quatro lições que custaram caro, todas de 2026-09-13/14

1. **Afirmação causal tirada de uma observação só cai na próxima medição.** Publiquei duas vezes que
   sabia o que varre os containers `Dead` — "reaper por idade", depois "bootar coleta" — e remedir
   derrubou as duas. O que sobreviveu foi o número de crescimento (~2 GB/hora num loop de teste),
   não o mecanismo.
2. **Uma mutação limpa é pergunta, não resposta.** Três rodadas voltaram verdes e nas três a
   conclusão certa era o oposto da óbvia. Detalhes em `MUTATION-TESTING-NOTES.md`.
3. **Procure "onde isto é decidido duas vezes?" antes de mutar.** As duas duplicações que causaram
   os piores bugs desta sessão estavam visíveis no código-fonte antes de qualquer mutante.
4. **Costura não testa o que ela substitui, e ambiente compartilhado não é medição.** Um guard foi
   enviado que não podia disparar porque o `doctor` roda com `measureSizes: false` e todo teste
   injetava um scanner que media.

Comece pela prioridade 1.
