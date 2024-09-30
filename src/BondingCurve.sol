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
import "forge-std/console.sol";

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
    uint256 public constant ONE = 10 ** DECIMALS;

    // Bonding curve parameters
    int128 private constant B = 5e18; // Fixed-point representation of 5 (scaled by 1e18)
    uint256 private constant A = 848200000000000; // Precomputed 'a' scaled by 1e18

    uint256 public constant LAUNCH_FEE = 0.0002 ether;
    uint256 public constant LAUNCH_REWARD = 0.05 ether;
    uint256 public constant LAUNCH_THRESHOLD = 20 ether;
    // 1 billion * 18 decimals
    uint256 public constant TOKEN_SUPPLY = 1 * 1e9 * ONE;
    // SUBJECT TO CHANGE
    uint256 public constant TOTAL_SALE = (80 * TOKEN_SUPPLY) / 100; // 80% of total supply, though this number won't likely be reached

    uint256 private constant b = 5 * ONE; // Fixed-point representation of 5 (scaled by 1e18)
    uint256 private K; // Constant for bonding curve, scaled

    // State Variables
    address public constant deadAddress =
        address(0x0000000000000000000000000000000000000000);
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

        // Calculate K
        uint256 exp_b = exp(b); // e^(b), scaled by 1e18
        uint256 exp_b_minus_one = exp_b - ONE; // e^(b) - 1, scaled
        K = (LAUNCH_THRESHOLD * ONE) / exp_b_minus_one; // Scale appropriately
    }

    function exp(uint256 x) internal pure returns (uint256) {
        uint256 sum = ONE; // Start with 1 * 10^18 for precision
        uint256 term = ONE; // Initial term = 1 * 10^18
        uint256 xPower = x; // Initial power of x

        for (uint256 i = 1; i <= 128; i++) {
            term = (term * xPower) / (i * ONE); // x^i / i!
            sum += term;

            // Break if term is too small to affect the sum
            if (term < 1) break;
        }

        return sum;
    }

    // High-precision ln(x) implementation for 128.128 fixed-point numbers
    // Constants for ln function

    int128 private constant ln2 = 0xB17217F7D1CF79AB;
    int128 private constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint256 private constant MAX_X = 9223372036854775807 * 1e18;

    function toInt128(uint256 x) internal pure returns (int128) {
        require(x <= MAX_X, "BondingCurve: Overflow in toInt128");
        return int128(int256((x << 64) / 1e18));
    }

    function fromInt128(int128 x) internal pure returns (uint256) {
        // Multiply by 1e18 and shift right by 64 bits
        return (uint256(int256(x)) * 1e18) / (1 << 64);
    }

    // Helper function to find most significant bit
    function log_2(uint256 x) internal pure returns (int128) {
        require(x > 0, "BondingCurve: Input must be greater than zero");

        int128 x64x64 = toInt128(x);

        int256 msb = 0;
        uint256 xc = uint256(int256(x64x64));
        if (xc >= 0x10000000000000000) {
            xc >>= 64;
            msb += 64;
        }
        if (xc >= 0x100000000) {
            xc >>= 32;
            msb += 32;
        }
        if (xc >= 0x10000) {
            xc >>= 16;
            msb += 16;
        }
        if (xc >= 0x100) {
            xc >>= 8;
            msb += 8;
        }
        if (xc >= 0x10) {
            xc >>= 4;
            msb += 4;
        }
        if (xc >= 0x4) {
            xc >>= 2;
            msb += 2;
        }
        if (xc >= 0x2) msb += 1; // No need to shift xc anymore

        int256 result = (msb - 64) << 64;

        uint256 ux = uint256(int256(x64x64)) << uint256(127 - msb);

        for (int256 bit = 0x8000000000000000; bit > 0; bit >>= 1) {
            ux = ux * ux;
            uint256 bbit = ux >> 255;
            ux >>= 127 + bbit;
            result += bit * int256(bbit);
        }

        return int128(result);
    }

    function ln(uint256 x) internal pure returns (uint256) {
        require(x > 0, "BondingCurve: Input must be greater than zero");

        int128 log2Result = log_2(x); // log_2 in 64.64 format

        // Multiply and adjust back to 64.64 format
        int128 lnResult = int128((int256(log2Result) * int256(ln2)) >> 64);

        return fromInt128(lnResult);
    }

    function calculateCumulativeCost(
        uint256 S_sold
    ) internal view returns (uint256 C_S) {
        // x = S_sold / TOTAL_SALE, scaled
        uint256 x = (S_sold * ONE) / TOTAL_SALE;

        // b_x = b * x, scaled
        uint256 b_x = (b * x) / ONE;

        // exp_b_x = e^(b * x), scaled
        uint256 exp_b_x = exp(b_x);

        // C(S) = K * (e^(b * x) - 1), scaled
        C_S = (K * (exp_b_x - ONE)) / ONE;

        return C_S; // Scaled by 1e18
    }

    function calculateSFromCumulativeCost(
        uint256 C_S
    ) internal view returns (uint256 S_sold) {
        // Solve for x: exp_b_x = (C_S * ONE) / K + ONE
        uint256 exp_b_x = (C_S * ONE) / K + ONE;

        // b_x = ln(exp_b_x), scaled
        uint256 b_x = ln(exp_b_x);

        // x = b_x / b, scaled
        uint256 x = (b_x * ONE) / b;

        // S_sold = x * TOTAL_SALE
        S_sold = (x * TOTAL_SALE) / ONE;

        return S_sold;
    }

    function getTokenAmountByPurchase(
        address token,
        uint256 ethAmount
    ) public view returns (uint256 tokenAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S_old = TOTAL_SALE - pool.TokenReserve; // Tokens sold so far

        // Calculate cumulative cost at S_old
        uint256 C_S_old = calculateCumulativeCost(S_old);

        // New cumulative cost after adding ethAmount
        uint256 C_S_new = C_S_old + ethAmount;

        // Solve for S_new using the new cumulative cost
        uint256 S_new = calculateSFromCumulativeCost(C_S_new);

        // Tokens purchased in this transaction
        tokenAmount = S_new - S_old;

        return tokenAmount;
    }

    function getEthAmountToBuyTokens(
        address token,
        uint256 tokenAmount
    ) public view returns (uint256 ethAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S_old = TOTAL_SALE - pool.TokenReserve; // Tokens sold so far
        uint256 S_new = S_old + tokenAmount; // Tokens sold after purchase

        // Calculate cumulative costs
        uint256 C_S_old = calculateCumulativeCost(S_old);
        uint256 C_S_new = calculateCumulativeCost(S_new);

        // ETH required = C(S_new) - C(S_old)
        ethAmount = C_S_new - C_S_old;

        return ethAmount;
    }

    function getEthAmountBySale(
        address token,
        uint256 tokenAmount
    ) public view returns (uint256 ethAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 S_old = TOTAL_SALE - pool.TokenReserve; // Tokens sold so far

        require(
            tokenAmount <= S_old,
            "BondingCurve: Cannot sell more tokens than owned"
        );

        uint256 S_new = S_old - tokenAmount; // Tokens sold after selling

        // Calculate cumulative costs
        uint256 C_S_old = calculateCumulativeCost(S_old);
        uint256 C_S_new = calculateCumulativeCost(S_new);

        // ETH received = C(S_old) - C(S_new)
        ethAmount = C_S_old - C_S_new;

        return ethAmount;
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
            TokenReserve: TOTAL_SALE,
            launched: false
        });

        emit TokenCreate(newTokenAddress, tokenCount, msg.sender);

        // Purchase initial tokens using the bonding curve
        uint256 tokenAmount = getTokenAmountByPurchase(
            newTokenAddress,
            initialFunds
        );

        if (tokenAmount == 0) {
            return;
        }

        require(
            tokenAmount <= TOTAL_SALE,
            "BondingCurve: Cannot purchase more tokens than available"
        );

        uint256 actualEthUsed = getEthAmountToBuyTokens(
            newTokenAddress,
            tokenAmount
        );
        require(
            actualEthUsed <= initialFunds,
            "BondingCurve: Calculated ETH exceeds sent ETH"
        );

        uint256 leftoverEth = initialFunds - actualEthUsed;
        require(
            leftoverEth >= 0,
            "BondingCurve: Leftover ETH cannot be negative"
        );

        virtualPools[newTokenAddress].ETHReserve += (initialFunds -
            leftoverEth);
        virtualPools[newTokenAddress].TokenReserve -= tokenAmount;

        // Transfer tokens to buyer
        Token(newTokenAddress).transfer(msg.sender, tokenAmount);

        if (leftoverEth > 0) {
            (bool success, ) = payable(msg.sender).call{value: leftoverEth}("");
            require(success, "BondingCurve: Refund failed");
        }

        emit TokenPurchased(
            newTokenAddress,
            msg.sender,
            initialFunds,
            tokenAmount,
            virtualPools[newTokenAddress].TokenReserve
        );

        uint256 newPrice = getEthAmountToBuyTokens(newTokenAddress, ONE);
        emit PriceChanged(newTokenAddress, newPrice);
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
        // this is redundant but I added it just for brevity
        require(
            amountMin <= virtualPools[token].TokenReserve,
            "BondingCurve: Cannot purchase more tokens than available"
        );

        uint256 ethAmount = msg.value;

        // Calculate token amount to send
        uint256 tokenAmount = getTokenAmountByPurchase(token, ethAmount);
        if (tokenAmount > virtualPools[token].TokenReserve) {
            tokenAmount = virtualPools[token].TokenReserve;
        }
        require(tokenAmount >= amountMin, "BondingCurve: Slippage exceeded");

        uint256 actualEthUsed = getEthAmountToBuyTokens(token, tokenAmount);
        actualEthUsed = actualEthUsed;

        require(
            actualEthUsed <= ethAmount,
            "BondingCurve: Calculated ETH exceeds sent ETH"
        );

        uint256 leftoverEth = ethAmount - actualEthUsed;
        require(
            leftoverEth >= 0,
            "BondingCurve: Leftover ETH cannot be negative"
        );

        virtualPools[token].ETHReserve += (ethAmount - leftoverEth);
        virtualPools[token].TokenReserve -= tokenAmount;

        // Transfer tokens to buyer
        Token(token).transfer(msg.sender, tokenAmount);

        if (leftoverEth > 0) {
            (bool success, ) = payable(msg.sender).call{value: leftoverEth}("");
            require(success, "BondingCurve: Refund failed");
        }

        // Emit events
        emit TokenPurchased(
            token,
            msg.sender,
            ethAmount,
            tokenAmount,
            virtualPools[token].TokenReserve
        );

        uint256 newPrice = getEthAmountToBuyTokens(token, ONE);
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

        // Check if ETH amount is greater than amountMin
        require(ethAmount >= amountMin, "BondingCurve: Slippage exceeded");

        // Update reserves
        virtualPools[token].ETHReserve -= ethAmount;
        virtualPools[token].TokenReserve += tokenAmount;

        // Transfer ETH to seller
        payable(msg.sender).transfer(ethAmount);

        // Emit event
        emit TokenSold(token, msg.sender, ethAmount, tokenAmount);

        uint256 newPrice = getEthAmountToBuyTokens(token, ONE);
        emit PriceChanged(token, newPrice);
    }

    // Enforce Launch Threshold
    function checkAndLaunchToken(address token) internal {
        VirtualPool storage pool = virtualPools[token];
        if (
            !pool.launched &&
            pool.TokenReserve == 0 &&
            pool.ETHReserve >= (LAUNCH_THRESHOLD - 0.002 ether)
        ) {
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
            block.timestamp + 1 hours
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
