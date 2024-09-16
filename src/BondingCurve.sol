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

    // State Variables
    uint256 public LAUNCH_FEE;
    uint256 public LAUNCH_THRESHOLD;
    uint256 public LAUNCH_ETH_RESERVE;
    uint256 public TOKEN_SUPPLY;
    uint256 public TOTAL_SALE;
    uint256 public VIRTUAL_TOKEN_RESERVE_AMOUNT;
    uint256 public VIRTUAL_ETH_RESERVE_AMOUNT;

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
        uint256 _purchaseFee
    ) external initializer {
        __Ownable_init();
        vault = _vault;
        v2Router = _v2Router;
        saleFee = _saleFee;
        purchaseFee = _purchaseFee;

        // Set default values (can be adjusted later by the owner)
        LAUNCH_FEE = 1 ether;
        LAUNCH_THRESHOLD = 100 ether;
        LAUNCH_ETH_RESERVE = 1000 ether;
        TOKEN_SUPPLY = 1e9 * 1e18; // 1 billion tokens with 18 decimals
        VIRTUAL_TOKEN_RESERVE_AMOUNT = 1e6 * 1e18;
        VIRTUAL_ETH_RESERVE_AMOUNT = 1000 ether;
        deadAddress = address(0xdead);
        launchFee = 1 ether;
        maxPurchaseAmount = 100 ether;
        minTxFee = 0.01 ether;
        mintFee = 0.1 ether;
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
        require(msg.value >= mintFee, "BondingCurve: Insufficient mint fee");
        uint256 initialFunds = msg.value - mintFee;

        // Create new token
        Token newToken = new Token(name, symbol, TOKEN_SUPPLY, address(this));
        address newTokenAddress = address(newToken);
        tokenCount++;
        tokenAddress[tokenCount] = newTokenAddress;
        tokenCreator[newTokenAddress] = msg.sender;

        // Initialize virtual pool
        virtualPools[newTokenAddress] = VirtualPool({
            ETHReserve: VIRTUAL_ETH_RESERVE_AMOUNT,
            TokenReserve: VIRTUAL_TOKEN_RESERVE_AMOUNT,
            launched: false
        });

        emit TokenCreate(newTokenAddress, tokenCount, msg.sender);

        // Purchase initial tokens
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

        uint256 ethAmount = msg.value;
        uint256 fee = (ethAmount * purchaseFee) / 1e18;
        if (fee < minTxFee) {
            fee = minTxFee;
        }
        uint256 netAmount = ethAmount - fee;

        // Calculate token amount to send
        uint256 tokenAmount = getTokenAmountByPurchase(token, netAmount);
        require(tokenAmount >= amountMin, "BondingCurve: Slippage exceeded");

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

        // Transfer fee to vault
        payable(vault).transfer(fee);
    }

    // Sell Token
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

        // Update reserves
        virtualPools[token].ETHReserve -= netAmount;
        virtualPools[token].TokenReserve += tokenAmount;

        // Transfer ETH to seller
        payable(msg.sender).transfer(netAmount);

        // Emit event
        emit TokenSold(token, msg.sender, ethAmount, fee, tokenAmount);

        // Transfer fee to vault
        payable(vault).transfer(fee);
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

        // Bonding curve formula (e.g., constant product)
        // Adjust the formula according to your bonding curve design
        tokenAmount =
            (ethAmount * pool.TokenReserve) /
            (pool.ETHReserve + ethAmount);
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

        // Bonding curve formula (e.g., constant product)
        // Adjust the formula according to your bonding curve design
        ethAmount =
            (tokenAmount * pool.ETHReserve) /
            (pool.TokenReserve + tokenAmount);
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
