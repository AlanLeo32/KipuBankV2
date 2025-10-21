KipuBank V2 es un contrato inteligente de Solidity que implementa un banco descentralizado multi-token, capaz de aceptar depósitos y retiros en ETH y tokens ERC-20, con límites de retiro y capacidad global expresados en USD, gracias a oráculos de precios Chainlink.
El contrato introduce mejoras significativas respecto a versiones anteriores, orientadas a seguridad, trazabilidad y escalabilidad.# KipuBankV2

Mejoras implementadas

Soporte multi-token: ahora es posible habilitar dinámicamente diferentes tokens ERC-20, cada uno asociado a su propio oráculo de precios.
Control de acceso con AccessControl: se definieron roles administrativos (ADMIN_ROLE) para restringir operaciones críticas como agregar tokens o modificar configuraciones.
Límites globales expresados en USD: tanto la capacidad total del banco como el máximo retiro por operación se expresan en dólares, utilizando oráculos para convertir los valores de cada token.
Integración con Chainlink Price Feeds: se utilizan feeds de precios en tiempo real para calcular equivalencias de ETH o tokens a USD.
Contabilidad normalizada: todos los valores se manejan internamente con 6 decimales, similar a USDC, lo que facilita las operaciones entre tokens con distintos decimales.
Parámetros inmutables: los límites (withdrawalThresholdUSD y bankCapUSD) se fijan en el constructor y no pueden modificarse luego, asegurando transparencia.
Errores personalizados: en lugar de require() genéricos, se emplean errores con nombre, lo que mejora la legibilidad y optimiza el consumo de gas.
Eventos detallados: se registran todas las operaciones relevantes (depósitos, retiros, tokens agregados) para facilitar auditorías y monitoreo.
Protección contra reentradas: mediante ReentrancyGuard, se asegura que no haya vulnerabilidades al realizar transferencias externas.

Instrucciones de despliegue
Requisitos previos

Remix IDE o Hardhat

Solidity 0.8.26

Testnet Sepolia

Chainlink Price Feed ETH/USD:
0x694AA1769357215DE4FAC081bf1f309aDC325306 (Sepolia)
Ejemplo para Sepolia:

_withdrawalThresholdUSD: 5000 * 1e18 → límite de retiro de $5.000

_bankCapUSD: 50000 * 1e18 → capacidad total del banco de $50.000

_ethPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306

Depósitos

ETH:
Llamar depositETH() o enviar ETH directamente al contrato.

Token ERC-20:

Asegurarse de que el token esté soportado (addTokenSupport)
Aprobar el gasto
Llamar depositToken(token, amount)

Retiros

withdrawETH(amount) o
withdrawToken(token, amount)
(respetando los límites en USD configurados)

Consultas útiles

getBalance(user, token) → saldo nativo

getBalanceUSD(user, token) → saldo en USD

getSupportedTokens() → lista de tokens disponibles

getTotalDepositsUSD() → total global en USD

Decisiones de diseño y trade-offs

Uno de los principales objetivos de esta versión fue lograr una arquitectura coherente y segura, equilibrando precisión monetaria, simplicidad de uso y transparencia.

La contabilidad normalizada a 6 decimales se eligió para facilitar las operaciones con múltiples tokens y mantener coherencia entre activos con diferentes unidades, como USDC (6 decimales) o DAI (18). Esto simplifica la suma y comparación de valores, aunque introduce una mínima pérdida de precisión en las conversiones.

La inmutabilidad de los parámetros críticos (como los límites globales o umbrales de retiro) refuerza la confianza de los usuarios, asegurando que las reglas del sistema no cambien arbitrariamente después del despliegue. A cambio, se sacrifica cierta flexibilidad para ajustes dinámicos sin redeployar el contrato.

El uso de oráculos Chainlink garantiza datos confiables y descentralizados sobre precios, fundamentales para calcular equivalencias USD. Sin embargo, introduce una dependencia externa que requiere disponibilidad constante de los oráculos.

Por último, se optó por emitir eventos extensivos y usar AccessControl de OpenZeppelin. Esto mejora la trazabilidad y la seguridad, pero implica un leve incremento en el consumo de gas y almacenamiento. Aun así, el beneficio en términos de transparencia y auditoría justifica plenamente la decisión.
