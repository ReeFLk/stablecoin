// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
* @title Decentralized Stable Coin
* Collateral: Exogenous (ETH, BTC)
* Minting: Algoritmic
* Relative Stability: Pegged to USD
*
* This contract meant to be governed by DSCEngine. 
* This contract is just the ERC20 implementation of our stable coin.
*/
abstract contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DSC__MustBeMoreThanZero();
    error DSC__BurnAmountExceedsBalance();
    error DSC__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DSC__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DSC__MustBeMoreThanZero();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DSC__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DSC__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
