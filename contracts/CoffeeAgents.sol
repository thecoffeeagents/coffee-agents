// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";

/// @title Coffee Agents (BEANS) — Model A
/// @notice ERC-721, max supply 5,555 locked. Free phase for Agent ID holders
///         (first 1,500, 1 per wallet), then a paid price ladder
///         (0.0005 / 0.001 / 0.002 BNB). Mint window 2 weeks from first open;
///         finalize() closes minting forever (unminted supply can never exist).
///         Final metadata URI is committed before mint opens and locked forever;
///         reveal is permissionless 48h after finalize; proceeds stay locked
///         in the contract until reveal. Owner powers are limited to:
///         start/pause mint, finalize, commit final URI (pre-mint), withdraw
///         after reveal. No owner mint, no supply changes, no control over
///         holders' tokens.
contract CoffeeAgents is ERC721Royalty, Ownable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 5555;
    uint256 public constant FREE_QUOTA = 1500;
    uint256 public constant MAX_PER_WALLET = 20;
    uint256 public constant MINT_DURATION = 14 days;
    uint256 public constant REVEAL_DELAY = 48 hours;

    uint256 public constant PRICE_TIER_1 = 0.0005 ether; // tokens 1501-3000
    uint256 public constant PRICE_TIER_2 = 0.001 ether; //  tokens 3001-4500
    uint256 public constant PRICE_TIER_3 = 0.002 ether; //  tokens 4501-5555

    uint256 private constant TIER_1_END = 3000;
    uint256 private constant TIER_2_END = 4500;

    IERC721 public immutable agentId;
    address public immutable treasury;

    uint256 public totalMinted;
    uint256 public mintStartTime;
    uint256 public finalizedAt;
    bool public mintActive;
    bool public finalized;
    bool public revealed;

    string private _sealedURI;
    string private _finalBaseURI;
    bool private _finalBaseURICommitted;

    mapping(address => bool) public freeClaimed;
    mapping(address => uint256) public mintedPerWallet;

    event MintStarted(uint256 startTime, uint256 deadline);
    event MintPaused();
    event MintResumed();
    event Finalized(uint256 totalMinted, uint256 finalizedAt);
    event FinalBaseURICommitted(string baseURI);
    event Revealed(string baseURI);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(
        address agentIdContract,
        address treasuryAddress,
        string memory sealedURI
    ) ERC721("Coffee Agents", "BEANS") Ownable(msg.sender) {
        require(agentIdContract != address(0), "agentId = 0");
        require(treasuryAddress != address(0), "treasury = 0");
        agentId = IERC721(agentIdContract);
        treasury = treasuryAddress;
        _sealedURI = sealedURI;
        _setDefaultRoyalty(treasuryAddress, 300); // 3% ERC-2981
    }

    // ---------- owner: phase control (the full extent of owner power) ----------

    /// @notice Opens the mint window once. The 14-day deadline is anchored here.
    function startMint() external onlyOwner {
        require(mintStartTime == 0, "already started");
        require(!finalized, "finalized");
        mintStartTime = block.timestamp;
        mintActive = true;
        emit MintStarted(mintStartTime, mintStartTime + MINT_DURATION);
    }

    function pauseMint() external onlyOwner {
        require(mintActive, "not active");
        mintActive = false;
        emit MintPaused();
    }

    function resumeMint() external onlyOwner {
        require(mintStartTime != 0 && !mintActive && !finalized, "cannot resume");
        require(block.timestamp < mintStartTime + MINT_DURATION, "window over");
        mintActive = true;
        emit MintResumed();
    }

    /// @notice Permanently closes minting. Unminted supply can never be created.
    function finalize() external onlyOwner {
        require(!finalized, "already finalized");
        finalized = true;
        finalizedAt = block.timestamp;
        mintActive = false;
        emit Finalized(totalMinted, finalizedAt);
    }

    /// @notice Commits the final metadata baseURI before mint opens.
    ///         One-shot and locked forever, so the revealed art is fixed
    ///         before anyone pays. Must be set before startMint().
    function commitFinalBaseURI(string calldata finalBaseURI) external onlyOwner {
        require(mintStartTime == 0, "mint already started");
        require(!_finalBaseURICommitted, "already committed");
        _finalBaseURI = finalBaseURI;
        _finalBaseURICommitted = true;
        emit FinalBaseURICommitted(finalBaseURI);
    }

    /// @notice Permissionless reveal, 48h after finalize: anyone can trigger it,
    ///         so delivery never depends on the team showing up.
    function reveal() external {
        require(finalized, "not finalized");
        require(!revealed, "already revealed");
        require(_finalBaseURICommitted, "no committed URI");
        require(block.timestamp >= finalizedAt + REVEAL_DELAY, "reveal too early");
        revealed = true;
        emit Revealed(_finalBaseURI);
    }

    /// @notice Proceeds stay locked in the contract until reveal is live.
    function withdraw() external onlyOwner {
        require(revealed, "locked until reveal");
        uint256 amount = address(this).balance;
        require(amount > 0, "nothing to withdraw");
        (bool ok, ) = treasury.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(treasury, amount);
    }

    // ---------- minting ----------

    function _mintOpen() internal view {
        require(mintActive && !finalized, "mint not open");
        require(block.timestamp < mintStartTime + MINT_DURATION, "mint window over");
    }

    /// @notice Free mint: 1 per wallet, Agent ID holders only, first 1,500 tokens.
    function mintFree() external {
        _mintOpen();
        require(totalMinted < FREE_QUOTA, "free quota exhausted");
        require(!freeClaimed[msg.sender], "free already claimed");
        require(agentId.balanceOf(msg.sender) > 0, "no Agent ID");
        require(mintedPerWallet[msg.sender] < MAX_PER_WALLET, "wallet cap");
        freeClaimed[msg.sender] = true;
        mintedPerWallet[msg.sender] += 1;
        totalMinted += 1;
        _safeMint(msg.sender, totalMinted);
    }

    /// @notice Paid mint on the price ladder. Exact payment only.
    ///         Available once the free quota is exhausted (or supply sells out first).
    function mint(uint256 qty) external payable nonReentrant {
        _mintOpen();
        require(totalMinted >= FREE_QUOTA, "free phase still running");
        require(qty > 0, "qty = 0");
        require(totalMinted + qty <= MAX_SUPPLY, "exceeds supply");
        require(mintedPerWallet[msg.sender] + qty <= MAX_PER_WALLET, "wallet cap");
        uint256 cost = quotePrice(totalMinted, qty);
        require(msg.value == cost, "exact payment required");
        mintedPerWallet[msg.sender] += qty;
        for (uint256 i = 0; i < qty; i++) {
            totalMinted += 1;
            _safeMint(msg.sender, totalMinted);
        }
    }

    /// @notice Total price for minting `qty` tokens starting at `alreadyMinted`,
    ///         walking the ladder blocks (a single mint can straddle two tiers).
    function quotePrice(uint256 alreadyMinted, uint256 qty) public pure returns (uint256) {
        uint256 cost = 0;
        uint256 pos = alreadyMinted;
        uint256 remaining = qty;
        while (remaining > 0) {
            uint256 price;
            uint256 blockEnd;
            if (pos < TIER_1_END) {
                price = PRICE_TIER_1;
                blockEnd = TIER_1_END;
            } else if (pos < TIER_2_END) {
                price = PRICE_TIER_2;
                blockEnd = TIER_2_END;
            } else {
                price = PRICE_TIER_3;
                blockEnd = MAX_SUPPLY;
            }
            uint256 take = blockEnd - pos;
            if (take > remaining) take = remaining;
            cost += take * price;
            pos += take;
            remaining -= take;
        }
        return cost;
    }

    function currentPrice() external view returns (uint256) {
        if (totalMinted < FREE_QUOTA) return 0;
        return quotePrice(totalMinted, 1);
    }

    // ---------- metadata ----------

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (!revealed) return _sealedURI;
        return string(abi.encodePacked(_finalBaseURI, _toString(tokenId), ".json"));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Royalty)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
