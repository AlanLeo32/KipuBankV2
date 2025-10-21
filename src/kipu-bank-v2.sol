// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title KipuBank V2
 * @notice Banco multi-token con límites globales en USD y control de acceso por roles.
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rol de administrador: puede agregar/quitar tokens y administrar parámetros.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Umbral máximo de retiro por transacción en USD (18 decimales).
    /// @dev Inmutable: se define en el constructor, no puede cambiar.
    uint256 public immutable i_withdrawalThresholdUSD;
    
    /// @notice Tope (cap) global del banco en USD (18 decimales). Suma total de depósitos.
    /// @dev Inmutable: se define en el constructor, no puede cambiar.
    uint256 public immutable i_bankCapUSD;
    
    /// @notice Decimales que usamos para contabilidad estilo USDC (6 decimales).
    /// @dev Normalizamos saldos a 6 decimales para facilidad de sumas por token.
    uint8 private constant USDC_DECIMALS = 6;
    
    /// @notice Decimales estándar para reportar USD (18 decimales), útil para feeds y umbrales.
    uint8 private constant USD_DECIMALS = 18;
    
    /// @notice Identificador del token nativo (ETH). Se usa address(0) por convención.
    address private constant NATIVE_ETH = address(0);
    
    /// @notice Saldos por usuario y por token, normalizados a 6 decimales .
    mapping(address user => mapping(address token => uint256 balance)) private s_deposits;
    
    /// @notice Total depositado por token (también en 6 decimales).
    mapping(address token => uint256 total) private s_totalDeposits;
    
    /// @notice Oráculo Chainlink por token para obtener precio TOKEN/USD.
    mapping(address token => AggregatorV3Interface priceFeed) private s_priceFeeds;
    
    /// @notice Lista de tokens habilitados (incluye NATIVE_ETH).
    address[] private s_supportedTokens;
    
    /// @notice Métricas: número total de depósitos realizados.
    uint256 public s_depositCount;
    
    /// @notice Métricas: número total de retiros realizados.
    uint256 public s_withdrawalCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Se emite cuando un usuario deposita.
    /// @param user Cuenta que deposita.
    /// @param token Token depositado (address(0) = ETH).
    /// @param amount Monto en decimales nativos del token (wei para ETH).
    /// @param usdValue Valor equivalente en USD (18 decimales).
    event DepositMade(address indexed user, address indexed token, uint256 amount, uint256 usdValue);
    
    /// @notice Se emite cuando un usuario retira.
    /// @param user Cuenta que retira.
    /// @param token Token retirado (address(0) = ETH).
    /// @param amount Monto en decimales nativos del token (wei para ETH).
    /// @param usdValue Valor equivalente en USD (18 decimales).
    event WithdrawalMade(address indexed user, address indexed token, uint256 amount, uint256 usdValue);
    
    /// @notice Se emite al habilitar un token ERC-20.
    event TokenAdded(address indexed token, address indexed priceFeed);
    
    /// @notice Se emite al deshabilitar un token ERC-20.
    event TokenRemoved(address indexed token);

    /*//////////////////////////////////////////////////////////////
                          ERRORES PERSONALIZADOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Monto igual a cero.
    error KipuBank__ZeroAmount();
    
    /// @notice Se excede el cap global del banco (en USD).
    error KipuBank__BankCapExceeded(uint256 requestedUSD, uint256 availableUSD);
    
    /// @notice Saldo insuficiente para retirar.
    error KipuBank__InsufficientBalance(uint256 requestedAmount, uint256 availableBalance);
    
    /// @notice Se excede el umbral de retiro por transacción (en USD).
    error KipuBank__WithdrawalThresholdExceeded(uint256 requestedUSD, uint256 thresholdUSD);
    
    /// @notice Transferencia fallida (genérico).
    error KipuBank__TransferFailed();
    
    /// @notice Token no soportado (no tiene feed configurado o es inválido).
    error KipuBank__TokenNotSupported(address token);
    
    /// @notice Token ya estaba habilitado.
    error KipuBank__TokenAlreadySupported(address token);
    
    /// @notice El oráculo devolvió precio inválido (<= 0) o datos corruptos.
    error KipuBank__InvalidPriceData();
    
    /// @notice Falló el envío de ETH nativo.
    error KipuBank__ETHTransferFailed();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa el banco con umbral de retiro y cap global en USD.
     * @param _withdrawalThresholdUSD Umbral por retiro en USD (18 decimales).
     * @param _bankCapUSD Cap global de depósitos en USD (18 decimales).
     * @param _ethPriceFeed Dirección del feed Chainlink ETH/USD.
     */
    constructor(
        uint256 _withdrawalThresholdUSD,
        uint256 _bankCapUSD,
        address _ethPriceFeed
    )
    {
        // Validaciones básicas de parámetros ( errores personalizados)
        if (_withdrawalThresholdUSD == 0 || _bankCapUSD == 0) {
            revert KipuBank__ZeroAmount();
        }

        i_withdrawalThresholdUSD = _withdrawalThresholdUSD;
        i_bankCapUSD = _bankCapUSD;

        // Roles: el deployer es admin por defecto (AccessControl)
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // Habilitar ETH como token soportado y setear su oráculo
        s_priceFeeds[NATIVE_ETH] = AggregatorV3Interface(_ethPriceFeed);
        s_supportedTokens.push(NATIVE_ETH);
    }

    /*//////////////////////////////////////////////////////////////
                         RECEIVE & FALLBACK (ETH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Recibe ETH directamente y lo trata como depósito.
    receive() external payable {
        _deposit(NATIVE_ETH, msg.value);
    }

    /// @notice Fallback: no aceptamos otras llamadas sin datos; revertimos.
    fallback() external payable {
        revert KipuBank__TransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                          FUNCIONES EXTERNAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposita ETH nativo (address(0)).
     */
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert KipuBank__ZeroAmount();
        _deposit(NATIVE_ETH, msg.value);
    }

    /**
     * @notice Deposita un token ERC-20 habilitado.
     * @param token Dirección del token ERC-20.
     * @param amount Monto a depositar (en decimales nativos del token).
     */
    function depositToken(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert KipuBank__ZeroAmount();
        if (token == NATIVE_ETH) revert KipuBank__TokenNotSupported(token);
        if (address(s_priceFeeds[token]) == address(0)) {
            revert KipuBank__TokenNotSupported(token);
        }

        // INTERACCIÓN segura primero (transferencia hacia el contrato),
        // luego delegamos la contabilidad a _deposit (efectos + evento).
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(token, amount);
    }

    /**
     * @notice Retira ETH de tu saldo.
     * @param amount Monto en wei a retirar.
     */
    function withdrawETH(uint256 amount) external nonReentrant {
        if (amount == 0) revert KipuBank__ZeroAmount();
        _withdraw(NATIVE_ETH, amount);
    }

    /**
     * @notice Retira tokens ERC-20 de tu saldo.
     * @param token Dirección del token.
     * @param amount Monto a retirar (en decimales nativos del token).
     */
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert KipuBank__ZeroAmount();
        if (token == NATIVE_ETH) revert KipuBank__TokenNotSupported(token);
        _withdraw(token, amount);
    }

    /**
     * @notice Habilita soporte para un nuevo token ERC-20.
     * @param token Dirección del token.
     * @param priceFeed Dirección del oráculo TOKEN/USD (Chainlink).
     */
    function addTokenSupport(address token, address priceFeed) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (token == NATIVE_ETH) revert KipuBank__TokenNotSupported(token);
        if (address(s_priceFeeds[token]) != address(0)) {
            revert KipuBank__TokenAlreadySupported(token);
        }

        s_priceFeeds[token] = AggregatorV3Interface(priceFeed);
        s_supportedTokens.push(token);

        emit TokenAdded(token, priceFeed);
    }

    /**
     * @notice Deshabilita un token (debe no tener depósitos pendientes).
     * @param token Dirección del token a deshabilitar.
     */
    function removeTokenSupport(address token) external onlyRole(ADMIN_ROLE) {
        if (address(s_priceFeeds[token]) == address(0)) {
            revert KipuBank__TokenNotSupported(token);
        }
        if (s_totalDeposits[token] > 0) {
            revert KipuBank__InsufficientBalance(0, s_totalDeposits[token]);
        }

        delete s_priceFeeds[token];

        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            if (s_supportedTokens[i] == token) {
                s_supportedTokens[i] = s_supportedTokens[s_supportedTokens.length - 1];
                s_supportedTokens.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES INTERNAS (CEI)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lógica interna de depósito (ETH o ERC-20).
     * @param token Token a depositar (address(0) = ETH).
     * @param amount Monto en decimales nativos del token.
     * @dev Patrón CEI:
     *      - CHECKS: calcular USD, verificar cap global.
     *      - EFFECTS: actualizar contabilidad normalizada a USDC(6).
     *      - INTERACTIONS: sólo evento (tokens ya fueron transferidos arriba).
     */
    function _deposit(address token, uint256 amount) private {
        // CHECKS
        uint256 usdValue = _getUSDValue(token, amount);        // USD(18)
        uint256 currentTotalUSD = _getTotalDepositsUSD();      // USD(18)
        
        if (currentTotalUSD + usdValue > i_bankCapUSD) {
            revert KipuBank__BankCapExceeded(
                usdValue, 
                i_bankCapUSD - currentTotalUSD
            );
        }

        // EFFECTS (contabilidad en 6 decimales)
        uint256 normalizedAmount = _normalizeToUSDC(token, amount); // a USDC(6)
        s_deposits[msg.sender][token] += normalizedAmount;
        s_totalDeposits[token] += normalizedAmount;
        s_depositCount++;

        // INTERACTIONS 
        emit DepositMade(msg.sender, token, amount, usdValue);
    }

    /**
     * @notice Lógica interna de retiro (ETH o ERC-20).
     * @param token Token a retirar (address(0) = ETH).
     * @param amount Monto en decimales nativos del token.
     */
    function _withdraw(address token, uint256 amount) private {
        // CHECKS
        uint256 normalizedAmount = _normalizeToUSDC(token, amount);
        uint256 userBalance = s_deposits[msg.sender][token];
        
        if (normalizedAmount > userBalance) {
            revert KipuBank__InsufficientBalance(normalizedAmount, userBalance);
        }

        uint256 usdValue = _getUSDValue(token, amount); // USD(18)
        if (usdValue > i_withdrawalThresholdUSD) {
            revert KipuBank__WithdrawalThresholdExceeded(
                usdValue,
                i_withdrawalThresholdUSD
            );
        }

        // EFFECTS
        s_deposits[msg.sender][token] -= normalizedAmount;
        s_totalDeposits[token] -= normalizedAmount;
        s_withdrawalCount++;

        // INTERACTIONS
        if (token == NATIVE_ETH) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) revert KipuBank__ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit WithdrawalMade(msg.sender, token, amount, usdValue);
    }

    /*//////////////////////////////////////////////////////////////
                          FUNCIONES DE CÁLCULO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Convierte un monto de `token` a USD(18) usando Chainlink.
     * @param token Token cuyo valor queremos evaluar (address(0) = ETH).
     * @param amount Monto en decimales nativos del token.
     * @return USD con 18 decimales.
     */
    function _getUSDValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = s_priceFeeds[token];
        

        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) revert KipuBank__InvalidPriceData();

        // Decimales del token (18 si es ETH), y del feed 
        uint8 tokenDecimals = token == NATIVE_ETH ? 18 : IERC20Metadata(token).decimals();
        uint8 priceFeedDecimals = priceFeed.decimals();

        // Fórmula: USD(18) = amount * price * 10^18 / (10^tokenDecimals * 10^priceFeedDecimals)
        return (amount * uint256(price) * 10**USD_DECIMALS) / 
               (10**tokenDecimals * 10**priceFeedDecimals);
    }

    /**
     * @notice Normaliza montos del token a 6 decimales (USDC-like) para contabilidad.
     * @param token Token.
     * @param amount Monto en decimales nativos del token.
     * @return Monto normalizado a 6 decimales.
     */
    function _normalizeToUSDC(address token, uint256 amount) private view returns (uint256) {
        uint8 tokenDecimals = token == NATIVE_ETH ? 18 : IERC20Metadata(token).decimals();
        
        if (tokenDecimals > USDC_DECIMALS) {
            return amount / (10**(tokenDecimals - USDC_DECIMALS));
        } else if (tokenDecimals < USDC_DECIMALS) {
            return amount * (10**(USDC_DECIMALS - tokenDecimals));
        }
        return amount;
    }

    /**
     * @notice Suma el total global en USD(18) recorriendo tokens soportados.
     */
    function _getTotalDepositsUSD() private view returns (uint256) {
        uint256 totalUSD = 0;
        
        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            address token = s_supportedTokens[i];
            uint256 normalizedAmount = s_totalDeposits[token]; // USDC(6)
            
            if (normalizedAmount > 0) {
                // Convertimos de 6 decimales a nativos del token
                uint256 nativeAmount = _denormalizeFromUSDC(token, normalizedAmount);
                // Y de nativos a USD(18) por oráculo
                totalUSD += _getUSDValue(token, nativeAmount);
            }
        }
        
        return totalUSD;
    }

    /**
     * @notice Convierte desde 6 decimales (USDC-like) a decimales nativos del token.
     * @param token Token.
     * @param normalizedAmount Monto en 6 decimales.
     * @return Monto en decimales nativos del token.
     */
    function _denormalizeFromUSDC(address token, uint256 normalizedAmount) 
        private 
        view 
        returns (uint256) 
    {
        uint8 tokenDecimals = token == NATIVE_ETH ? 18 : IERC20Metadata(token).decimals();
        
        if (tokenDecimals > USDC_DECIMALS) {
            return normalizedAmount * (10**(tokenDecimals - USDC_DECIMALS));
        } else if (tokenDecimals < USDC_DECIMALS) {
            return normalizedAmount / (10**(USDC_DECIMALS - tokenDecimals));
        }
        return normalizedAmount;
    }

    /*//////////////////////////////////////////////////////////////
                              FUNCIONES VIEW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Devuelve el saldo del usuario en decimales nativos del token.
     * @param user Dirección del usuario.
     * @param token Token (address(0) = ETH).
     */
    function getBalance(address user, address token) external view returns (uint256) {
        uint256 normalizedBalance = s_deposits[user][token];          // USDC(6)
        return _denormalizeFromUSDC(token, normalizedBalance);        // nativos
    }

    /**
     * @notice Devuelve el saldo del usuario en USD(18).
     * @param user Dirección del usuario.
     * @param token Token (address(0) = ETH).
     */
    function getBalanceUSD(address user, address token) external view returns (uint256) {
        uint256 normalizedBalance = s_deposits[user][token];          // USDC(6)
        uint256 nativeAmount = _denormalizeFromUSDC(token, normalizedBalance);
        return _getUSDValue(token, nativeAmount);
    }

    /**
     * @notice Devuelve el total depositado para un token (en decimales nativos).
     * @param token Token.
     */
    function getTotalDeposits(address token) external view returns (uint256) {
        return _denormalizeFromUSDC(token, s_totalDeposits[token]);
    }

    /**
     * @notice Devuelve el total global de depósitos en USD(18) sumando todos los tokens.
     */
    function getTotalDepositsUSD() external view returns (uint256) {
        return _getTotalDepositsUSD();
    }

    /**
     * @notice Devuelve la capacidad disponible del banco en USD(18) (cap - total actual).
     */
    function getAvailableBankCapUSD() external view returns (uint256) {
        uint256 currentTotal = _getTotalDepositsUSD();
        return currentTotal >= i_bankCapUSD ? 0 : i_bankCapUSD - currentTotal;
    }

    /**
     * @notice Lista de tokens soportados actualmente (incluye ETH).
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return s_supportedTokens;
    }

    /**
     * @notice Indica si un token está soportado (tiene oráculo configurado).
     */
    function isTokenSupported(address token) external view returns (bool) {
        return address(s_priceFeeds[token]) != address(0);
    }

    /**
     * @notice Devuelve la dirección del oráculo TOKEN/USD para un token.
     */
    function getPriceFeed(address token) external view returns (address) {
        return address(s_priceFeeds[token]);
    }

}

/**
 * @notice Interfaz mínima para consultar `decimals()` cuando el token lo expone.
 * @dev No forma parte del estándar ERC-20 base; es una extensión muy común (ERC20 Metadata).
 */
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
