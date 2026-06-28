---
title: DevFlow — Schema do .devflow.yaml
status: draft
---

# Schema do `.devflow.yaml`

Contrato de configuração que o plugin DevFlow lê do repositório que o instala. O motor é stack-agnóstico: tudo que varia entre projetos vive aqui. Nenhum valor de stack, modelo, branch ou comando é embutido no plugin.

## Princípios do schema

- **Versionado.** O campo `version` é obrigatório e o motor valida compatibilidade ao carregar. Schema incompatível falha cedo, com mensagem clara, antes de qualquer worktree.
- **Sem declaração de especialista.** Os especialistas não vivem no config. O plugin os descobre por proximidade de diretório nos `.claude/agents/` do projeto (ver "Descoberta de especialistas"). O projeto só organiza seus agentes no formato nativo do Claude Code.
- **Fail-safe.** Defaults escolhem sempre o caminho mais conservador (não deployar antes do PR, isolar falha em vez de seguir cego).

## Descoberta de especialistas (não vive no config)

Decisão de arquitetura que mantém o config enxuto e o roteamento determinístico sem reimplementar o que a plataforma já faz.

O Claude Code já descobre subagents em `.claude/agents/` e já resolve precedência por proximidade: em monorepo com `.claude/` aninhado, a definição mais próxima do diretório de trabalho vence. O DevFlow reaproveita isso. A localização do arquivo do agente é o sinal de roteamento, não um glob no config.

Um hook do motor, antes do spawn do executor:

1. Lê os paths que a tarefa toca.
2. Sobe a árvore de diretórios a partir de cada path e coleta os agentes alcançáveis em `.claude/agents/`.
3. Esse conjunto é o time de especialistas da tarefa.

Casos:

- **Um escopo:** aciona o especialista alcançável daquele escopo.
- **Vários escopos** (tarefa cross-cutting em monorepo): fan-out, um agente por escopo, respeitando `fan_out.max_agents`.
- **Nenhum agente alcançável:** aplica `fallback`.

A decisão é determinística (caminhada de diretório é fato do filesystem, não escolha do modelo) e exige zero declaração: o projeto cria os agentes que fizerem sentido, onde fizerem sentido, e o resto cai no genérico.

Caso deliberadamente em aberto: dois agentes no mesmo escopo. Na prática servem fases diferentes do ciclo (execução vs. review), então raramente competem pelo mesmo slot. Desempate fica para quando for problema real.

## Arquivo de referência anotado

```yaml
# .devflow.yaml
# Contrato de configuração do plugin DevFlow.
# Vive na raiz do repositório que instala o plugin.

# --- Identificação do schema (obrigatório) ---
version: 1                    # int. Versão do schema deste contrato.
                              # O motor recusa carregar se for incompatível.

# --- Git (obrigatório) ---
base_branch: develop          # string. Branch a partir da qual cada worktree
                              # é criado. O motor nunca opera direto nela.

# --- Modelos (obrigatório) ---
# Nomes de modelo são opacos para o plugin: ele apenas repassa.
models:
  plan: <modelo-forte>        # string. Modelo da fase de plan.
  execution: <modelo-exec>    # string. Modelo da fase de execução / fan-out.
  review: <modelo-review>     # string, opcional. Default: igual a `plan`.

# --- Comandos do projeto (obrigatório test; resto opcional) ---
# Strings de shell executadas pelo motor dentro do worktree.
commands:
  test: <comando de teste>    # string, obrigatório. Suíte de testes.
  lint: <comando de lint>     # string, opcional. Pulado se ausente.
  build: <comando de build>   # string, opcional. Pulado se ausente.
  deploy: <comando de deploy> # string, opcional. Sem deploy se ausente.

# --- Fan-out (opcional) ---
fan_out:
  enabled: true               # bool. Default: false.
  max_agents: 4               # int >= 1. Default: 1. Teto de agentes paralelos.
  on_partial_failure: isolate # enum. Default: abort.
                              #   abort   -> cancela o run inteiro
                              #   isolate -> segue com os que passaram,
                              #              marca o que falhou
                              #   retry   -> retenta só os que falharam
  retry_limit: 1              # int >= 0. Default: 0. Só usado se retry.

# --- Gates (opcional) ---
gates:
  deploy_before_pr: false     # bool. Default: false.
                              #   false -> PR aprovado é portão; deploy depois
                              #   true  -> deploy antes do PR (preview/staging)
  require_tests_pass: true    # bool. Default: true. Bloqueia PR se teste falha.
  require_lint_pass: true     # bool. Default: true. Ignorado se sem lint.
  auto_pr: false              # bool. Default: false.
                              #   false -> mostra comando, pede confirmação antes de abrir PR
                              #   true  -> abre PR automaticamente sem perguntar

# --- Spec (opcional) ---
spec:
  tool: openspec              # string, opcional. Ferramenta de spec externa.
                              # Ausente = sem etapa de spec gerenciada.
  require_approved: true      # bool. Default: true quando `tool` presente.
                              # Exige spec aprovada antes de gerar tasks.

# --- Fallback de especialista (opcional) ---
# Aplicado quando a descoberta por proximidade não acha nenhum agente
# alcançável para o escopo da tarefa.
fallback:
  mode: generic               # enum. Default: generic.
                              #   generic -> usa o agente genérico
                              #   refuse  -> motor para e pede um especialista
  generic_agent: <path>       # string, opcional. Subagent genérico.
                              # Default: o genérico de exemplo que o plugin shippa.

# --- Limites (opcional, recomendado em ambiente distribuído) ---
limits:
  max_tokens_per_run: 0       # int >= 0. Default: 0 (sem limite).
                              # > 0 aborta ou pede confirmação ao estourar.
  on_limit: confirm           # enum. Default: confirm. (confirm | abort)

# --- Telemetria (opcional) ---
telemetry:
  enabled: true               # bool. Default: true.
  path: .devflow/runs/        # string. Default: .devflow/runs/.
                              # JSONL por run: fases, reprovações, re-execuções,
                              # tempo, e especialista acionado por escopo.
```

## Referência de campos

| Campo | Tipo | Obrigatório | Default | Notas |
|---|---|---|---|---|
| `version` | int | sim | — | Versão do schema. Motor valida compatibilidade ao carregar. |
| `base_branch` | string | sim | — | Branch base dos worktrees. Motor nunca opera direto nela. |
| `models.plan` | string | sim | — | Modelo da fase de plan. Opaco para o plugin. |
| `models.execution` | string | sim | — | Modelo da execução / fan-out. |
| `models.review` | string | não | = `plan` | Modelo da fase de review. |
| `commands.test` | string | sim | — | Suíte de testes. |
| `commands.lint` | string | não | — | Pulado se ausente. |
| `commands.build` | string | não | — | Pulado se ausente. |
| `commands.deploy` | string | não | — | Sem deploy se ausente. |
| `fan_out.enabled` | bool | não | `false` | Liga o fan-out. |
| `fan_out.max_agents` | int ≥ 1 | não | `1` | Teto de agentes paralelos. |
| `fan_out.on_partial_failure` | enum | não | `abort` | `abort` / `isolate` / `retry`. |
| `fan_out.retry_limit` | int ≥ 0 | não | `0` | Só com `retry`. |
| `gates.deploy_before_pr` | bool | não | `false` | `false` = PR é portão; `true` = preview/staging. |
| `gates.require_tests_pass` | bool | não | `true` | Bloqueia PR se teste falha. |
| `gates.require_lint_pass` | bool | não | `true` | Ignorado se sem lint. |
| `gates.auto_pr` | bool | não | `false` | `false` = pede confirmação; `true` = abre PR automaticamente. |
| `spec.tool` | string | não | — | Ferramenta de spec externa. Ausente = sem etapa de spec. |
| `spec.require_approved` | bool | não | `true`* | *Quando `tool` presente. Exige spec aprovada antes das tasks. |
| `fallback.mode` | enum | não | `generic` | `generic` / `refuse`. |
| `fallback.generic_agent` | string | não | genérico do plugin | Subagent usado quando nenhum especialista é alcançável. |
| `limits.max_tokens_per_run` | int ≥ 0 | não | `0` | `0` = sem limite. |
| `limits.on_limit` | enum | não | `confirm` | `confirm` / `abort`. |
| `telemetry.enabled` | bool | não | `true` | Liga o log estruturado por run. |
| `telemetry.path` | string | não | `.devflow/runs/` | Diretório dos JSONL. |

Note que não há bloco `specialists`. Especialistas são descobertos, não declarados.

## Regras de validação

O motor rejeita o config (com mensagem e sem iniciar worktree) quando:

1. `version` ausente ou incompatível com o plugin instalado.
2. Qualquer campo obrigatório ausente: `base_branch`, `models.plan`, `models.execution`, `commands.test`.
3. `fan_out.enabled: true` com `max_agents < 1`.
4. `fan_out.on_partial_failure: retry` com `retry_limit` ausente ou `< 1`.
5. `fallback.mode: generic` com `generic_agent` apontando para arquivo inexistente (quando informado; se omitido, usa o genérico do plugin).
6. `fallback.mode: refuse` é válido sem `generic_agent`.
7. `spec.require_approved: true` sem `spec.tool` definido.
8. Valor fora do enum em qualquer campo enumerado.

## Exemplos mínimos

### Single-stack

Um `.claude/agents/` na raiz cobre tudo. Sem fan-out.

```yaml
version: 1
base_branch: main
models:
  plan: <modelo-forte>
  execution: <modelo-exec>
commands:
  test: <comando de teste>
# nenhum specialists[]: o agente em .claude/agents/ é descoberto por proximidade
```

### Monorepo com fan-out

Cada área tem seu `.claude/agents/` aninhado; o motor descobre por proximidade e faz fan-out por escopo.

```yaml
version: 1
base_branch: develop
models:
  plan: <modelo-forte>
  execution: <modelo-exec>
commands:
  test: <comando de teste>
  lint: <comando de lint>
  deploy: <comando de deploy preview>
fan_out:
  enabled: true
  max_agents: 4
  on_partial_failure: isolate
gates:
  deploy_before_pr: true        # deploy de preview antes do PR
fallback:
  mode: generic                 # paths sem agente próprio caem no genérico

# estrutura de agentes no repo (não no config):
#   apps/api/.claude/agents/backend.md
#   apps/web/.claude/agents/web.md
#   apps/mobile/.claude/agents/mobile.md
```
