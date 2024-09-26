// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/BondingCurve.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract DeployBondingCurve is Script {
    function run() external {
        // PRIVATE_KEY, VAULT_ADDRESS, FACTORY_ADDRESS, ROUTER_ADDRESS, MAX_PURCHASE_AMOUNT, OWNER_ADDRESS

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("VAULT_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        uint256 maxPurchaseAmount = vm.envUint("MAX_PURCHASE_AMOUNT");
        address owner = vm.envAddress("OWNER_ADDRESS");

        console.log("~vault", vault);
        console.log("~factory", factory);
        console.log("~router", router);
        console.log("~maxPurchaseAmount", maxPurchaseAmount);
        console.log("~owner", owner);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the implementation contract
        BondingCurve bondingCurve = new BondingCurve();

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin(owner);

        // Encode the initializer function call
        bytes memory initializerData = abi.encodeWithSignature(
            "initialize(address,address,address,uint256,address)",
            vault,
            factory,
            router,
            maxPurchaseAmount,
            owner
        );

        // Deploy the TransparentUpgradeableProxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(bondingCurve),
            address(proxyAdmin),
            initializerData
        );

        // Try to manually initialize, in case it failed
        bondingCurve.initialize(
            vault,
            factory,
            router,
            maxPurchaseAmount,
            owner
        );

        vm.stopBroadcast();

        // Output the deployed addresses
        console.log("BondingCurve Implementation:", address(bondingCurve));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("BondingCurve Proxy:", address(proxy));
    }
}
