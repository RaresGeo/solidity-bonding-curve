// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "./Token.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract BondingCurve is OwnableUpgradeable {
    // Events
    event LaunchPending(address token);
    event LauncherChanged(
        address indexed oldLauncher,
        address indexed newLauncher
    );
    event MinTxFeeSet(uint256 oldFee, uint256 newFee);
    event MintFeeSet(uint256 oldFee, uint256 newFee);
    event OperatorChanged(
        address indexed oldOperator,
        address indexed newOperator
    );
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PendingOwnerSet(
        address indexed oldPendingOwner,
        address indexed newPendingOwner
    );
    event PurchaseFeeSet(uint256 oldFee, uint256 newFee);
    event SaleFeeSet(uint256 oldFee, uint256 newFee);
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
        uint256 fee,
        uint256 tokenAmount,
        uint256 tokenReserve
    );
    event TokenSold(
        address indexed token,
        address indexed seller,
        uint256 ethAmount,
        uint256 fee,
        uint256 tokenAmount
    );

    uint256 public constant LAUNCH_FEE = 3_000_000_000;
    uint256 public constant LAUNCH_THRESHOLD =
        200_000_000_000_000_000_000_000_000;
    uint256 public constant LAUNCH_ETH_RESERVE = 138_000_000_000;
    uint256 public constant TOKEN_SUPPLY =
        1_000_000_000_000_000_000_000_000_000;
    uint256 public constant TOTAL_SALE = 800_000_000_000_000_000_000_000_000;
    uint256 public constant VIRTUAL_TOKEN_RESERVE_AMOUNT =
        70_000_000_000_000_000_000_000_000;
    uint256 public constant VIRTUAL_ETH_RESERVE_AMOUNT = 35_000_000_000;

    // State Variables
    address public deadAddress;
    address public implementation;
    uint256 public launchFee;
    address public launcher;
    uint256 public maxPurchaseAmount;
    uint256 public minTxFee;
    uint256 public mintFee;
    address public operator;
    address public pendingImplementation;
    address public pendingOwner;
    uint256 public purchaseFee;
    uint256 public saleFee;
    address public v2Router;
    address public vault;

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
        address _v2Router,
        uint256 _saleFee,
        uint256 _purchaseFee,
        uint256 _mintFee,
        uint256 _minTxFee,
        uint256 _maxPurchaseAmount,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        vault = _vault;
        v2Router = _v2Router;
        saleFee = _saleFee;
        purchaseFee = _purchaseFee;
        mintFee = _mintFee;
        minTxFee = _minTxFee;
        maxPurchaseAmount = _maxPurchaseAmount;

        // Set default values (can be adjusted later by the owner)
        // DANIEL'S NOTE: not sure what this dead address does. The LLM did not generate any use for it. I assume it is for burning tokens.
        deadAddress = address(0xdead);
        launchFee = LAUNCH_FEE;
        // DANIEL'S NOTE: operator also does not do anything in this contract. I have allowed it to be different from the owner.
        operator = msg.sender;
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

    // Fee functions
    function setPurchaseFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1e18, "BondingCurve: Fee cannot exceed 100%");
        emit PurchaseFeeSet(purchaseFee, _fee);
        purchaseFee = _fee;
    }

    function setSaleFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1e18, "BondingCurve: Fee cannot exceed 100%");
        emit SaleFeeSet(saleFee, _fee);
        saleFee = _fee;
    }

    function setMinTxFee(uint256 newFee) external onlyOwner {
        emit MinTxFeeSet(minTxFee, newFee);
        minTxFee = newFee;
    }

    // DANIEL'S NOTE: I'm not sure why there is a mint fee
    function setMintFee(uint256 newFee) external onlyOwner {
        emit MintFeeSet(mintFee, newFee);
        mintFee = newFee;
    }

    function setMintAndMinTxFee(
        uint256 _newMintFee,
        uint256 _newMinTxFee
    ) external onlyOwner {
        emit MintFeeSet(mintFee, _newMintFee);
        emit MinTxFeeSet(minTxFee, _newMinTxFee);
        mintFee = _newMintFee;
        minTxFee = _newMinTxFee;
    }

    // Token Creation
    function createAndInitPurchase(
        string calldata name,
        string calldata symbol
    ) external payable {
        require(!pause, "BondingCurve: Contract is paused");
        require(
            msg.value >= LAUNCH_FEE + mintFee,
            "BondingCurve: Insufficient fees"
        );

        uint256 initialFunds = msg.value - LAUNCH_FEE - mintFee;

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
            ETHReserve: VIRTUAL_ETH_RESERVE_AMOUNT,
            TokenReserve: VIRTUAL_TOKEN_RESERVE_AMOUNT,
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

        // Transfer mint fee to vault
        payable(vault).transfer(mintFee);
    }

    // Purchase Token
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
        uint256 fee = (ethAmount * purchaseFee) / 1e18;
        if (fee < minTxFee) {
            fee = minTxFee;
        }
        uint256 netAmount = ethAmount - fee;

        // Calculate token amount to send
        uint256 tokenAmount = getTokenAmountByPurchase(token, netAmount);
        require(tokenAmount >= amountMin, "BondingCurve: Slippage exceeded");

        // Transfer fee to vault
        // DANIEL'S NOTE: I moved this, it happened after emitting the event before. But it's better to transfer the fee first. To avoid reentrancy attacks.
        payable(vault).transfer(fee);

        // Update reserves
        virtualPools[token].ETHReserve += netAmount;
        virtualPools[token].TokenReserve -= tokenAmount;

        // Transfer tokens to buyer
        Token(token).transfer(msg.sender, tokenAmount);

        // Emit event
        emit TokenPurchased(
            token,
            msg.sender,
            ethAmount,
            fee,
            tokenAmount,
            virtualPools[token].TokenReserve
        );

        // Check if the token should be launched
        checkAndLaunchToken(token);
    }

    // Sell Token
    // DANIEL'S NOTE: This function name looks like a typo. It should be "sellToken" instead
    function saleToken(
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
        uint256 fee = (ethAmount * saleFee) / 1e18;
        if (fee < minTxFee) {
            fee = minTxFee;
        }
        uint256 netAmount = ethAmount - fee;
        require(netAmount >= amountMin, "BondingCurve: Slippage exceeded");

        // Transfer fee to vault
        // DANIEL'S NOTE: I also moved this, it was after emitting the event before. But it's better to transfer the fee first. To avoid reentrancy attacks.
        payable(vault).transfer(fee);

        // Update reserves
        virtualPools[token].ETHReserve -= netAmount;
        virtualPools[token].TokenReserve += tokenAmount;

        // Transfer ETH to seller
        payable(msg.sender).transfer(netAmount);

        // Emit event
        emit TokenSold(token, msg.sender, ethAmount, fee, tokenAmount);
    }

    // Get Token Amount By Purchase
    function getTokenAmountByPurchase(
        address token,
        uint256 ethAmount
    ) public view returns (uint256 tokenAmount) {
        VirtualPool memory pool = virtualPools[token];
        require(
            pool.TokenReserve > 0 && pool.ETHReserve > 0,
            "BondingCurve: Invalid reserves"
        );

        uint256 tokenReserve = pool.TokenReserve;
        uint256 ethReserve = pool.ETHReserve;

        // Bonding curve formula using constant product market maker (CPMM)
        // DANIEL'S NOTE: This is essentially the bonding curve formula. We should decide on a formula and change this
        // DANIEL'S NOTE: I think we will use an exponential curve in the future.
        uint256 k = tokenReserve * ethReserve;
        uint256 newEthReserve = ethReserve + ethAmount;
        uint256 newTokenReserve = k / newEthReserve;
        tokenAmount = tokenReserve - newTokenReserve;
    }

    // Get ETH Amount By Sale
    function getEthAmountBySale(
        address token,
        uint256 tokenAmount
    ) public view returns (uint256 ethAmount) {
        VirtualPool memory pool = virtualPools[token];
        require(
            pool.TokenReserve > 0 && pool.ETHReserve > 0,
            "BondingCurve: Invalid reserves"
        );

        uint256 tokenReserve = pool.TokenReserve;
        uint256 ethReserve = pool.ETHReserve;

        // Bonding curve formula using constant product market maker (CPMM)
        // DANIEL'S NOTE: Same as the purchase function, we should decide on a formula and change this
        uint256 k = tokenReserve * ethReserve;
        uint256 newTokenReserve = tokenReserve + tokenAmount;
        uint256 newEthReserve = k / newTokenReserve;
        ethAmount = ethReserve - newEthReserve;
    }

    // Enforce Launch Threshold
    function checkAndLaunchToken(address token) internal {
        VirtualPool storage pool = virtualPools[token];
        if (!pool.launched && pool.ETHReserve >= LAUNCH_THRESHOLD) {
            pool.launched = true;
            // DANIEL'S NOTE: I am unsure if we can launch the token here. I guess we might have to listen for this event on our backend and then launch the token on the DEX.
            emit TokenLaunched(token);
        }
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
