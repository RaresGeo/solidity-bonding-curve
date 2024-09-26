#!/bin/bash

forge script --chain sepolia script/DeployBondingCurve.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify --verifier blockscout --verifier-url https://base-sepolia.blockscout.com/api/ -vvvv