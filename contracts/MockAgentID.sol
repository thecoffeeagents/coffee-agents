// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Test-only stand-in for the BSC Agent ID contract.
contract MockAgentID is ERC721 {
    uint256 private _next = 1;

    constructor() ERC721("Mock Agent ID", "AGENTID") {}

    function give(address to) external {
        _safeMint(to, _next);
        _next += 1;
    }
}
