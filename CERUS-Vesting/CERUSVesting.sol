//                                   %@
//                               @@@@@%
//                            %@@@@@@@
//                  @@@     /@@@@@@@
//                 &@@@@   @@@@@@@
//                 @@@@@  %@@@@%
//                 @@@@@ #@            (,/
//         @@@     @@@@@@ *@@@@@@@@@..........,,
//         @@@@&    @@@@@@@@@@@@@@..................
//         @@@@@(   @@,#&@%(  (......................,#
//          @@@@@  @ .,................................,/
//    @@    */..@@........................,..........,.......
//   @@@@@  . @@@.......................... ...,......../ ....,
//   (@@@@@..( @#.........................,       ....(
//    @@@@@( &@(.........,, ..................,,  ,.(
//     @@@@@@&......,@@@@@@(..,,....,( .   ...,.
//      #@@@(.....@@@@@@#      ....( .......
//        @#@...@@@/           .,.
//       @( ,...              #..
//      @(  ....,#(/,...,,..............,.,,...*/(#

//      @@@@@@@@   @@@@@@@@@  @@@@@@@@  @@@@   @@@  @@@@@@@@@
//     @@@        @@@        @@    @@@  @@@   @@@  @@@
//    @@@        @@@@@@@@@@ @@@@@@@@@  @@@   @@@ @@@@@@@@@@
//   @@@        @@@        @@@   @@@  @@@   @@@&       @@@
//    @@@@@@   @@@@@@@@@@ @@@    @@@   @@@@@@   @@@@@@@%
//
// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CERUSVesting is AccessControl, ReentrancyGuard {
    using SafeERC20 for ERC20Burnable;
    using SafeERC20 for IERC20;

    // EVENTS
    event Initialized();
    event InitializedClaim();
    event CERUS(address cerus);
    event Treasury(address treasury);
    event Deposit(address indexed user, uint256 indexed amount);
    event Claim(address indexed user, uint256 indexed amount);
    event WithdrawUnsold(uint256 amount);
    event Whitelist(address proxy, bool state);

    // ACCESS ROLES
    bytes32 public constant WHITELISTER_ROLE = keccak256("WHITELISTER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // WHITELIST
    mapping(address => bool) public whitelisted;
    bool public useWhitelist;

    // Info of each user.
    struct InvestorInfo {
        uint256 depositedAmount; // How much an investor has invested in the buy token.
        uint256 vestedAmount; // Is the amount CERUS left to claim by an investor.
        uint256 claimedEpochs; // How many times an investor has claimed.
    }
    mapping(address => InvestorInfo) public investorInfo;

    // TOKENS
    address public cerusToken; /// @notice undeployed, must be set later.
    address public buyToken; // We will use 0xEA32A96608495e54156Ae48931A7c20f0dcc1a21 - m.usdc on metis
    uint256 public constant CERUS_DECIMALS = 18;

    // SALE
    bool public isPublicSale;
    uint256 public constant MAX_BURNED = 100000 * 10**CERUS_DECIMALS; // Amount to burn if not sold after public sale.
    uint256 public totalCerus; // Total amount to sell.
    uint256 public cerusPrice; // In buy token (m.usdc).
    uint256 public minBuy; // Min. amount invested in buy token.
    uint256 public totalVested = 0; // Total amount of CERUS sold.

    uint256 public saleStart; // In unix time.
    uint256 public saleEnd; // In unix time.

    address public treasury;

    // CLAIM
    uint256 public claimStart; // In unix time.
    uint256 public totalEpochs; // Number of claim epochs.
    uint256 public epochLength; // Fx. 4 weeks.
    uint256 public totalClaimed; // counter for the UI.

    // Booleans used for locking.
    bool public hasWithdrawnUnsold = false;
    bool public initialized = false;
    bool public initializedClaim = false;

    // CONSTRUCTOR
    /// @dev We don't pass args here to make it easier to verify on METIS.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // INIT CONTRACT
    function initialize(
        address _whitelister,
        address _treasury,
        address _buyToken,
        uint256 _totalCerus,
        uint256 _cerusPrice,
        uint256 _minBuy,
        uint256 _saleStart,
        uint256 _saleDuration,
        bool _useWhitelist,
        bool _isPublicSale
    ) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin!");
        require(!initialized, "Already initialized!");
        initialized = true;

        _grantRole(WHITELISTER_ROLE, _whitelister);
        _grantRole(TREASURY_ROLE, _treasury);

        useWhitelist = _useWhitelist;
        treasury = _treasury;
        buyToken = _buyToken;
        totalCerus = _totalCerus;
        cerusPrice = _cerusPrice;
        minBuy = _minBuy;
        saleStart = _saleStart;
        saleEnd = _saleStart + _saleDuration;
        isPublicSale = _isPublicSale; /// @notice this determines if tokens are burned when withdrawUnsold is called

        emit Initialized();
    }

    function initializeClaim(
        uint256 _claimStart,
        uint256 _epochs,
        uint256 _epochLength
    ) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin!");
        require(!initializedClaim, "Claim already initialized!");

        initializedClaim = true;
        claimStart = _claimStart;
        totalEpochs = _epochs;
        epochLength = _epochLength;

        emit InitializedClaim();
    }

    // EXTERNAL & PUBLIC FUNCTIONS
    function whitelist(address _investor, bool _newState) external {
        require(hasRole(WHITELISTER_ROLE, msg.sender), "Not whitelister!");

        whitelisted[_investor] = _newState;

        emit Whitelist(_investor, _newState);
    }

    function deposit(uint256 _depositAmount) external nonReentrant {
        address investor = msg.sender;
        address _treasury = treasury;

        /// @dev Deposit requirements
        require(initialized, "deposit: not initialized!");
        require(_treasury != address(0), "deposit: treasury not set!");
        require(
            !useWhitelist || whitelisted[investor],
            "deposit: not whitelisted!"
        );
        require(isSale(), "deposit: sale is not live!");
        require(
            _depositAmount >= minBuy ||
                investorInfo[investor].depositedAmount > 0,
            "deposit: not enough!"
        );
        uint256 amountCerusToGet = (_depositAmount * (10**CERUS_DECIMALS)) /
            cerusPrice;
        require(
            amountCerusToGet <= (totalCerus - totalVested),
            "deposit: too much!"
        );
        require(
            _depositAmount <=
                IERC20(buyToken).allowance(investor, address(this)),
            "deposit: not approved!"
        );

        // Deposit
        bool success = IERC20(buyToken).transferFrom(
            investor,
            _treasury,
            _depositAmount
        );

        require(success, "deposit: tx error!");

        uint256 vestAmount = (_depositAmount * (10**CERUS_DECIMALS)) /
            cerusPrice;
        totalVested += vestAmount;

        investorInfo[investor].depositedAmount += _depositAmount;
        investorInfo[investor].vestedAmount += vestAmount;

        emit Deposit(investor, vestAmount);
    }

    function claim() external nonReentrant {
        address _cerusToken = cerusToken;
        address investor = msg.sender;

        /// @dev Claim requirements
        require(_cerusToken != address(0), "Cerus: not set!");
        require(claimStart <= block.timestamp, "claim: not yet!");
        require(
            investorInfo[investor].vestedAmount > 0,
            "claim: no investment!"
        );

        (uint256 claimableEpochs, uint256 claimableAmount) = pendingEpochs(
            investor
        );

        require(claimableEpochs > 0, "claim: wait until next epoch!");

        uint256 balance = IERC20(_cerusToken).balanceOf(address(this));

        require(balance > 0, "claim: token balance low!");

        // increment vars and send claim
        investorInfo[investor].claimedEpochs += claimableEpochs;
        investorInfo[investor].vestedAmount -= claimableAmount;
        totalClaimed += claimableAmount;

        IERC20(_cerusToken).transfer(investor, claimableAmount);

        emit Claim(investor, claimableAmount);
    }

    function withdrawUnsold() external {
        require(!hasWithdrawnUnsold, "withdrawUnsold: only once!");
        require(!isSale(), "withdrawUnsold: Sale not over!");
        require(
            hasRole(TREASURY_ROLE, msg.sender),
            "withdrawUnsold: not TREASURY_ROLE"
        );

        address _cerusToken = cerusToken;
        uint256 unsold = totalCerus - totalVested;
        uint256 balance = IERC20(_cerusToken).balanceOf(address(this));

        require(balance >= unsold, "withdrawUnsold: not enough tokens!");

        uint256 toBurn = (unsold <= MAX_BURNED) ? unsold : MAX_BURNED;
        uint256 toTransfer = (unsold > MAX_BURNED) ? unsold - MAX_BURNED : 0;
        hasWithdrawnUnsold = true;

        /// @notice we only burn only after the public sale round
        bool _isPublicSale = isPublicSale;

        if (_isPublicSale && toBurn > 0) {
            ERC20Burnable(_cerusToken).burn(toBurn);
        }
        if (
            (_isPublicSale && toTransfer > 0) || (!_isPublicSale && unsold > 0)
        ) {
            IERC20(_cerusToken).transfer(
                treasury,
                _isPublicSale ? toTransfer : unsold
            );
        }

        emit WithdrawUnsold(unsold);
    }

    // SETTERS
    function setTreasury(address _newTreasury) external {
        require(hasRole(TREASURY_ROLE, msg.sender), "not treasury!");

        treasury = _newTreasury;

        emit Treasury(_newTreasury);
    }

    function setCerus(address _cerus) external {
        require(hasRole(TREASURY_ROLE, msg.sender), "not treasury!");
        require(cerusToken == address(0), "Cerus: already set!");

        cerusToken = _cerus;

        emit CERUS(_cerus);
    }

    // HELPERS
    function isSale() public view returns (bool) {
        bool sale = (saleStart <= block.timestamp) &&
            (block.timestamp < saleEnd);

        return sale;
    }

    /// @dev we count claimable epochs from 1.
    function currentEpoch() public view returns (uint256) {
        uint256 _claimStart = claimStart;
        uint256 _claimEnd = _claimStart + (totalEpochs * epochLength);

        if (!(initialized && (block.timestamp >= _claimStart))) return 0;
        if (initialized && (block.timestamp >= _claimEnd)) return totalEpochs;

        return 1 + ((block.timestamp - _claimStart) / epochLength);
    }

    function pendingEpochs(address _investor)
        public
        view
        returns (uint256, uint256)
    {
        InvestorInfo memory investor = investorInfo[_investor];

        uint256 claimableEpochs = currentEpoch() - investor.claimedEpochs;

        if (claimableEpochs == 0) return (0, 0);

        uint256 unclaimedEpochs = totalEpochs - investor.claimedEpochs;
        uint256 claimableAmount = (investor.vestedAmount * claimableEpochs) /
            unclaimedEpochs;

        return (claimableEpochs, claimableAmount);
    }

    // END OF CONTRACT
}
