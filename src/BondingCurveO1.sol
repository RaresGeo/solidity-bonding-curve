// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "./Token.sol";
// import the uniswap interfaces here
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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

    uint256 public constant DECIMALS = 18;

    uint256 public constant LAUNCH_FEE = 0.0002 ether;
    uint256 public constant LAUNCH_REWARD = 0.05 ether;
    uint256 public constant LAUNCH_THRESHOLD = 20 ether;
    // 1 billion * 18 decimals
    uint256 public constant TOKEN_SUPPLY = 1 * 1e9 * 10 ** DECIMALS;
    // SUBJECT TO CHANGE
    uint256 public constant TOTAL_SALE = (80 * TOKEN_SUPPLY) / 100; // 80% of total supply, though this number won't likely be reached
    uint256 private constant K = 1e16; // initial price constant
    uint256 private constant A = 1e18; // Steepness of the curve (adjustable)

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

    // Operator functions
    // DANIEL'S NOTE: Again, this is not doing anything currently.
    function setOperator(address newOperator) external onlyOwner {
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
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
            0,
            tokenAmount,
            virtualPools[newTokenAddress].TokenReserve
        );
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

        // Transfer fee to vault
        // DANIEL'S NOTE: I also moved this, it was after emitting the event before. But it's better to transfer the fee first. To avoid reentrancy attacks.
        payable(vault).transfer(fee);

        // Update reserves
        virtualPools[token].ETHReserve -= ethAmount;
        virtualPools[token].TokenReserve += tokenAmount;

        // Transfer ETH to seller
        payable(msg.sender).transfer(ethAmount);

        // Emit event
        emit TokenSold(token, msg.sender, ethAmount, tokenAmount);
    }

    function getTokenAmountByPurchase(
        address token,
        uint256 ethAmount
    ) public view returns (uint256 tokenAmount) {
        VirtualPool memory pool = virtualPools[token];
        uint256 tokenReserve = pool.TokenReserve;

        uint256 exponential = 1 +
            (A.mul(tokenReserve).div(10 ** DECIMALS)) +
            (
                A.mul(tokenReserve).mul(tokenReserve).div(
                    2 * 10 ** DECIMALS * 10 ** DECIMALS
                )
            );

        // Calculate token price using the exponential bonding curve
        uint256 price = K.mul(exponential).div(10 ** DECIMALS);

        // Calculate how many tokens can be bought with the ethAmount
        tokenAmount = ethAmount.mul(10 ** DECIMALS).div(price);
    }

    function getEthAmountBySale(
        address token,
        uint256 tokenAmount
    ) public view returns (uint256 ethAmount) {
        VirtualPool memory pool = virtualPools[token];

        uint256 tokenReserve = pool.TokenReserve;

        // Reverse the exponential bonding curve to calculate ETH from tokens
        // Formula would depend on the reverse of the token purchase calculation
        uint256 price = K.mul(1 + A.mul(tokenReserve).div(10 ** DECIMALS)).div(
            10 ** DECIMALS
        );

        // Calculate how much ETH should be received for the tokenAmount
        ethAmount = tokenAmount.mul(price).div(10 ** DECIMALS);
    }

    // Enforce Launch Threshold
    function checkAndLaunchToken(address token) internal {
        VirtualPool storage pool = virtualPools[token];
        if (!pool.launched && pool.ETHReserve >= LAUNCH_THRESHOLD) {
            pool.launched = true;
            emit TokenLaunched(token);

            // Create a liquidity pool
            address pool = _createLiquidityPool(token);
            console.log("Pool address ", pool);

            // Provide liquidity
            uint tokenAmount = TOKEN_SUPPLY - TOTAL_SALE;
            uint ethAmount = listedToken.fundingRaised - LAUNCH_REWARD;
            uint liquidity = _provideLiquidity(token, tokenAmount, ethAmount);

            // Burn the LP Token
            _burnLpTokens(pool, liquidity);

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
        address pool,
        uint liquidity
    ) internal returns (uint) {
        IUniswapV2Pair(pool).transfer(address(0), liquidity);
        console.log("Uni v2 tokens burnt");
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
