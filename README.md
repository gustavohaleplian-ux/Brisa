# Brisa

Controle o seu ar-condicionado **LG ThinQ** direto da barra de menus do Mac.

Brisa é um app nativo para macOS, feito em Swift e SwiftUI. Ele fica na barra de menus,
mostra a temperatura e abre um painel com os controles do aparelho: ligar e desligar,
temperatura, modo, ventilação, sono e direção do vento. Tudo isso com uma ilustração
animada do fluxo de ar, que reage ao ponteiro do mouse.

<p align="center">
  <img src="docs/brisa.gif" alt="O Brisa na barra de menus do Mac: o painel abre, o ar é ligado e o vento reage ao ponteiro" width="360">
</p>

> Projeto independente, sem vínculo com a LG Electronics ou a Apple.

---

## Recursos

- **Barra de menus**: com o ar ligado, mostra a temperatura escolhida; desligado, mostra
  a temperatura ambiente. O ícone ganha ou perde o fluxo de ar com uma animação suave.
- **Painel de controle**
  - Ligar e desligar.
  - Temperatura em graus inteiros, como no controle remoto, por barra deslizante ou
    pelos botões − e +. Os limites vêm do próprio aparelho.
  - **Modo**: Resfriar, Desumidificar, Ventilar e outros que o aparelho oferecer.
  - **Ventilação**: Natural, 1, 2, 3, 4 e 5.
  - **Sono**: desligar em 1 a 7 horas, ou desativar o temporizador.
  - **Direção**: oscilar ou parar a oscilação vertical.
  - **Eco**: quando o aparelho oferece o modo pela API.
- **Resposta imediata**: o valor escolhido aparece na hora e é confirmado com o aparelho
  em segundo plano. Se o aparelho não confirmar, a tela volta ao estado real.
- **Atualização automática**: a cada 5 minutos, ao abrir o painel e quando o Mac acorda.
- **Animação do vento**: partículas que saem do aparelho, perdem força com a distância
  e são afastadas ou lançadas pelo ponteiro do mouse. Respeita o "Reduzir movimento" do macOS.
- **Iniciar com o Mac**, nas configurações.
- **Menu "…"**, nas configurações, para reiniciar ou encerrar o Brisa.
- **Fecha ao clicar fora**: um clique em qualquer lugar fora do Brisa fecha o painel, e
  junto com ele qualquer menu aberto.
- **Modo de demonstração**, para ver o painel sem conectar uma conta. Ele usa o perfil de um
  aparelho LG real, com todos os controles disponíveis, e começa como um aparelho de verdade:
  desligado, em 24 °C, com o ambiente em 28 °C. Toca os bipes do aparelho ao ligar, desligar
  e ajustar. Nenhum comando é enviado.

## Requisitos

- macOS 14 (Sonoma) ou mais recente.
- Xcode recente, para compilar.
- Um ar-condicionado LG que já funcione no app **LG ThinQ** e seja compatível com a
  **API ThinQ Connect**. Nem todo modelo com Wi-Fi é compatível.
- Conta LG da região **Brasil**.

## Baixar o app pronto

1. Em [Releases](https://github.com/gustavohaleplian-ux/Brisa/releases/latest), baixe o
   arquivo `Brisa-…zip` e abra-o para extrair o `Brisa.app`.
2. Arraste o `Brisa.app` para a pasta **Aplicativos**.
3. Abra o Brisa. Como o app não é notarizado pela Apple, o macOS avisa que não pode verificar
   o desenvolvedor e não abre. Para liberar, uma única vez:
   - abra **Ajustes do Sistema → Privacidade e Segurança**;
   - role até a mensagem sobre o Brisa e clique em **Abrir Mesmo Assim**;
   - confirme com a senha do Mac.
4. O ícone aparece na barra de menus. Comece por **Experimentar demonstração** ou conecte a
   sua conta LG.

Funciona em Macs com Apple Silicon e Intel, com macOS 14 ou mais recente.

## Compilar a partir do código

1. Clone o repositório e abra `Brisa.xcodeproj` no Xcode.
2. Escolha o esquema **Brisa** e o destino **My Mac**.
3. Pressione **⌘R**. O ícone aparece na barra de menus; o app não abre janela nem aparece no Dock.

Para gerar um `.app` de uso diário, rode `bash build-mac.sh`. O script compila em modo
Release e abre `build/Release/Brisa.app`, que pode ser copiado para a pasta Aplicativos.
O app é assinado só localmente e não é notarizado pela Apple.

> O "Iniciar com o Mac" funciona melhor com o app copiado para a pasta Aplicativos.

## Conectar a sua conta LG

1. No painel, abra as configurações e clique em **Gerar chave no portal da LG**
   (https://connect-pat.lgthinq.com).
2. Entre com a mesma conta usada no app LG ThinQ.
3. Gere uma chave pessoal (Personal Access Token) com acesso à lista de aparelhos,
   ao perfil, ao estado e ao controle.
4. Cole a chave no Brisa e clique em **Conectar ao meu ar**.

A chave fica guardada no **Chaves** (Keychain) do macOS e nunca é mostrada de novo.
Para trocá-la, use **Remover chave** nas configurações.

---

## Como funciona

### Estrutura do projeto

```
AppIcon.icon                      Ícone do app (Icon Composer, com Liquid Glass)
Assets.xcassets                   Marca do Brisa (as três rajadas) usada dentro do app
Sounds/                           Bipes do aparelho, tocados só no modo de demonstração
docs/                             Imagens deste README
Sources/
├── App/
│   └── BrisaApp.swift            Entrada do app, item da barra de menus, ícone animado,
│                                 abertura e fechamento do painel
├── Model/
│   ├── ClimateModel.swift        Estado do aparelho, comandos, ajuste de temperatura,
│   │                             atualização automática, modo de demonstração
│   └── DemoSounds.swift          Toca os bipes do aparelho na demonstração
├── Networking/
│   ├── ThinQClient.swift         Requisições HTTPS à API LG ThinQ Connect e erros
│   └── TokenVault.swift          Leitura e gravação da chave no Chaves do macOS
└── Views/
    ├── ClimatePanel.swift        Painel principal e tela de configurações
    ├── Components/
    │   ├── ControlCard.swift     Cards de Modo, Ventilação, Sono e Direção, e seus menus
    │   ├── ControlSurface.swift  Estilo de vidro (Liquid Glass no macOS 26)
    │   ├── TemperatureTrack.swift  Barra de temperatura (mouse, teclado e VoiceOver)
    │   ├── LaunchAtLoginRow.swift  Opção "Iniciar com o Mac"
    │   └── PopupMenuButton.swift   Menu "…" com visual nativo, preso ao painel
    └── Airflow/
        ├── AirIllustration.swift O aparelho e o fluxo de ar
        ├── ParticleField.swift   Simulação das partículas de ar
        └── PointerTracking.swift Leitura do ponteiro e transição de ligar/desligar
```

### Comunicação com a LG

O Brisa fala diretamente com a API **LG ThinQ Connect** por HTTPS, sem servidor
intermediário. O protocolo foi reimplementado em Swift a partir do
[SDK oficial da LG](https://github.com/thinq-connect/pythinqconnect).

| Ação | Requisição |
|---|---|
| Listar aparelhos | `GET /devices` |
| Capacidades do aparelho | `GET /devices/{id}/profile` |
| Estado atual | `GET /devices/{id}/state` |
| Enviar comando | `POST /devices/{id}/control` |

- **Servidor**: `api-aic.lgthinq.com`, a região da LG que atende o Brasil, com `x-country: BR`.
- **Cabeçalhos**: os mesmos do SDK oficial (`Authorization`, `x-api-key`, `x-client-id`,
  `x-message-id` e `x-service-phase`).
- **`x-client-id`**: gerado uma vez por instalação e reaproveitado, como a LG pede.
- **`x-api-key`**: é a chave **pública** de aplicativo distribuída no SDK da LG, igual para
  todos. Ela não é a sua chave pessoal e não dá acesso a nenhuma conta.

### Perfil do aparelho

Cada modelo descreve, no **perfil**, quais recursos tem, se são só de leitura ou também
graváveis, e quais valores aceitam. O Brisa lê esse perfil e:

- monta os menus com os valores que o aparelho declara;
- desativa os controles que o aparelho não oferece, mostrando "Indisponível";
- nunca envia comandos para recursos ausentes ou valores fora do que foi declarado.

### Comandos e confirmação

1. O novo valor aparece na tela na hora, marcado como pendente.
2. O comando é enviado. Nunca há dois comandos ao mesmo tempo.
3. O app relê o estado do aparelho algumas vezes, em intervalos crescentes, até confirmar.
4. Se o aparelho recusar ou não confirmar, a tela volta ao estado real.

Um erro num controle não trava os outros.

### Ajuste de temperatura

A temperatura tem um fluxo próprio, pensado para ajustes rápidos:

- **Espera de 0,5 s** depois do último toque ou arraste: ir de 23 °C a 19 °C envia só 19 °C.
- **Intervalo mínimo de 3 s** entre comandos de temperatura.
- **Só o último valor vale**: valores intermediários nunca entram numa fila.
- Um aviso discreto mostra "Ajustando…", "Temperatura ajustada" ou
  "Não foi possível ajustar a temperatura. Tente novamente.". Os códigos técnicos
  da LG ficam só no registro interno.
- Recusas passageiras da LG ganham **uma** nova tentativa. Antes de mostrar erro, o app
  confere se o aparelho aplicou o ajuste mesmo assim.

### Atualização automática

O estado é lido em segundo plano a cada **5 minutos**. A temperatura ambiente muda
devagar, mas a mesma leitura mostra se o ar foi ligado, desligado ou ajustado pelo
controle remoto. Também há uma leitura ao abrir o painel, se a última tiver mais de
1 minuto, e outra quando o Mac acorda. Essas leituras são silenciosas: não travam
controles e, se falharem, mantêm o último dado na tela.

### Animação do fluxo de ar

A animação roda a 60 fps e só enquanto o painel está aberto e o ar ligado.

- **Partículas**: cada uma sai da saída do aparelho com velocidade, alcance e
  aparência próprios. Ela ondula, desacelera e se espalha ao perder força.
- **Ponteiro**: parado no fluxo, afasta o ar ao redor; em movimento, transfere a própria
  velocidade e pode lançar as partículas longe. Depois elas planam de volta para o fluxo.
- **Velocidade**: a ventilação escolhida muda o vento. Do 1 ao 5 o ar fica mais rápido e
  mais denso, e o Natural varia devagar, como rajadas.
- **Névoa**: uma camada bem desfocada dá volume ao vento.
- **Ligar e desligar**: ao ligar, a aleta abre, o ventilador ganha rotação e o ar engrossa
  aos poucos. Ao desligar, a saída para e o ar que já saiu termina de descer.

### Comportamentos da API LG

Comportamentos observados em testes com um aparelho real, e tratados pelo app:

| Situação | Resposta da LG | Como o Brisa lida |
|---|---|---|
| Dois comandos quase simultâneos | `2208` (falha no controle) | Comandos sempre um de cada vez |
| Temperatura com o aparelho desligado | `2304` | Controle de temperatura desativado |
| Temperatura no modo Ventilar | `2305` | Mensagem simples, sem código na tela |
| Sono acima de 7 horas | `2201` | Menu oferece de 1 a 7 h |
| Recusa passageira de um valor válido | `2201`, raramente | Uma nova tentativa automática |
| Alvo de temperatura | Fica no recurso `temperature`, não em `temperatureInUnits` | O app procura onde o perfil permite gravar |

Outros modelos LG podem ter limites diferentes.

## Privacidade e segurança

- A chave pessoal fica **só no Chaves** do macOS, acessível só neste Mac e com ele desbloqueado.
- O app se conecta **apenas** a `api-aic.lgthinq.com`, por HTTPS e com a validação de
  certificado padrão do sistema.
- Não há telemetria, analytics nem servidores próprios.
- O registro interno (subsistema com o identificador do app) guarda valores e códigos
  de erro, nunca a chave.

Para acompanhar os ajustes de temperatura no Terminal:

```bash
log stream --predicate 'subsystem == "com.surtocriativo.Brisa"' --level info
```

## Ajustes finos

Os principais valores ficam concentrados em constantes, fáceis de mudar:

| Constante | Arquivo | Padrão | O que controla |
|---|---|---|---|
| `autoRefreshInterval` | `ClimateModel.swift` | 5 min | Intervalo da atualização automática |
| `temperatureDebounce` | `ClimateModel.swift` | 0,5 s | Espera depois do último ajuste |
| `temperatureSpacing` | `ClimateModel.swift` | 3 s | Intervalo mínimo entre comandos de temperatura |
| `emissionRate` | `ParticleField.swift` | 40/s | Quantidade de partículas |
| `pointerCarry` | `ParticleField.swift` | 0,85 | Quão longe o mouse lança o ar |
| `pointerPush` | `ParticleField.swift` | 800 | Quanto o ponteiro parado afasta o ar |
| `drag` | `ParticleField.swift` | 1,6 | Quanto tempo o ar plana antes de voltar ao fluxo |
| `streamLength` | `AirIllustration.swift` | 135 pt | Alcance do vento |

## Limitações

- Funciona só com aparelhos **LG** compatíveis com a API ThinQ Connect.
- A região está fixada em **Brasil**.
- Foi testado com um modelo de aparelho; outros podem ter recursos e limites diferentes.
- A API pública da LG não oferece posições fixas da aleta, só oscilar ou parar.
- O app não é notarizado. Para distribuir fora do GitHub, é preciso assinar com uma
  conta de desenvolvedor Apple e notarizar.

## Licença

O **código** do Brisa é distribuído sob a [licença MIT](LICENSE): você pode usar, copiar,
modificar e distribuir, inclusive em projetos comerciais, desde que mantenha o aviso de
copyright e a licença.

O **nome Brisa**, o **ícone** (`AppIcon.icon`) e a **marca das três rajadas**
(`Assets.xcassets/BrisaMark`) não fazem parte da licença MIT: todos os direitos reservados
a SurtoCriativo. Os sons em `Sounds/` são gravações dos bipes de um ar-condicionado LG,
incluídos apenas para o modo de demonstração.

## Créditos

O protocolo da API foi reimplementado a partir do SDK oficial da LG,
[pythinqconnect](https://github.com/thinq-connect/pythinqconnect), licenciado sob
Apache 2.0. Veja `THIRD-PARTY-NOTICES.md` e `LICENSE-LG-SDK.txt`. Nenhum código do SDK é
incluído no app.
