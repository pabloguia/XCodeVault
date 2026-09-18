# Briefing: revisão exaustiva antes de abrir o código

> **Documento de trabalho.** Existe para ser executado uma vez e depois apagado, como o
> `PROMPT-PUBLICATION-PREP.md` antes dele. Se você está lendo isto num repositório já público,
> alguém esqueceu de apagá-lo — apague.

Você está numa sessão limpa. O repositório está pronto para ser publicado e **não vai ser publicado
hoje**: o dono segurou o push para que esta revisão aconteça primeiro. Seu trabalho é deixá-lo no
melhor estado possível antes que cada decisão que ele carrega vire permanente aos olhos de
estranhos.

Leia `CLAUDE.md` (carregado automaticamente), depois `STATUS.md` e
`docs/process/KNOWN-ISSUES-AT-PUBLICATION.md`. Só então comece.

**Duas coisas sobre a própria sessão, antes de qualquer trabalho:**

- **Converse em português.** O dono do repositório é brasileiro. Código, commits, comentários e
  documentação do projeto continuam em inglês; a conversa com ele, não.
- **Escreva os achados em disco conforme aparecem, não no fim.** Crie
  `docs/process/REVIEW-<data>.md` no primeiro achado e vá acrescentando. Esta sessão vai ser longa e
  vai compactar, e um achado que só existe no contexto morre na compactação — junto com o motivo
  pelo qual você decidiu não corrigi-lo.

---

## 1. Autonomia, e onde ela termina

Você tem autonomia total para investigar, decidir, corrigir, reescrever, reorganizar e apagar
dentro da árvore de trabalho. Não peça permissão para cada achado; corrija e registre. Não pare no
primeiro problema para perguntar se deve continuar.

Cinco coisas **não** são suas, e nenhuma delas é negociável por conveniência:

1. **Nunca `sudo`, nunca peça a senha do dono.** Se algo exigir root, escreva o script e entregue o
   comando para ele rodar.
2. **Antes de tocar em qualquer device de simulador:** rode `pgrep -fl xcodebuild` e
   `xcrun simctl list devices`, e diga qual device você vai tocar. Há plataformas de teste rodando
   nesta máquina.
3. **Commite só com `swift build && swift test` verdes, conferindo o código de saída real, não um
   grep.** O shell é zsh: `${PIPESTATUS[0]}` devolve vazio. Use `cmd > log 2>&1; rc=$?`.
4. **Mudança que copia/move/apaga/monta dados vai para `migration-safety-reviewer` antes do commit;
   mudança no helper vai para `helper-security-reviewer`.** A skill `safety-review` faz o despacho.
   Você não pode revisar o que você mesmo escreveu — essa é a regra permanente do repositório, e
   ela existe porque foi violada e custou caro.
5. **Não crie o remote e não faça push.** Isso é irreversível e é do dono.

E uma sexta, que este briefing acrescenta porque é fácil de não enxergar:

6. **Não reescreva o histórico do git de novo.** Ele já foi reescrito em 2026-09-17;
   `docs/process/HISTORY-REWRITE-2026-09-17.md` mapeia 9 SHAs repontados e o único backup é um
   bundle fora do repositório. Uma segunda reescrita invalida esse mapa e toda referência a SHA nos
   documentos. Se você concluir que é necessária, **pare e escreva a recomendação** — a decisão é do
   dono.

---

## 2. Inventário medido (2026-09-17, 96 commits, branch `main`)

| | |
|---|---|
| Código | 36 arquivos Swift, 6.831 linhas em 6 targets |
| — `XCodeVaultCore` | 28 arquivos, 5.352 linhas — a única camada de domínio |
| — `xcodevaultctl` | 4 arquivos, 720 linhas |
| — `XCodeVaultHelperCore` | 1 arquivo, 327 linhas — lógica do daemon root |
| — `XCodeVaultHelper` | 1 arquivo, 29 linhas — só bootstrap |
| — `XCodeVaultHelperProtocol` | 1 arquivo, 93 linhas — a fronteira XPC |
| — `XCodeVault` | 1 arquivo, 310 linhas — app SwiftUI |
| Testes | 4.745 linhas, **269 testes, 0 falhas** |
| Documentação | 29 `.md` em `docs/` (6.121 linhas) + 8 na raiz |
| Config agêntica | 3 agentes, 3 skills, 2 hooks em `.claude/`; espelho em `.codex/` |
| ADRs | 6 (0000 template + 0001–0005) |

**Arquivos maiores, por ordem** — não são culpados por serem grandes, mas são onde procurar
primeiro: `STATUS.md` (1.856), `DoctorAndScanTests.swift` (1.249), `FINDINGS-2026-09-05.md`
(1.158), `Doctor.swift` (1.025), `COMPATIBILITY_MATRIX.md` (839), `MigrationEngine.swift` (839),
`ReviewFixTests.swift` (712).

**Portões que devem continuar verdes** (todos com exit code conferido, não grep):

```bash
swift build          # 0 warnings
swift test           # 269 testes, 0 falhas
bash scripts/helper-invariants.sh
bash scripts/experiments/test-common.sh   # 32 checks
```

---

## 3. As seis frentes

Trate cada uma como uma passagem independente. Não misture achados de frentes diferentes no mesmo
commit.

### 3.1 Engenharia agêntica com Claude Code

O objetivo não é "mais configuração", é **contexto barato e confiável**. Um arquivo que o modelo
carrega em toda sessão e não usa é imposto sobre cada tarefa futura.

- `CLAUDE.md` é o ponto de entrada sempre carregado. Ele deve ser curto e apontar; qualquer coisa
  nele que esteja duplicada em `docs/` é peso morto. Verifique se cada ponteiro ainda resolve e se
  cada regra ainda é verdadeira.
- `AGENTS.md` existe para o Codex e **espelha** o `CLAUDE.md`. Dois arquivos que precisam ser
  editados juntos derivam; já derivaram uma vez (`.Codex/` com C maiúsculo). Decida se a duplicação
  se paga e, se sim, deixe explícito em cada um que o outro existe e precisa acompanhar.
- `.codex/` inteiro é um espelho de `.claude/`: agentes em `.toml` em vez de `.md`, hooks
  byte-idênticos. Mesma pergunta, mesma resposta esperada.
- Os 3 agentes (`helper-security-reviewer`, `migration-safety-reviewer`, `storage-researcher`)
  foram usados de verdade nesta base e **acharam coisas que nenhum humano achou**. Avalie a
  descrição de cada um (é ela que decide se o agente é acionado na hora certa), o escopo de
  ferramentas, e se falta algum — nota: **nenhuma revisão até hoje olhou para arquitetura nem para
  a própria configuração agêntica**, o que é parte do motivo desta sessão existir.
- As 3 skills (`safety-review`, `run-experiment`, `add-catalog-category`): a descrição dispara? O
  procedimento ainda bate com o repositório?
- Os hooks: `helper-guard.sh` já foi rebaixado de "controle" para "conveniência" depois de uma
  revisão demonstrar que ele não distingue uso de menção e não vê `cat >`, `sed -i`, `git apply`.
  O cabeçalho dele agora diz isso. Confira se o `swift-format-lint.sh` merece o mesmo escrutínio.
- **ADRs**: 6 existem. Há decisões arquiteturais tomadas nesta base **sem ADR**? A 0005 registra a
  abertura do código; a 0004 registra a demissão do mount canônico. Procure reversões silenciosas.
- **Histórico em documento**: você tem autorização explícita do dono para **resumir ou apagar**
  histórico que não agrega. `STATUS.md` tem 1.856 linhas de log cronológico; grande parte é
  narrativa de sessão que já não informa ninguém. `BOOTSTRAP_PROMPT.md` e
  `PROMPT-PUBLICATION-PREP.md` são briefings concluídos. **Mas**: o que vira commit é público para
  sempre, então antes de apagar, pergunte se aquilo é a *única* cópia de uma razão. Uma decisão sem
  o porquê registrado é uma decisão que alguém vai desfazer.
- Os `PROMPT-*.md` e o `SESSION-HANDOFF.md` estão em português enquanto o resto do repositório está
  em inglês. Para um leitor de fora isso é ruído, e está listado em KNOWN-ISSUES. Decida e execute.

### 3.2 Arquitetura e engenharia de software

- Limites de módulo: `XCodeVaultCore` é a única camada de domínio por ADR-0003. Isso se sustenta?
  Há lógica de domínio vazando para `xcodevaultctl` ou para o app SwiftUI?
- `Doctor.swift` com 1.025 linhas e `MigrationEngine.swift` com 839 são os candidatos óbvios a
  responsabilidade demais. **Não parta nada só por tamanho** — parta se houver dois motivos de
  mudança no mesmo arquivo.
- A fronteira XPC (`XCodeVaultHelperProtocol`, 93 linhas) é o contrato mais caro do repositório:
  tudo que passa por ali é superfície de ataque com privilégio de root. Ela está mínima?
- Acoplamento a detalhes do sistema: `getattrlist`, `statfs`, `fts`, `getgrouplist` aparecem
  espalhados ou estão atrás de costuras testáveis? A lição do `getgrouplist` — um defeito que
  nenhum teste alcançava porque morava num target executável — é o padrão a procurar.
- Injeção de dependência: o motor de migração ganhou `volumeUUIDAt` injetável para permitir
  injeção de falha. Onde mais falta essa costura?

### 3.3 Desenvolvimento Apple

- **Swift 6**: o modo de linguagem é `.v6`. Há **5 `@unchecked Sendable`** na árvore — cada um tem
  justificativa escrita, e ela ainda é verdadeira?
  Há `@preconcurrency` ou supressão de warning escondendo um problema real de concorrência?
- **Swift API Design Guidelines**: nomes de tipos, métodos e argumentos. Uma API pública lida em voz
  alta deve formar uma frase.
- **Disponibilidade**: mínimo macOS 14.0 (ADR-0001). Há `if #available` para versões abaixo disso?
  Há uso de API mais nova sem anotação?
- **Estrutura SwiftPM**: `Package.swift` — dependências do helper (a propriedade "só dois
  dependentes" hoje é sustentada só por revisão humana; o checker não lê o `Package.swift`),
  `swiftSettings`, plataformas, e se algum target expõe mais do que precisa.
- **Helper privilegiado**: `SMAppService.daemon`, `setCodeSigningRequirement`, plist do LaunchDaemon.
  `docs/architecture/SECURITY_MODEL.md` é a especificação; `scripts/helper-invariants.sh` é o
  controle mecânico dela e roda em CI. **Ele já foi derrotado por mutação três vezes** e tem 13
  bypasses conhecidos listados em KNOWN-ISSUES.
- **Assinatura e distribuição**: `scripts/bundle-app.sh` e `scripts/release.sh` — assinatura
  inside-out, sem `--deep`, library validation ligada, notarização. O helper está atrás de
  `--with-helper`, desligado por padrão, e **deve continuar assim** enquanto os 6 achados abertos
  existirem.
- **Diagnóstico**: `print` versus `os.Logger`, e o que de dados do usuário pode acabar num log.
- **Concorrência real**: nada que faça I/O de disco pesado deve estar bloqueando a main thread do
  app SwiftUI.

### 3.4 Code review — código simples de manter

O leitor a imaginar é alguém que chega ao repositório em seis meses sem nenhum contexto desta
conversa.

- Funções longas com muitos retornos; condicionais aninhadas que escondem o caminho feliz.
- Erros: `MigrationError` com string versus tipos que o chamador consegue discriminar. Há `try?`
  engolindo uma falha que importa?
- Nomes que mentem, ou que só fazem sentido para quem viveu a sessão em que nasceram.
- **Comentários que prometem verificação inexistente.** Já foram encontrados dois nesta base, e um
  comentário falso é pior que nenhum, porque é nele que o próximo revisor confia. Todo comentário
  que afirma um fato sobre o sistema deve ser verificável — e se você não conseguir verificar,
  reescreva para dizer o que de fato se sabe.
- Duplicação: `xcv_redact` (shell) e `Redaction.swift` fazem o mesmo trabalho em duas linguagens,
  com duas suítes de teste. Isso é deliberado (contextos diferentes) ou é derrapagem esperando para
  acontecer?
- Código morto: verbos do helper sem cliente, opções de CLI sem caminho, ramos inalcançáveis. O
  `removeStrandedRuntimeDownload` é candidato declarado a deleção — leia o que KNOWN-ISSUES diz.

### 3.5 Qualidade de software

- **269 testes é uma contagem, não uma medida.** A pergunta é o que eles pegam. Para cada teste que
  guarda uma propriedade de segurança, **mute a implementação e confirme que ele falha.** Um teste
  que passa com o bug reintroduzido não estava testando nada — três já foram encontrados assim aqui.
- Organização: `ReviewFixTests.swift` tem 712 linhas e o nome descreve *de onde vieram*, não *o que
  guardam*. `DoctorAndScanTests.swift` tem 1.249.
- **20 `XCTSkip` na suíte.** Um `XCTSkip` que dispara sempre é um teste que não existe, e ele
  reporta verde. Rode a suíte e conte quantos desses 20 realmente pularam nesta máquina — e o
  que acontece com eles num runner de CI, que não tem volume externo nem os simuladores daqui.
- CI (`.github/workflows/ci.yml`, macos-15 + macos-26): os quatro portões estão lá? Algum passo
  pode reportar sucesso sem ter rodado?
- `COMPATIBILITY_MATRIX.md`: nenhuma linha pode dizer "supported" sem a Definition of Done de
  `docs/product/NON_GOALS_AND_SAFETY.md`. Confira uma por uma.

### 3.6 Licença, proveniência e o que sai no DMG

Frente curta e a mais fácil de esquecer, porque nada nela quebra um teste.

- **MIT foi escolhida em ADR-0005.** `swift-argument-parser` é **Apache License 2.0** e é ligado
  estaticamente no binário que o `bundle-app.sh` empacota. A Apache-2.0 §4 exige propagar atribuição
  em obras distribuídas, e **não existe `NOTICE` nem `THIRD-PARTY-LICENSES` neste repositório**.
  Determine o que é de fato exigido e faça — isto é a categoria de achado que bloqueia publicação.
- **Proveniência.** `mac-ssd-rescue` aparece em 4 arquivos de código. Uma checagem rápida indica que
  são referências de **interoperabilidade** — o `doctor` detecta e nomeia o layout que aquela
  ferramenta cria, o que é uso nominativo e não derivação. Confirme isso em toda a árvore, incluindo
  `docs/process/PRIOR_ART.md` e os testes, e confirme que nenhum trecho foi copiado de lá ou de
  qualquer outra fonte.
- **Cabeçalhos de licença nos fontes:** o projeto tem zero. Decida se quer, aplique de forma
  consistente, ou registre a decisão de não ter. Qualquer das três serve; o que não serve é metade.
- `Package.resolved` está versionado. Confirme que as versões pinadas não carregam CVE conhecido.

---

## 4. Como provar que uma verificação rodou

Esta é a lição mais cara desta base, e ela vale mais que qualquer achado individual.

Na preparação da publicação, **três varreduras separadas reportaram "limpo" sem ter varrido nada**:
um `git grep` sobre 86 revisões que bateu silenciosamente no limite de tamanho de argumento; um
parser que saiu do laço num cabeçalho curto; e um `grep -c … || echo 0` que emitiu `"0\n0"`, fazendo
a comparação dar erro e o `&&` curto-circuitar por cima do teste. As três só apareceram porque
alguém rodou um **controle positivo**.

Portanto, nesta sessão:

- **Toda varredura precisa de um controle positivo.** Plante um caso que a varredura *deve* achar e
  confirme que ela acha, antes de acreditar num resultado vazio.
- **Todo checker e todo teste de regressão precisa de mutação.** Quebre o que ele guarda e confirme
  que ele grita.
- Distinga sempre "não encontrei" de "não procurei". Se uma verificação não pôde rodar, diga isso
  em vez de reportar limpo.
- `git checkout -- <arquivo>` restaura o conteúdo **commitado** e destrói trabalho não commitado.
  Isso já desfez um refactor inteiro nesta base, durante a limpeza de uma mutação.

E duas armadilhas específicas desta árvore:

- **Refatoração precisa preservar comportamento, e "preserva" é uma afirmação que precisa de prova.**
  Antes de partir um arquivo ou reescrever uma função, confirme que existe teste cobrindo o
  comportamento que você vai mover. Se não existir, **escreva o teste primeiro, veja-o passar contra
  o código atual**, e só então mexa. 269 testes não cobrem 6.831 linhas por igual, e uma revisão que
  quebra o que funcionava causou exatamente o dano que existia para evitar.
- **Dois placeholders são load-bearing e precisam continuar placeholders.** `TEAMID_PLACEHOLDER` em
  `Sources/XCodeVaultHelper/main.swift` é *afirmado presente* por `scripts/helper-invariants.sh`:
  preenchê-lo quebra o CI e remove um guarda fail-closed que faz o daemon recusar-se a servir sem
  team id real. `<owner>` em `packaging/homebrew/xcodevault.rb` é deliberado — um nome de dono
  registrável por qualquer pessoa é risco de supply chain no minuto em que o repositório abre.

---

## 5. Severidade: o que bloqueia, o que corre, o que vira issue

Você tem mandato aberto, e mandato aberto sem modelo de severidade produz ou gold-plating ou
thrash. Classifique **todo** achado num destes três e diga qual no relatório:

1. **Bloqueia a publicação.** Segurança alcançável por um cliente, perda de dados, vazamento de
   identidade da máquina, problema de licença, ou qualquer afirmação falsa numa superfície que um
   estranho lê primeiro — um README que promete o que o código não faz é isto. Corrija antes de
   tudo e diga em voz alta.
2. **Corrija agora porque fica mais caro depois.** Qualquer coisa que entre no histórico público e
   depois exija uma segunda correção pública: nomes de API, formato do journal, contrato XPC,
   estrutura de diretórios, nomes de comando da CLI.
3. **Vira issue.** Melhoria real que não piora com o tempo e que um contribuidor externo poderia
   pegar. **Este é o destino preferido**, não o consolo: um repositório recém-aberto com issues bem
   escritas é mais convidativo que um repositório perfeito e mudo, e é exatamente para isso que o
   `KNOWN-ISSUES-AT-PUBLICATION.md` existe.

O corolário: se um achado não cabe em nenhum dos três, ele não é um achado. Não reescreva código
que funciona porque você o escreveria diferente.

---

## 6. O que não re-litigar

`docs/process/KNOWN-ISSUES-AT-PUBLICATION.md` lista o que foi achado por revisões independentes,
julgado não-bloqueante e **deixado de propósito**, com o motivo de cada um. Leia antes de começar.

Você pode discordar e corrigir qualquer um deles — mas com a razão registrada na mão, não por não
saber que ela existia. Dois em particular são armadilha:

- **A proibição de symlink no `CoreSimulator`** (regra 7). Ela é incondicional, mas o relato de
  quebra em mesmo disco **não reproduziu aqui** (E9). Ela se apoia no que foi de fato observado:
  o CoreSimulator recria um diretório no caminho antigo depois de reiniciar o serviço. Não
  "simplifique" a justificativa de volta para o relato não verificado — isso já foi corrigido uma
  vez.
- **O par `abort`/`forget` do motor de migração** custou **três rodadas** de "corrijo, quebro outra
  coisa". A versão atual termina por construção: conta entradas `ABORT_FAILED` e limita o redirect a
  um. Se você for mexer nisso, entenda primeiro por que as duas versões anteriores — que
  *previam* se uma remoção ia funcionar — falharam.

---

## 7. Entregáveis

1. **Todos os achados resolvidos na árvore de trabalho**, em commits lógicos, cada um com os quatro
   portões verdes por exit code real e `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
   Commits que tocam helper ou dados levam também a linha `Reviewed-by:` do agente que revisou.
2. **`docs/process/REVIEW-<data>.md`**: o que foi revisado, o que foi achado, o que foi corrigido,
   e — a parte que mais importa — **o que foi deixado e por quê**. Um achado sem decisão registrada
   volta como surpresa depois.
3. **`KNOWN-ISSUES-AT-PUBLICATION.md` atualizado**: o que esta revisão resolveu sai; o que ela
   acrescentou entra.
4. **`STATUS.md` e `SESSION-HANDOFF.md` atualizados** para refletir o estado real.
5. **Quatro verificações finais**, cada uma com controle positivo:
   - **Varredura de vazamento sobre o que *esta sessão* escreveu.** O redator
     (`scripts/experiments/common.sh`, `Redaction.swift`) filtra arquivos de evidência, não
     documentos novos. Nome de usuário, caminho de home, rótulo e UUID de volume não podem aparecer
     em nada que você criou. Plante um caso e confirme que a varredura o acha antes de acreditar num
     resultado vazio.
   - **Clone limpo compila.** `git clone` para um diretório temporário, `swift build && swift test`.
     Caminho absoluto embutido, arquivo que o build precisa e não está versionado, ou dependência
     que só existe nesta máquina — nada disso aparece de outro jeito, e todos aparecem para o
     primeiro estranho que clonar.
   - **Os templates de issue são YAML válido.** O GitHub ignora em silêncio um `.yml` malformado em
     `.github/ISSUE_TEMPLATE/`, e você descobre quando o primeiro usuário não consegue abrir uma
     issue.
   - **Todo comando do README roda como está escrito.** Rode um por um. É controle positivo
     aplicado a documentação.

6. **O comando de push entregue ao dono**, não executado:

   ```bash
   git remote add origin git@github.com:<usuário>/XCodeVault.git && git push -u origin main
   ```

7. Se você encontrar algo que **deveria** bloquear a publicação, diga isso em voz alta e em primeiro
   lugar na sua resposta final. Não enterre no meio de um relatório.

---

## 8. Ordem sugerida

Leitura primeiro (`CLAUDE.md`, `STATUS.md`, `KNOWN-ISSUES`, os 6 ADRs), depois a passagem de
arquitetura — porque ela pode mudar o que faz sentido corrigir nas outras. Depois Apple e code
review, que se sobrepõem. Qualidade e engenharia agêntica por último, porque dependem do estado
final do código. A limpeza de documentação e histórico fecha, já sabendo o que sobrou.

**Licença e proveniência (3.6) não dependem de nada** — rode essa frente no começo, em paralelo com
a leitura. É a mais curta, é a que ninguém lembra, e é a única em que um achado pode bloquear a
publicação sem que nenhum teste fique vermelho.

Rode as frentes independentes em paralelo quando elas não dependerem uma da outra. Não pergunte por
aprovação entre elas — pergunte só quando bater numa das seis linhas da seção 1.
