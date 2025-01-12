// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "../src/BondingCurve.sol";
import "../src/Token.sol";

contract MockVault {
    receive() external payable {}
}

contract MockUniswapV2Factory {
    address public pair;

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address) {
        // For simplicity, create a new MockUniswapV2Pair
        MockUniswapV2Pair newPair = new MockUniswapV2Pair(tokenA, tokenB);
        pair = address(newPair);
        return pair;
    }
}

contract MockUniswapV2Router {
    address public immutable WETHAddress;

    constructor(address _weth) {
        WETHAddress = _weth;
    }

    function WETH() external view returns (address) {
        // Return the WETH address
        return WETHAddress;
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity)
    {
        // Mock behavior: Just return the input amounts
        require(token != address(169), "use the token param to avoid warning");
        require(to != address(169), "use the to param to avoid warning");
        require(deadline > block.timestamp, "Deadline has passed");
        require(amountETHMin <= msg.value, "Amount ETH min exceeded");
        require(
            amountTokenMin <= amountTokenDesired,
            "Amount token min exceeded"
        );
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = amountToken + amountETH;
        return (amountToken, amountETH, liquidity);
    }
}

contract MockUniswapV2Pair {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function transfer(address to, uint amount) external pure returns (bool) {
        // Mock transfer: Do nothing and return true
        require(to != address(169), "use the to param to avoid warning");
        require(amount > 0, "Transfer amount must be greater than 0");
        return true;
    }
}

contract BondingCurveTest is Test {
    BondingCurve public bondingCurve;
    Token public token;

    address public owner = address(1);
    address public user = address(2);
    MockVault vault = new MockVault();
    Token weth = new Token("WETH", "WETH", 1000000 ether, address(owner));
    MockUniswapV2Factory factory = new MockUniswapV2Factory();
    MockUniswapV2Router router = new MockUniswapV2Router(address(weth));

    receive() external payable {}

    function setUp() public {
        // Deploy the BondingCurve contract
        vm.prank(owner);
        bondingCurve = new BondingCurve();
        bondingCurve.initialize(
            address(vault), // vault
            address(factory), // factory
            address(router), // router
            1 ether, // maxPurchaseAmount
            owner // owner
        );
    }

    function deployTestToken() internal returns (address) {
        vm.prank(user);
        bondingCurve.createAndInitPurchase{
            value: 1 ether + bondingCurve.LAUNCH_FEE()
        }("Test Token", "TTK");
        return bondingCurve.tokenAddress(1);
    }

    function onlyCreateTestToken() internal returns (address) {
        vm.prank(user);
        bondingCurve.createAndInitPurchase{value: bondingCurve.LAUNCH_FEE()}(
            "Test Token",
            "TTK"
        );
        address tokenAddress = bondingCurve.tokenAddress(1);
        (uint256 ETHReserve, uint256 TokenReserve, ) = bondingCurve
            .virtualPools(tokenAddress);

        uint256 tokenAmount = Token(tokenAddress).balanceOf(user);

        assertEq(tokenAmount, 0, "User should not receive tokens");
        assertEq(ETHReserve, 0, "ETHReserve should be 0");
        assertEq(
            TokenReserve,
            bondingCurve.TOTAL_SALE(),
            "TokenReserve should be TOTAL_SALE"
        );

        return tokenAddress;
    }

    function logPoolData(address tokenAddress) internal view {
        (uint256 ETHReserve, uint256 TokenReserve, bool launched) = bondingCurve
            .virtualPools(tokenAddress);
        console.log("ETHReserve: ", ETHReserve);
        console.log("TokenReserve: ", TokenReserve);
        console.log("Launched: ", launched);
    }

    function testCreateAndInitPurchase_Successful() public {
        uint256 initialFunds = 1 ether;
        uint256 totalFunds = initialFunds + bondingCurve.LAUNCH_FEE();

        vm.deal(user, totalFunds);

        vm.prank(user);
        bondingCurve.createAndInitPurchase{value: totalFunds}(
            "Test Token",
            "TTK"
        );

        // Check token creation
        address tokenAddress = bondingCurve.tokenAddress(1);
        assertTrue(tokenAddress != address(0), "Token should be created");

        // Compute the tokens bought during initial purchase
        uint256 tokensBought = Token(tokenAddress).balanceOf(user);

        // Check token reserve and ETH reserve
        (uint256 ETHReserve, uint256 TokenReserve, ) = bondingCurve
            .virtualPools(tokenAddress);

        assertEq(
            TokenReserve,
            bondingCurve.TOTAL_SALE() - tokensBought,
            "TokenReserve should be updated correctly"
        );
        assertEq(
            ETHReserve,
            initialFunds - user.balance,
            "ETHReserve should be updated correctly"
        );
    }

    function testCreateAndInitPurchase_InsufficientFee() public {
        vm.deal(user, 0.0001 ether);

        vm.prank(user);
        vm.expectRevert("BondingCurve: Insufficient fees");
        bondingCurve.createAndInitPurchase{value: 0.0001 ether}(
            "Test Token",
            "TTK"
        );
    }

    function testCreateAndInitPurchase_ContractPaused() public {
        uint256 initialFunds = 1 ether;
        uint256 totalFunds = initialFunds + bondingCurve.LAUNCH_FEE();

        vm.prank(owner);
        bondingCurve.pausePad();

        vm.deal(user, 1 ether + bondingCurve.LAUNCH_FEE());
        vm.prank(user);

        vm.expectRevert("BondingCurve: Contract is paused");
        bondingCurve.createAndInitPurchase{value: totalFunds}(
            "Test Token",
            "TTK"
        );
    }

    function testPurchaseToken_Successful() public {
        address tokenAddress = deployTestToken();

        // Verify reserves
        (
            uint256 initialEthReserve,
            uint256 initialTokenReserve,

        ) = bondingCurve.virtualPools(tokenAddress);
        initialEthReserve -= user.balance;

        vm.deal(user, 1 ether);
        vm.prank(user);
        bondingCurve.purchaseToken{value: 1 ether}(tokenAddress, 0);

        // Verify token balance
        uint256 tokenBalance = Token(tokenAddress).balanceOf(user);
        assertGt(tokenBalance, 0, "User should receive tokens");
        uint256 leftoverEth = user.balance;

        // Verify reserves
        (uint256 ETHReserve, uint256 TokenReserve, ) = bondingCurve
            .virtualPools(tokenAddress);

        uint256 expectedRemainingTokens = initialTokenReserve - tokenBalance;
        uint256 expectedEthReserve = 1 ether - leftoverEth;

        assertEq(
            TokenReserve,
            expectedRemainingTokens,
            "TokenReserve should be updated correctly"
        );
        assertEq(
            ETHReserve - initialEthReserve,
            expectedEthReserve,
            "ETHReserve should be updated correctly"
        );
    }

    function testPurchaseToken_ExceedsMaxAmount() public {
        address tokenAddress = deployTestToken();
        uint256 valueWhichExceedsMaxAmount = bondingCurve.maxPurchaseAmount() +
            1 ether;

        vm.deal(user, valueWhichExceedsMaxAmount);
        vm.prank(user);
        vm.expectRevert("BondingCurve: Exceeds max purchase amount");
        bondingCurve.purchaseToken{value: valueWhichExceedsMaxAmount}(
            tokenAddress,
            0
        );
    }

    function testPurchaseToken_SlippageExceeded() public {
        address tokenAddress = deployTestToken();
        uint256 initialTokens = 1e18;

        uint256 ethValue = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            initialTokens
        );
        vm.deal(user, ethValue);
        vm.prank(user);
        vm.expectRevert("BondingCurve: Slippage exceeded");
        bondingCurve.purchaseToken{value: ethValue}(
            tokenAddress,
            initialTokens * 2
        );
    }

    function testPurchaseToken_SlippageNotExceeded() public {
        address tokenAddress = deployTestToken();
        uint256 initialTokens = 1e18;

        uint256 ethValue = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            initialTokens
        );
        uint256 slippageTwoPercent = initialTokens -
            ((initialTokens * 2) / 100);
        vm.deal(user, ethValue);
        vm.prank(user);
        bondingCurve.purchaseToken{value: ethValue}(
            tokenAddress,
            slippageTwoPercent
        );

        uint256 tokenBalance = Token(tokenAddress).balanceOf(user);
        assertGt(
            tokenBalance,
            slippageTwoPercent,
            "User should receive tokens"
        );
    }

    function testSellToken_Successful() public {
        address tokenAddress = onlyCreateTestToken();
        uint256 initialEthValue = 1 ether;

        // User buys tokens first
        vm.deal(user, initialEthValue);
        vm.prank(user);
        bondingCurve.purchaseToken{value: initialEthValue}(tokenAddress, 0);

        uint256 initialTokenBalance = Token(tokenAddress).balanceOf(user);
        uint256 tokenAmount = initialTokenBalance / 2;

        // Approve half of the tokens for sale
        vm.prank(user);
        Token(tokenAddress).approve(address(bondingCurve), tokenAmount);

        // Sell half the tokens
        vm.prank(user);
        bondingCurve.sellToken(tokenAddress, tokenAmount, 0);

        // Verify token balance
        uint256 tokenBalance = Token(tokenAddress).balanceOf(user);
        assertLt(
            tokenBalance,
            initialTokenBalance,
            "Tokens should be deducted after sale"
        );

        // Verify ETH balance
        uint256 ethBalance = user.balance;
        assertGt(ethBalance, 0, "User should receive ETH");

        // Verify reserves
        (uint256 ETHReserve, uint256 TokenReserve, ) = bondingCurve
            .virtualPools(tokenAddress);

        assertEq(
            TokenReserve,
            bondingCurve.TOTAL_SALE() - tokenBalance,
            "TokenReserve should be updated correctly"
        );
        assertEq(
            ETHReserve,
            initialEthValue - ethBalance,
            "ETHReserve should be updated correctly"
        );
    }

    function testSellToken_MoreThanOwned() public {
        address tokenAddress = deployTestToken();
        uint256 tokenAmount = 1000 * 1e18;

        // User has no tokens
        vm.prank(user);
        vm.expectRevert();
        bondingCurve.sellToken(tokenAddress, tokenAmount, 0);
    }

    function testTokenLaunch_ThresholdReached() public {
        address tokenAddress = onlyCreateTestToken();

        for (uint256 i = 0; i < 201; i++) {
            vm.deal(user, 0.1 ether);
            vm.prank(user);
            bondingCurve.purchaseToken{value: 0.1 ether}(tokenAddress, 0);
        }

        (, , bool launched) = bondingCurve.virtualPools(tokenAddress);
        assertTrue(launched, "Token should be launched");
    }

    function testTokenLaunch_NotReached() public {
        address tokenAddress = onlyCreateTestToken();

        for (uint256 i = 0; i < 198; i++) {
            vm.deal(user, 0.1 ether);
            vm.prank(user);
            bondingCurve.purchaseToken{value: 0.1 ether}(tokenAddress, 0);
        }

        logPoolData(tokenAddress);
        // Verify token is not launched
        (, , bool launched) = bondingCurve.virtualPools(tokenAddress);

        assertFalse(launched, "Token should not be launched");
    }

    function testPriceIncreaseOnPurchase() public {
        address tokenAddress = deployTestToken();

        // Get initial price
        uint256 initialPrice = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            1e18
        );

        // User purchases tokens
        vm.deal(user, 1 ether);
        vm.prank(user);
        bondingCurve.purchaseToken{value: 1 ether}(tokenAddress, 0);

        // Get new price
        uint256 newPrice = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            1e18
        );

        assertGt(
            newPrice,
            initialPrice,
            "Price should increase after purchase"
        );
    }

    function testPriceDecreaseOnSale() public {
        address tokenAddress = deployTestToken();

        // User purchases tokens first
        vm.deal(user, 1 ether);
        vm.prank(user);
        bondingCurve.purchaseToken{value: 1 ether}(tokenAddress, 0);

        uint256 priceAfterPurchase = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            1e18
        );

        // Approve and sell tokens
        uint256 tokenAmount = Token(tokenAddress).balanceOf(user);
        vm.prank(user);
        Token(tokenAddress).approve(address(bondingCurve), tokenAmount);

        vm.prank(user);
        bondingCurve.sellToken(tokenAddress, tokenAmount, 0);

        uint256 priceAfterSale = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            1e18
        );

        assertLt(
            priceAfterSale,
            priceAfterPurchase,
            "Price should decrease after sale"
        );
    }

    function testPriceIsAccurate() public {
        address tokenAddress = deployTestToken();
        // Get initial price
        uint256 initialPrice = bondingCurve.getEthAmountToBuyTokens(
            tokenAddress,
            1e18
        );
        // User purchases one token with the initialPrice
        vm.deal(user, initialPrice);
        vm.prank(user);
        bondingCurve.purchaseToken{value: initialPrice}(tokenAddress, 0);
        vm.prank(user);
        // Check that we have one token
        uint256 tokenBalance = Token(tokenAddress).balanceOf(user);

        // Calculate the allowed difference (0.05% of 1e18)
        uint256 allowedDifference = (1e18 * 5) / 10000;

        // Check if the token balance is within the allowed range
        assertTrue(
            tokenBalance >= 1e18 - allowedDifference &&
                tokenBalance <= 1e18 + allowedDifference,
            "User's token balance should be within 0.05% of one token"
        );
    }

    function testTokenSellsForSamePrice() public {
        address tokenAddress = deployTestToken();

        // User purchases tokens for 1 eth

        vm.deal(user, 1 ether);
        vm.prank(user);
        bondingCurve.purchaseToken{value: 1 ether}(tokenAddress, 0);

        // User sells tokens for 1 eth
        uint256 tokenAmount = Token(tokenAddress).balanceOf(user);
        vm.prank(user);
        Token(tokenAddress).approve(address(bondingCurve), tokenAmount);

        // Check that the sale would result in 1 eth, getEthAmountBySale
        vm.prank(user);
        uint256 ethAmount = bondingCurve.getEthAmountBySale(
            tokenAddress,
            tokenAmount
        );
        assertEq(
            ethAmount + user.balance,
            1 ether,
            "User should receive 1 eth"
        );

        vm.prank(user);
        bondingCurve.sellToken(tokenAddress, tokenAmount, 0);
        // Check that we have no tokens
        uint256 tokenBalance = Token(tokenAddress).balanceOf(user);
        assertEq(tokenBalance, 0, "User should have no tokens");

        // Check that we have 1 eth
        uint256 ethBalance = user.balance;
        assertEq(ethBalance, 1 ether, "User should have 1 eth");
    }

    function testPauseContract() public {
        address tokenAddress = deployTestToken();
        vm.prank(owner);
        bondingCurve.pausePad();

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert("BondingCurve: Contract is paused");
        bondingCurve.purchaseToken{value: 1 ether}(tokenAddress, 0);
    }

    function testUnpauseContract() public {
        address tokenAddress = deployTestToken();
        vm.prank(owner);
        bondingCurve.pausePad();

        vm.prank(owner);
        bondingCurve.rerunPad();

        vm.deal(user, 1 ether);
        vm.prank(user);
        bondingCurve.purchaseToken{value: 1 ether}(tokenAddress, 0);

        // Verify purchase was successful
        uint256 tokenBalance = Token(tokenAddress).balanceOf(user);
        assertGt(tokenBalance, 0, "User should receive tokens after unpausing");
    }

    function testOnlyOwnerCanSetVault() public {
        address newVault = address(3);
        // Non-owner tries to set vault
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user)
        );
        bondingCurve.setVault(newVault);
        // Owner sets vault
        vm.prank(owner);
        bondingCurve.setVault(newVault);
        assertEq(
            bondingCurve.vault(),
            newVault,
            "Vault should be updated by owner"
        );
    }

    function testOwnershipTransfer() public {
        address newOwner = address(0x789);

        // Owner sets pending owner
        vm.prank(owner);
        bondingCurve.setPendingOwner(newOwner);

        // New owner accepts ownership
        vm.prank(newOwner);
        bondingCurve.acceptOwner();

        assertEq(
            bondingCurve.owner(),
            newOwner,
            "Ownership should be transferred"
        );
    }
    function testPurchaseWhenMaxSupplyReached() public {
        address tokenAddress = onlyCreateTestToken();

        for (uint256 i = 0; i < 199; i++) {
            vm.deal(user, 0.1 ether);
            vm.prank(user);
            bondingCurve.purchaseToken{value: 0.1 ether}(tokenAddress, 0);
        }

        uint256 maxPurchaseAmount = bondingCurve.maxPurchaseAmount();
        uint256 tokenAmount = bondingCurve.getTokenAmountByPurchase(
            tokenAddress,
            maxPurchaseAmount
        );

        vm.deal(user, maxPurchaseAmount);
        vm.prank(user);
        vm.expectRevert(
            "BondingCurve: Cannot purchase more tokens than available"
        );
        bondingCurve.purchaseToken{value: maxPurchaseAmount}(
            tokenAddress,
            (tokenAmount * 100) / 98
        );
    }

    function testLaunchFeeTransferredToVault() public {
        address bcVault = bondingCurve.vault();
        uint256 initialVaultBalance = bcVault.balance;

        vm.deal(user, bondingCurve.LAUNCH_FEE());
        vm.prank(user);
        bondingCurve.createAndInitPurchase{value: bondingCurve.LAUNCH_FEE()}(
            "Test Token",
            "TTK"
        );

        uint256 finalVaultBalance = bcVault.balance;
        assertEq(
            finalVaultBalance - initialVaultBalance,
            bondingCurve.LAUNCH_FEE(),
            "Launch fee should be transferred to vault"
        );
    }

    function testReentrancyProtection() public {
        address tokenAddress = deployTestToken();

        // Deploy malicious contract
        MaliciousContract attacker = new MaliciousContract(
            bondingCurve,
            tokenAddress
        );

        vm.deal(address(attacker), 1 ether);

        vm.prank(address(attacker));
        vm.expectRevert(); // Expect reentrancy to be prevented
        attacker.attack{value: 1 ether}();
    }
}

// Implement a malicious contract that attempts reentrancy
contract MaliciousContract {
    BondingCurve public bondingCurve;
    address public tokenAddress;

    constructor(BondingCurve _bondingCurve, address _tokenAddress) {
        bondingCurve = _bondingCurve;
        tokenAddress = _tokenAddress;
    }

    function attack() public payable {
        bondingCurve.purchaseToken{value: msg.value}(tokenAddress, 0);
    }

    // Fallback function to attempt reentrancy
    receive() external payable {
        // Attempt to re-enter purchaseToken or sellToken
        bondingCurve.sellToken(tokenAddress, 1, 0);
    }
}
