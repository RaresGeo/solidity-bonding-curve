// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "./Token.sol";
// import the uniswap interfaces here
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import the ABDK library here
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "v2-core/interfaces/IUniswapV2Factory.sol";
import "v2-core/interfaces/IUniswapV2Pair.sol";
import "v2-periphery/interfaces/IUniswapV2Router02.sol";

contract BondingCurve is OwnableUpgradeable {
    // Events
    event LaunchPending(address token);
    event LauncherChanged(
        address indexed oldLauncher,
        address indexed newLauncher
    );
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PendingOwnerSet(
        address indexed oldPendingOwner,
        address indexed newPendingOwner
    );
    event TokenCreate(
        address tokenAddress,
        uint256 tokenIndex,
        address creator
    );
    event TokenLaunched(address indexed token);
    event TokenPurchased(
        address indexed token,
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 tokenReserve
    );
    event TokenSold(
        address indexed token,
        address indexed seller,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event PriceChanged(address indexed token, uint256 newPrice);

    uint256 public constant DECIMALS = 18;

    // Bonding curve parameters
    int128 private constant B = 5e18; // Fixed-point representation of 5 (scaled by 1e18)
    uint256 private constant A = 848200000000000; // Precomputed 'a' scaled by 1e18

    uint256 public constant LAUNCH_FEE = 0.0002 ether;
    uint256 public constant LAUNCH_REWARD = 0.05 ether;
    uint256 public constant LAUNCH_THRESHOLD = 20 ether;
    // 1 billion * 18 decimals
    uint256 public constant TOKEN_SUPPLY = 1 * 1e9 * 10 ** DECIMALS;
    // SUBJECT TO CHANGE
    uint256 public constant TOTAL_SALE = (80 * TOKEN_SUPPLY) / 100; // 80% of total supply, though this number won't likely be reached

    // int128 private constant b_fp = ABDKMath64x64.fromInt(5);
    int128 private b_fp;
    int128 private S_max_fp;
    int128 private K;

    // State Variables
    address public deadAddress;
    address public implementation;
    address public launcher;
    uint256 public maxPurchaseAmount;
    address public pendingImplementation;
    address public pendingOwner;
    address public vault;
    address public factory;
    address public router;

    uint256 public tokenCount;
    bool public pause;

    // Mappings
    mapping(uint256 => address) public tokenAddress;
    mapping(address => address) public tokenCreator;
    mapping(address => VirtualPool) public virtualPools;

    struct VirtualPool {
        uint256 ETHReserve;
        uint256 TokenReserve;
        bool launched;
    }

    // Initializer function (replaces constructor)
    function initialize(
        address _vault,
        address _factory,
        address _router,
        uint256 _maxPurchaseAmount,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        vault = _vault;
        maxPurchaseAmount = _maxPurchaseAmount;
        factory = _factory;
        router = _router;

        // Initialize fixed-point constants
        b_fp = ABDKMath64x64.fromInt(5);
        S_max_fp = ABDKMath64x64.fromUInt(TOTAL_SALE);
        int128 exp_b = ABDKMath64x64.exp(b_fp);
        int128 exp_b_minus_1 = ABDKMath64x64.sub(
            exp_b,
            ABDKMath64x64.fromInt(1)
        );
        int128 Total_Cost_fp = ABDKMath64x64.fromUInt(LAUNCH_THRESHOLD);
        K = ABDKMath64x64.div(Total_Cost_fp, exp_b_minus_1);

        deadAddress = address(0x0000000000000000000000000000000000000000);
    }

    // Ownership functions
    function acceptOwner() external {
        require(
            msg.sender == pendingOwner,
            "BondingCurve: Only pending owner can accept ownership"
        );
        emit OwnerChanged(owner(), pendingOwner);
        _transferOwnership(pendingOwner);
        pendingOwner = address(0);
    }

    function setPendingOwner(address newPendingOwner) external onlyOwner {
        emit PendingOwnerSet(pendingOwner, newPendingOwner);
        pendingOwner = newPendingOwner;
    }

    // Token Creation
    function createAndInitPurchase(
        string calldata name,
        string calldata symbol
    ) external payable {
        require(!pause, "BondingCurve: Contract is paused");
        require(msg.value >= LAUNCH_FEE, "BondingCurve: Insufficient fees");

        uint256 initialFunds = msg.value - LAUNCH_FEE;

        // Transfer LAUNCH_FEE to vault
        payable(vault).transfer(LAUNCH_FEE);

        // Create new token
        Token newToken = new Token(name, symbol, TOKEN_SUPPLY, address(this));
        address newTokenAddress = address(newToken);
        tokenCount++;
        tokenAddress[tokenCount] = newTokenAddress;
        tokenCreator[newTokenAddress] = msg.sender;

        // Initialize virtual pool with constants
        virtualPools[newTokenAddress] = VirtualPool({
            ETHReserve: 0,
            TokenReserve: 0,
            launched: false
        });

        emit TokenCreate(newTokenAddress, tokenCount, msg.sender);

        // Purchase initial tokens using the bonding curve
        uint256 tokenAmount = getTokenAmountByPurchase(
            newTokenAddress,
            initialFunds
        );
        require(
            tokenAmount > 0,
            "BondingCurve: Token amount must be greater than zero"
        );

        // Transfer tokens to buyer
        Token(newTokenAddress).transfer(msg.sender, tokenAmount);

        // Update reserves
        virtualPools[newTokenAddress].ETHReserve += initialFunds;
        virtualPools[newTokenAddress].TokenReserve -= tokenAmount;

        emit TokenPurchased(
            newTokenAddress,
            msg.sender,
            initialFunds,
            tokenAmount,
            virtualPools[newTokenAddress].TokenReserve
        );
    }

    /**
     * @dev Returns the current price of the specified token based on the exponential bonding curve.
     * @param token The address of the token.
     * @return price The current price of the token in ETH.
     */
    function getCurrentPrice(
        address token
    ) public view returns (uint256 price) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S = pool.TokenReserve;

        // Convert values to fixed-point format
        int128 S_fp = ABDKMath64x64.fromUInt(S);
        int128 x = ABDKMath64x64.div(S_fp, S_max_fp); // x = S / S_max
        int128 b_x = ABDKMath64x64.mul(b_fp, x); // b * x
        int128 exp_b_x = ABDKMath64x64.exp(b_x); // e^(b * x)

        // P(S) = (K * b / S_max) * e^(b * x)
        int128 P_fp = ABDKMath64x64.mul(
            ABDKMath64x64.div(ABDKMath64x64.mul(K, b_fp), S_max_fp),
            exp_b_x
        );

        price = ABDKMath64x64.toUInt(P_fp);
        return price;
    }

    function purchaseToken(address token, uint256 amountMin) external payable {
        require(!pause, "BondingCurve: Contract is paused");
        require(
            msg.value > 0,
            "BondingCurve: Must send ETH to purchase tokens"
        );
        require(
            !virtualPools[token].launched,
            "BondingCurve: Token already launched"
        );
        require(
            msg.value <= maxPurchaseAmount,
            "BondingCurve: Exceeds max purchase amount"
        );

        uint256 ethAmount = msg.value;

        // Calculate token amount to send
        uint256 tokenAmount = getTokenAmountByPurchase(token, ethAmount);
        require(tokenAmount >= amountMin, "BondingCurve: Slippage exceeded");

        // Update reserves
        virtualPools[token].ETHReserve += ethAmount;
        virtualPools[token].TokenReserve -= tokenAmount;

        // Transfer tokens to buyer
        Token(token).transfer(msg.sender, tokenAmount);

        // Emit event
        emit TokenPurchased(
            token,
            msg.sender,
            ethAmount,
            tokenAmount,
            virtualPools[token].TokenReserve
        );

        uint256 newPrice = getCurrentPrice(token);
        emit PriceChanged(token, newPrice);

        // Check if the token should be launched
        checkAndLaunchToken(token);
    }

    function sellToken(
        address token,
        uint256 tokenAmount,
        uint256 amountMin
    ) external {
        require(!pause, "BondingCurve: Contract is paused");
        require(
            tokenAmount > 0,
            "BondingCurve: Token amount must be greater than zero"
        );
        require(
            !virtualPools[token].launched,
            "BondingCurve: Token already launched"
        );

        // Transfer tokens from seller to contract
        Token(token).transferFrom(msg.sender, address(this), tokenAmount);

        // Calculate ETH amount to send
        uint256 ethAmount = getEthAmountBySale(token, tokenAmount);

        // Update reserves
        virtualPools[token].ETHReserve -= ethAmount;
        virtualPools[token].TokenReserve += tokenAmount;

        // Transfer ETH to seller
        payable(msg.sender).transfer(ethAmount);

        // Emit event
        emit TokenSold(token, msg.sender, ethAmount, tokenAmount);

        uint256 newPrice = getCurrentPrice(token);
        emit PriceChanged(token, newPrice);
    }

    function getTokenAmountByPurchase(
        address token,
        uint256 ethAmount
    ) public view returns (uint256 tokenAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S_old = pool.TokenReserve;

        // Convert values to fixed-point format
        int128 S_old_fp = ABDKMath64x64.fromUInt(S_old);
        int128 x_old = ABDKMath64x64.div(S_old_fp, S_max_fp);
        int128 b_x_old = ABDKMath64x64.mul(b_fp, x_old);
        int128 exp_b_x_old = ABDKMath64x64.exp(b_x_old);
        int128 C_S_old = ABDKMath64x64.mul(
            K,
            ABDKMath64x64.sub(exp_b_x_old, ABDKMath64x64.fromInt(1))
        );

        int128 ethAmount_fp = ABDKMath64x64.fromUInt(ethAmount);
        int128 C_S_new = ABDKMath64x64.add(C_S_old, ethAmount_fp);

        int128 ln_argument = ABDKMath64x64.add(
            ABDKMath64x64.div(C_S_new, K),
            ABDKMath64x64.fromInt(1)
        );

        int128 ln_term = ABDKMath64x64.ln(ln_argument);
        int128 S_new_fp = ABDKMath64x64.mul(
            ABDKMath64x64.div(S_max_fp, b_fp),
            ln_term
        );

        int128 delta_S_fp = ABDKMath64x64.sub(S_new_fp, S_old_fp);
        tokenAmount = ABDKMath64x64.toUInt(delta_S_fp);

        return tokenAmount;
    }

    /**
     * @dev Returns the amount of ETH required to purchase a specified number of tokens based on the exponential bonding curve.
     * @param token The address of the token.
     * @param tokenAmount The desired amount of tokens to purchase.
     * @return ethAmount The amount of ETH required.
     */
    function getEthAmountToBuyTokens(
        address token,
        uint256 tokenAmount
    ) public view returns (uint256 ethAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S_old = pool.TokenReserve;
        uint256 S_new = S_old + tokenAmount;

        // Convert values to fixed-point format
        int128 S_new_fp = ABDKMath64x64.fromUInt(S_new);
        int128 x_new = ABDKMath64x64.div(S_new_fp, S_max_fp); // x = S_new / S_max
        int128 b_x_new = ABDKMath64x64.mul(b_fp, x_new); // b * x_new
        int128 exp_b_x_new = ABDKMath64x64.exp(b_x_new); // e^(b * x_new)

        // C(S_new) = K * (e^(b * x_new) - 1)
        int128 C_S_new = ABDKMath64x64.mul(
            K,
            ABDKMath64x64.sub(exp_b_x_new, ABDKMath64x64.fromInt(1))
        );

        // C(S_old) = K * (e^(b * x_old) - 1)
        int128 S_old_fp = ABDKMath64x64.fromUInt(S_old);
        int128 x_old = ABDKMath64x64.div(S_old_fp, S_max_fp);
        int128 b_x_old = ABDKMath64x64.mul(b_fp, x_old);
        int128 exp_b_x_old = ABDKMath64x64.exp(b_x_old);
        int128 C_S_old = ABDKMath64x64.mul(
            K,
            ABDKMath64x64.sub(exp_b_x_old, ABDKMath64x64.fromInt(1))
        );

        // ETH required = C(S_new) - C(S_old)
        int128 ethAmount_fp = ABDKMath64x64.sub(C_S_new, C_S_old);
        ethAmount = ABDKMath64x64.toUInt(ethAmount_fp);

        return ethAmount;
    }

    function getEthAmountBySale(
        address token,
        uint256 tokenAmount
    ) public view returns (uint256 ethAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S_old = pool.TokenReserve;
        uint256 S_new = S_old - tokenAmount;

        // Convert values to fixed-point format
        int128 S_old_fp = ABDKMath64x64.fromUInt(S_old);
        int128 x_old = ABDKMath64x64.div(S_old_fp, S_max_fp);
        int128 b_x_old = ABDKMath64x64.mul(b_fp, x_old);
        int128 exp_b_x_old = ABDKMath64x64.exp(b_x_old);
        int128 C_S_old = ABDKMath64x64.mul(
            K,
            ABDKMath64x64.sub(exp_b_x_old, ABDKMath64x64.fromInt(1))
        );

        int128 S_new_fp = ABDKMath64x64.fromUInt(S_new);
        int128 x_new = ABDKMath64x64.div(S_new_fp, S_max_fp);
        int128 b_x_new = ABDKMath64x64.mul(b_fp, x_new);
        int128 exp_b_x_new = ABDKMath64x64.exp(b_x_new);
        int128 C_S_new = ABDKMath64x64.mul(
            K,
            ABDKMath64x64.sub(exp_b_x_new, ABDKMath64x64.fromInt(1))
        );

        int128 ethAmount_fp = ABDKMath64x64.sub(C_S_old, C_S_new);
        ethAmount = ABDKMath64x64.toUInt(ethAmount_fp);

        return ethAmount;
    }

    // Enforce Launch Threshold
    function checkAndLaunchToken(address token) internal {
        VirtualPool storage pool = virtualPools[token];
        if (!pool.launched && pool.ETHReserve >= LAUNCH_THRESHOLD) {
            pool.launched = true;
            emit TokenLaunched(token);

            // Create a liquidity pool
            address lqPool = _createLiquidityPool(token);

            // Provide liquidity
            uint tokenAmount = TOKEN_SUPPLY - TOTAL_SALE;
            uint ethAmount = pool.ETHReserve - LAUNCH_REWARD;
            uint liquidity = _provideLiquidity(token, tokenAmount, ethAmount);

            // Burn the LP Token
            _burnLpTokens(lqPool, liquidity);

            // Also burn remaining tokens
            uint256 remainingTokenBalance = Token(token).balanceOf(
                address(this)
            );
            Token(token).burn(remainingTokenBalance);
        }
    }

    function _createLiquidityPool(address token) internal returns (address) {
        address pair = IUniswapV2Factory(factory).createPair(
            token,
            IUniswapV2Router02(router).WETH()
        );
        return pair;
    }

    function _provideLiquidity(
        address token,
        uint tokenAmount,
        uint ethAmount
    ) internal returns (uint) {
        Token(token).approve(router, tokenAmount);
        (, , uint liquidity) = IUniswapV2Router02(router).addLiquidityETH{
            value: ethAmount
        }(
            token,
            tokenAmount,
            tokenAmount,
            ethAmount,
            address(this),
            block.timestamp
        );
        return liquidity;
    }

    function _burnLpTokens(
        address lqPool,
        uint liquidity
    ) internal returns (uint) {
        IUniswapV2Pair(lqPool).transfer(address(0), liquidity);
        return 1;
    }

    // Pause and Unpause
    function pausePad() external onlyOwner {
        pause = true;
    }

    function rerunPad() external onlyOwner {
        pause = false;
    }

    // Set Vault
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    // Fallback function to accept ETH
    receive() external payable {}
}
