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
- Árvore git limpa em `3a21954`. Sem push em nenhum commit.

## Leia antes de agir, nesta ordem

1. `CLAUDE.md` — regras não-negociáveis (3, 5, 6, 7 especialmente).
2. `STATUS.md` — **as quatro últimas seções**, de 2026-09-13/14. Elas contêm o essencial.
3. `docs/process/MUTATION-TESTING-NOTES.md` — curto, e evita repetir três erros.
4. `docs/research/FINDINGS-2026-09-05.md` §F16, F18, F22 — só esses.
5. `docs/architecture/HYPOTHESES.md` — H6, H12, H13.

Não releia o resto de `docs/research`.

## Prioridade 1 — E14b fases 0–3 (o portão que mata o H12)

`scripts/experiments/e14b-device-set-external.sh`, **escrito e nunca rodado**. ~15 min, sem sudo.

```
scripts/experiments/e14b-device-set-external.sh /Volumes/<vault>/XCodeVault/E14bSet --i-understand
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

- **E13** — `scripts/experiments/e13-dyld-cache-reboot.sh`, a sonda dos 2,48 GB de cache dyld órfão.
  Roda antes e depois de um restart; só precisa que o usuário reinicie em algum momento.
- **`log erase --all` via `simctl spawn`** — é o único dos três por-device com verbo estreito
  documentado. Reproduzi-lo transformaria `simulatorLogStore` de reportado em oferecível.
- **Containment exato** `<deviceSet>/<UDID>/<subpath>` para as categorias por-device, que faria
  `pathTemplates.first!` parar de ser mentira para elas (hoje é o source default em `M3Commands`).

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
