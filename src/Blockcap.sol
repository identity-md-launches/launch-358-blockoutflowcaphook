// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply BCAP. The launch factory receives the supply when it deploys this token.
contract Blockcap is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Blockcap", "BCAP") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
